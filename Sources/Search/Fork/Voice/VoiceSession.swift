import AppKit
import AVFoundation
import Combine
import Foundation
import os

// Dictation into the agent composer: the one place voice reaches in v1 —
// or, while an addon owns the Agent sidebar, into the addon's composer,
// which takes the words as a DictationSink (DictationSink.swift,
// Fork/Addons/AddonVoice.swift) and never touches the native draft.
//
// A press of ⌃⇧D (or the composer's mic) starts one dictation — a microphone
// capture feeding one LiveSession, which hears the whole hold and decodes it
// once at the end. Its partials are shown under the composer, never put in
// the draft; when it stops, the final text goes into the composer at the
// caret it had when it started (ComposerInsert), and with Settings › Intelligence › Voice ›
// "Send right away" the message is sent the way Return sends it.
//
//   idle → arming → dictating → finishing → idle
//                \→ error(…)      (permission off, the mic failing,
//                                  the model failing to load or decode)
//
// Every event from the audio and decode threads hops to the main actor
// asynchronously and carries the dictation's number; a number that isn't the
// current one is dropped, so nothing from a cancelled dictation lands. (A
// synchronous hop would deadlock: LiveSession.cancel waits for an emit in
// flight, and VoiceCapture.stop for its own queue.)
//
// The speech model is loaded when the pane opens (`warm`, a third of a
// second once this Mac has prepared it) and let go after ten idle minutes.
// The first load after macOS throws its Neural Engine cache away takes about
// a minute: past a second of loading the mic shows it is preparing and a
// press says so instead of listening; a dictation already under way keeps
// listening and says "Finishing… preparing speech model" until it can decode.
//
// Audio and words stay in memory; nothing is logged but counts and times.

/// Where a dictation's audio comes from: the microphone, or a file in tests.
/// The same contract as VoiceCapture: 800-sample 16 kHz blocks on a private
/// queue, `onStop` once after the last one, `stop()` synchronous.
protocol VoiceAudioSource: AnyObject, Sendable {
    func start(onBlock: @escaping @Sendable ([Swift.Float]) -> Void,
               onStop: @escaping @Sendable (VoiceCaptureStop) -> Void) throws
    func stop()
}

extension VoiceCapture: VoiceAudioSource {}

@MainActor
final class Voice: ObservableObject {
    static let shared = Voice()

    enum Phase: Equatable {
        case idle
        /// Pressed; the microphone is being asked for (or opened).
        case arming
        case dictating
        /// Released; the last decode is running.
        case finishing
        case error(String)
    }

    /// Who started a dictation, so only the same one can end a hold.
    /// `addon`: the sidebar addon's mic, through the bridge.
    enum Hand: String { case key, button, bench, addon }

    /// What the composer's mic shows.
    enum Mic: Equatable {
        /// Voice is off (or can't be on this Mac): no mic at all.
        case hidden
        /// The agent can't take a message: disabled, with why.
        case unavailable(String)
        /// The speech model isn't ready: dimmed, with why; a click opens Settings › Intelligence › Voice.
        case waiting(String)
        /// The model is installed and loading, and the load has taken over a
        /// second (the Neural Engine preparing it): dimmed; a press says so.
        case preparing
        case ready
    }

    /// The speech model in memory: not loaded, loading, loaded.
    enum EngineState: String { case cold, warming, warm }

    /// What the line above the composer's buttons says.
    enum Line: Equatable {
        case live(String, String)   // "Listening…" / "Finishing…", and the words
        case plain(String)
        case denied
    }

    @Published private(set) var phase: Phase = .idle
    /// The newest partial, for the line under the composer. Never the draft.
    @Published private(set) var preview = ""
    /// A brief line under the composer: "Hold to talk", "Inserted — press Return to send".
    @Published private(set) var note: String?
    /// Arming has taken longer than a blink: say so.
    @Published private(set) var slowStart = false
    /// The bench's frozen model state, for pictures of the mic waiting.
    @Published var seededModel: ModelStore.State?
    /// The speech model in memory. `warming` while a load Voice started runs.
    @Published private(set) var engineState: EngineState = .cold
    /// The load has run past a second: the first one on this Mac, not a reload.
    @Published private(set) var engineSlow = false
    /// The bench's frozen slow load, for pictures.
    @Published var seededWarming = false

    /// The window and browser the current dictation belongs to.
    private(set) weak var browser: Browser?
    private(set) weak var window: NSWindow?
    /// The current dictation's number. Bumped by every start and cancel.
    private(set) var session = 0
    /// Who the current dictation (or the last, or the press that was turned
    /// away) is for. Kept after it ends, as `browser` is, so a note it leaves
    /// goes to the same place.
    private(set) var target: Target = .composer
    /// The sink, when `target` is one. Weak: a sink that goes away mid-way
    /// takes the words with it — they never fall back into the draft.
    private(set) weak var sink: DictationSink?

    nonisolated static let denied = "Microphone access is off. Open System Settings to allow Copper, then try again."
    nonisolated static let privacyPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    nonisolated static let preparingHelp = "Preparing speech model — one time, about a minute"
    nonisolated static let preparingNote = "Preparing speech model… try again in a moment"
    nonisolated static let finishingPreparing = "Finishing… preparing speech model"
    nonisolated static let loadFailed = "Speech model failed to load — try again"
    /// Hold to talk, after the first-use microphone question was answered Allow.
    nonisolated static let allowedHoldKey = "Microphone allowed — hold ⌃⇧D to talk"
    nonisolated static let allowedHoldButton = "Microphone allowed — hold the mic button to talk"
    /// VoiceOver, once the words are in the message (and not sent).
    nonisolated static let insertedAnnouncement = "Dictation inserted; review before sending"
    /// How long a load runs before the mic says the model is being prepared.
    nonisolated static let slowLoad: TimeInterval = 1
    static let holdThreshold = 0.25
    static let cap: TimeInterval = 120
    static let idleUnload: TimeInterval = 600

    private let prefs = VoicePrefs.shared
    private var source: VoiceAudioSource?
    private var live: LiveSession?
    private var anchor: ComposerInsert.Anchor?
    private var hand: Hand?
    private var pressedAt = Date()
    private var releasedWhileArming = false
    private var capTimer: DispatchWorkItem?
    private var slowTimer: DispatchWorkItem?
    private var noteTimer: DispatchWorkItem?
    private var unloadTimer: DispatchWorkItem?
    /// The load in flight that `warm` started; a decode waits on it.
    private var warmTask: Task<Bool, Never>?
    private var warmTimer: DispatchWorkItem?
    /// Bumped by every load started and every reset, so a stale one is dropped.
    private var warmGeneration = 0
    /// The last load failed (a dictation that then hears nothing says why).
    private var warmFailed = false
    private var booted = false
    private var bag: Set<AnyCancellable> = []
    private var tokens: [NSObjectProtocol] = []
    /// Composers that have the keyboard, by browser.
    private var focused: Set<ObjectIdentifier> = []

    private static let log = Logger(subsystem: "com.collinrijock.copper", category: "voice")

    // MARK: - test hooks (bench only)

    /// A file instead of the microphone (bench `voice source`, `voice dictate`).
    var testSource: (() -> VoiceAudioSource)?
    /// Where a bench dictation puts its words when no composer editor has the keyboard.
    var benchRange: NSRange?
    /// Overrides the agent's readiness when deciding whether to send.
    var benchAgentReady: Bool?
    /// A shorter cap than 120 s, to see it end a dictation.
    var benchCap: TimeInterval?
    /// Every load waits this long first: a stand-in for the Neural Engine's
    /// first-time preparation (`voice warm`, `voice dictate --warm-delay`).
    var benchWarmDelay: TimeInterval?
    /// Presses turned away while the model was being prepared.
    private(set) var refusedPreparing = 0
    /// Every decode of the next dictation throws, as a model that fails to
    /// load or decode would (`voice dictate --decode-fails`).
    var benchDecodeFails = false
    /// With a test source: the permission macOS would report, and how a
    /// question would be answered after `seconds` — no prompt is ever shown.
    var benchPermission: (status: AVAuthorizationStatus, grant: Bool, seconds: Double)?
    /// What the last dictation did, for the bench: counts and times; the text only here.
    private(set) var timeline: [(ms: Int, event: String, count: Int?)] = []
    private(set) var lastInsert: ComposerInsert.Landed?
    private(set) var lastSent: String?
    /// The words the last dictation handed to a sink.
    private(set) var lastDelivered: String?
    private(set) var partials = 0
    private(set) var announced: [String] = []
    private var origin = Date()

    private init() {}

    // MARK: - launch

    /// At launch: the engine behind the model store, the key monitor, and
    /// what ends a dictation. Idempotent.
    func boot() {
        guard !booted else { return }
        booted = true
        if #available(macOS 15, *) {
            ModelStore.prepareHook = { dir, progress in
                try await VoiceEngine.shared.prepare(modelDir: dir, progress: progress)
            }
            ModelStore.unloadHook = { await VoiceEngine.shared.unload() }
        }
        VoiceChecks.register()
        VoiceKeys.install()
        ComposerInsert.followUndo()
        Listen.shared.boot()

        // The pane closing, voice going off, the model going away: cancel.
        // The pane opening or voice coming on with the model ready: warm up.
        Agent.shared.$open.removeDuplicates().sink { [weak self] open in
            guard let self else { return }
            if open { DispatchQueue.main.async { self.warm() } } else { self.cancel("pane closed") }
        }.store(in: &bag)
        prefs.$enabled.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            if on { DispatchQueue.main.async { self.warm() } } else { self.cancel("voice off") }
        }.store(in: &bag)
        ModelStore.shared.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            if state != .ready {
                self.cancel("model not ready")
                self.resetEngine()
            } else {
                DispatchQueue.main.async { self.warm() }
            }
        }.store(in: &bag)

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Voice.shared.lostFocus("app inactive") }
        })
        tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window, window === Voice.shared.window { Voice.shared.lostFocus("window not key") } }
        })
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window, window === Voice.shared.window { Voice.shared.cancel("window closed") } }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Voice.shared.cancel("sleep") }
        })
    }

    // MARK: - what the pane shows

    func mic(agentReady: Bool) -> Mic {
        let model = speechModel()
        guard model != .hidden else { return .hidden }
        // One capture at a time: Listen live or paused has the microphone.
        if Listen.shared.holdsMic { return .unavailable(Listen.blocksDictation) }
        guard agentReady else { return .unavailable("Sign in with Claude or add a key to use the agent") }
        return model
    }

    /// The speech model alone, whoever wants it: `hidden` with voice off,
    /// `waiting`/`preparing` until it can hear, else `ready`. The Listen door
    /// reads this; the mic adds the agent and Listen to it.
    func speechModel() -> Mic {
        guard VoicePrefs.supported, prefs.enabled else { return .hidden }
        switch seededModel ?? ModelStore.shared.state {
        case .ready: return preparing ? .preparing : .ready
        case .downloading(let fraction): return .waiting("Speech model downloading · \(Int((fraction * 100).rounded(.down)))%")
        case .verifying, .compiling, .preparing: return .waiting("Preparing speech model — one time, about a minute")
        case .failed: return .waiting("Speech model needs attention")
        case .absent: return .waiting("Set up voice in Settings")
        }
    }

    /// The model is loading and has been for over a second.
    var preparing: Bool { seededWarming || (engineState == .warming && engineSlow) }

    /// The line above the composer's buttons, or none.
    var line: Line? {
        switch phase {
        case .arming:
            return slowStart ? .plain("Starting microphone…") : nil
        case .dictating:
            return .live("Listening…", preview)
        case .finishing:
            return .live(preparing ? Voice.finishingPreparing : "Finishing…", preview)
        case .error(let message):
            return message == Voice.denied ? .denied : .plain(message)
        case .idle:
            return note.map(Line.plain)
        }
    }

    /// A dictation is under way (or starting, or landing).
    var active: Bool {
        switch phase {
        case .arming, .dictating, .finishing: return true
        case .idle, .error: return false
        }
    }

    /// The window an event came from is the dictation's.
    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === self.window { return true }
        if let browser, Windows.owner(of: window) === browser { return true }
        return false
    }

    /// Whether this window's composer has the keyboard (the pane says).
    func composerFocused(in window: NSWindow) -> Bool {
        guard let browser = Windows.owner(of: window) else { return false }
        return focused.contains(ObjectIdentifier(browser))
    }

    /// The pane's composer took or lost the keyboard.
    func composer(focused on: Bool, in browser: Browser) {
        if on { focused.insert(ObjectIdentifier(browser)) } else { focused.remove(ObjectIdentifier(browser)) }
    }

    /// Whether this browser's pane shows the current dictation's line. Never
    /// a sink's: its composer draws its own.
    func shows(in browser: Browser) -> Bool {
        guard target == .composer else { return false }
        return self.browser == nil || self.browser === browser
    }

    /// Whether the current (or last) dictation is for `sink` — nil being
    /// the pane's own composer.
    func aimed(at sink: DictationSink?) -> Bool {
        guard let sink else { return target == .composer }
        return target == .sink && self.sink === sink
    }

    /// A dictation is under way for `sink`.
    func serves(_ sink: DictationSink) -> Bool { active && aimed(at: sink) }

    private func aim(at sink: DictationSink?) {
        target = sink == nil ? .composer : .sink
        self.sink = sink
    }

    // MARK: - gestures

    /// ⌃⇧D down, the mic pressed (or clicked), or the bench. `sink`: the
    /// press is for the sidebar addon's composer (⌃⇧D while it owns the
    /// sidebar), not the pane's.
    func press(_ hand: Hand, in browser: Browser, window: NSWindow?, for sink: DictationSink? = nil) {
        // One dictation at a time, for one composer: a press meant for the
        // other one leaves it alone.
        if active, !aimed(at: sink) { return }
        // A note this press brings up shows in this window's pane (or its sink).
        if !active {
            self.browser = browser
            self.window = window ?? Windows.window(of: browser)
            aim(at: sink)
        }
        // Whether one can start; one under way can always be stopped. A sink
        // talks to its own service, so Copper's agent being set up is not a
        // condition for it.
        if !active {
            switch mic(agentReady: sink == nil ? Agent.shared.ready : true) {
            case .unavailable(let why) where why == Listen.blocksDictation:
                if hand == .key { tell(why, code: "busy", for: 2.5) }
                return
            case .hidden, .unavailable:
                return
            case .waiting(let why):
                if hand == .button { browser.openSettings(.intelligence, at: "voice.enabled") } else { tell(why, code: "not_ready", for: 2.5) }
                return
            case .preparing:
                // No capture: nothing could be heard into words for a while yet.
                refusedPreparing += 1
                tell(Voice.preparingNote, code: "not_ready", for: 3)
                announce("Preparing speech model")
                return
            case .ready:
                break
            }
        }
        switch prefs.trigger {
        case .toggle:
            switch phase {
            case .idle, .error: start(hand, in: browser, window: window)
            case .dictating: finish("stop")
            case .arming: cancel("pressed again")
            case .finishing: break
            }
        case .hold:
            switch phase {
            case .idle, .error: start(hand, in: browser, window: window)
            case .arming, .dictating, .finishing: break
            }
        }
    }

    /// ⌃⇧D up (or ⌃/⇧ let go), the mic released. Ends a hold.
    func lift(_ hand: Hand) {
        guard prefs.trigger == .hold, self.hand == hand else { return }
        self.hand = nil
        switch phase {
        case .arming:
            releasedWhileArming = true
            mark("release")
        case .dictating:
            mark("release")
            if Date().timeIntervalSince(pressedAt) < Voice.holdThreshold {
                cancel("tap")
                tell("Hold to talk", code: "hold", for: 1.6)
            } else {
                finish("release")
            }
        default:
            break
        }
    }

    /// VoiceOver's press of the mic: start or stop, without a held chord.
    func accessibilityActivate(in browser: Browser) {
        let window = Windows.window(of: browser)
        // The pane's mic never ends the sidebar addon's dictation.
        if active, !aimed(at: nil) { return }
        if phase == .dictating { finish("stop"); return }
        guard !active else { return }
        if case .ready = mic(agentReady: Agent.shared.ready) {
            // No hold to let go of: the next activation stops it.
            aim(at: nil)
            start(.button, in: browser, window: window, held: false)
        } else {
            press(.button, in: browser, window: window)
        }
    }

    // MARK: - the sidebar addon's mic (bridge `copper.voice`)

    /// `voice.start()`: a dictation for `sink`, started outright — whether
    /// one may start was the bridge's to answer (AddonVoice.refusal), as a
    /// press's is `press`'s. Hold or toggle alike, its own `stop` ends it.
    func begin(for sink: DictationSink, in browser: Browser, window: NSWindow?) {
        guard !active else { return }
        self.browser = browser
        self.window = window ?? Windows.window(of: browser)
        aim(at: sink)
        start(.addon, in: browser, window: window)
    }

    /// `voice.stop()`: as letting go of the pane's mic in hold mode (a tap
    /// under a quarter of a second is "Hold to talk", nothing heard), else
    /// as pressing it again. Only the sink's own dictation.
    func stop(for sink: DictationSink) {
        guard serves(sink) else { return }
        if prefs.trigger == .hold, hand == .addon {
            lift(.addon)
            return
        }
        switch phase {
        case .dictating: finish("stop")
        case .arming: cancel("pressed again")
        default: break
        }
    }

    /// `voice.cancel()`: thrown away, as Escape throws it away.
    func cancel(for sink: DictationSink) {
        guard serves(sink) else { return }
        cancel("addon")
    }

    /// The line's ✕, or an error dismissed.
    func dismiss() {
        if active { cancel("✕") } else {
            if case .error = phase { phase = .idle }
            clearNote()
        }
    }

    // MARK: - one dictation

    /// `held`: a gesture that is let go of to stop (a key or a pointer held
    /// down); not VoiceOver's activation, which starts and stops by itself.
    private func start(_ hand: Hand, in browser: Browser, window: NSWindow?, held: Bool = true) {
        stopTimers()
        clearNote()
        session += 1
        let id = session
        self.hand = held ? hand : nil
        let holding = held && prefs.trigger == .hold
        self.browser = browser
        self.window = window ?? Windows.window(of: browser)
        pressedAt = Date()
        origin = pressedAt
        releasedWhileArming = false
        timeline = []
        lastInsert = nil
        lastSent = nil
        lastDelivered = nil
        partials = 0
        announced = []
        preview = ""
        let draft = Agent.shared.draft
        if target == .sink {
            // The sink keeps its own caret; the pane's draft isn't looked at.
            anchor = nil
        } else if let range = benchRange {
            anchor = ComposerInsert.Anchor(draft: draft, range: ComposerInsert.clamp(range, in: draft), editor: nil, window: self.window)
        } else {
            anchor = ComposerInsert.capture(in: self.window, draft: draft)
        }
        phase = .arming
        mark("press:\(hand.rawValue)")
        let slow = DispatchWorkItem { [weak self] in
            guard let self, self.session == id, self.phase == .arming else { return }
            self.slowStart = true
        }
        slowTimer = slow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: slow)

        if testSource == nil {
            // The real microphone: never in headless Copper, and in a test
            // world only when the run says so — an automated run must never
            // bring up the permission prompt or open someone's mic.
            if Headless.on {
                fail("Dictation isn't available in headless Copper")
                return
            }
            if Store.testing, ProcessInfo.processInfo.environment["SEARCH_VOICE_MIC"] != "1" {
                fail("The microphone is off in test worlds")
                return
            }
        }
        // A file needs nobody's permission; the bench can stand in for the
        // question macOS would ask (benchPermission), never asking it.
        let fake = testSource == nil ? nil : benchPermission
        let status = fake?.status ?? (testSource != nil ? .authorized : VoiceCapture.authorization)
        switch status {
        case .authorized:
            open(makeSource(), session: id)
        case .notDetermined:
            // The first explicit gesture asks. The question takes the keyboard
            // and the pointer, so a hold's let-go goes to it and never comes
            // here: after Allow nobody may be holding anything. A hold
            // therefore never starts once it is answered — the line says to
            // hold again. Press to start and stop starts, as asked.
            mark("permission asked")
            Task { @MainActor in
                let granted: Bool
                if let fake {
                    try? await Task.sleep(nanoseconds: UInt64(fake.seconds * 1_000_000_000))
                    granted = fake.grant
                } else {
                    granted = await VoiceCapture.requestAccess()
                }
                guard self.session == id, self.phase == .arming else { return }
                self.mark(granted ? "permission granted" : "permission denied")
                if !granted {
                    self.fail(Voice.denied)
                } else if holding {
                    if self.releasedWhileArming { self.mark("released during the prompt") }
                    self.mark("not started: hold again")
                    self.end(nil)
                    let button = hand == .button || hand == .addon
                    self.tell(button ? Voice.allowedHoldButton : Voice.allowedHoldKey, code: "hold", for: 6)
                    self.announce(button ? "Microphone allowed. Hold the mic button to talk."
                                         : "Microphone allowed. Hold Control-Shift-D to talk.")
                } else {
                    self.open(self.makeSource(), session: id)
                }
            }
        default:
            fail(Voice.denied)
        }
    }

    /// The microphone, or the bench's file.
    private func makeSource() -> VoiceAudioSource { testSource?() ?? VoiceCapture() }

    private func open(_ source: VoiceAudioSource, session id: Int) {
        guard #available(macOS 15, *) else { fail("Voice needs macOS 15 or later."); return }
        guard let dir = ModelStore.shared.modelDir else { fail("Speech model needs attention"); return }
        // Not loaded (let go after idle minutes, or the load failed): load
        // now, while the person talks. A decode waits for it; past a second
        // the line says the model is being prepared.
        if engineState == .cold { startWarm(dir) }
        let failing = benchDecodeFails
        let decode: @Sendable ([Swift.Float]) async throws -> String = { samples in
            if failing { throw VoiceBenchError("the bench made this decode fail") }
            await Voice.untilWarm()
            // A no-op once warm; loads again if something let the model go.
            try await VoiceEngine.shared.prepare(modelDir: dir) { _ in }
            return try await VoiceEngine.shared.transcribe(samples).text
        }
        let live = LiveSession(mode: .hold, decode: decode) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { Voice.shared.heard(event, session: id) } }
        }
        do {
            try source.start(onBlock: { block in live.feed(block) }, onStop: { reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { Voice.shared.stopped(reason, session: id) } }
            })
        } catch {
            live.cancel()
            fail(Voice.words(for: error))
            return
        }
        self.live = live
        self.source = source
        slowTimer?.cancel()
        slowStart = false
        phase = .dictating
        mark("dictating")
        announce("Dictation listening")
        let cap = DispatchWorkItem { [weak self] in
            guard let self, self.session == id, self.phase == .dictating else { return }
            self.finish("cap")
        }
        capTimer = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + (benchCap ?? Voice.cap), execute: cap)
    }

    /// Release, the second press, or the 120 s cap: the microphone off, the
    /// whole hold decoded, the words in.
    func finish(_ why: String) {
        guard phase == .dictating, let live else { return }
        let id = session
        capTimer?.cancel()
        hand = nil
        phase = .finishing
        mark("finishing:\(why)")
        // Off before this returns; the converter's tail is fed first.
        source?.stop()
        Task { @MainActor in
            let text = await live.finish()
            self.land(text, decodeFailed: live.lastDecodeError != nil, session: id)
        }
    }

    private func land(_ text: String, decodeFailed: Bool, session id: Int) {
        guard id == session, phase == .finishing else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = Date()
        mark("decoded", count: words.split(whereSeparator: \.isWhitespace).count)
        // Nothing heard because the model never loaded, or a decode threw
        // (a load inside it failing, Core ML refusing): say so, once — never
        // the silence of an empty result.
        if words.isEmpty, decodeFailed || (warmFailed && engineState == .cold) {
            if decodeFailed { mark("decode failed") }
            Voice.log.error("dictation: no words; the speech model failed")
            mark("model failed")
            end(Voice.loadFailed)
            announce("Speech model failed to load")
            return
        }
        defer { end(nil) }
        if target == .sink {
            // Someone else's composer: the words are handed over once and
            // that is all — never into the draft, never sent from here. No
            // words, no hand-over: a sink set to send must not send its
            // draft for a dictation that heard nothing.
            guard !words.isEmpty else {
                mark("empty")
                return
            }
            guard let sink else {
                mark("dropped: sink gone")
                return
            }
            lastDelivered = words
            sink.dictation(final: words, finish: prefs.finish)
            mark("delivered", count: words.split(whereSeparator: \.isWhitespace).count)
            Voice.log.info("dictation: \(self.partials) partials, \(words.split(whereSeparator: \.isWhitespace).count) words, handed to the sidebar addon")
            return
        }
        guard !words.isEmpty, let anchor else {
            mark("empty")
            return
        }
        let agent = Agent.shared
        lastInsert = ComposerInsert.insert(words, at: anchor, agent: agent)
        mark("inserted", count: lastInsert?.piece.utf16.count)
        Voice.log.info("dictation: \(self.partials) partials, \(words.split(whereSeparator: \.isWhitespace).count) words, insert \(Int(Date().timeIntervalSince(heard) * 1000)) ms after the decode")
        guard prefs.finish == .send else {
            announce(Voice.insertedAnnouncement)
            return
        }
        let ready = benchAgentReady ?? agent.ready
        if ready, !agent.busy, let browser, !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastSent = agent.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            agent.send(in: browser)
            mark("sent")
            announce("Dictation sent")
        } else {
            mark(ready ? "not sent: busy" : "not sent: not ready")
            show(note: "Inserted — press Return to send", for: 6)
            announce(Voice.insertedAnnouncement)
        }
    }

    /// Escape, ✕, the pane or window closing, sleep, a tap too short: audio
    /// and partials thrown away, the draft and its selection as they were.
    func cancel(_ why: String) {
        guard active else { return }
        session += 1
        mark("cancelled:\(why)")
        live?.cancel()
        source?.stop()
        if let anchor { ComposerInsert.restore(anchor, agent: Agent.shared) }
        end(nil)
    }

    /// The app or the window lost the keyboard: a hold under way is
    /// cancelled. Not while the permission prompt is up — the prompt is what
    /// took it — and not once the hold has ended: finishing words land.
    private func lostFocus(_ why: String) {
        guard phase == .dictating else { return }
        cancel(why)
    }

    /// The capture ended without being asked: sleep, a lost device, an error.
    private func stopped(_ reason: VoiceCaptureStop, session id: Int) {
        guard id == session, phase == .dictating else { return }
        switch reason {
        case .requested:
            break
        case .sleep, .sessionResigned:
            cancel("capture stopped")
        case .deviceLost:
            cancel("device lost")
            failed("The microphone was disconnected — try again")
        case .failed:
            cancel("capture failed")
            failed("The microphone stopped — try again")
        }
    }

    private func heard(_ event: LiveEvent, session id: Int) {
        guard id == session else { return }
        switch event {
        case .partial(let text):
            guard phase == .dictating || phase == .finishing else { return }
            partials += 1
            // The same guess again (the room after the last word) is no news to a sink.
            let news = text != preview
            preview = text
            if target == .sink, news { sink?.dictation(partial: text) }
            mark("partial", count: text.split(whereSeparator: \.isWhitespace).count)
        case .final:
            mark("final")
        }
    }

    private func fail(_ message: String) {
        session += 1
        mark("error")
        live?.cancel()
        source?.stop()
        end(message)
        if message == Voice.denied { announce("Microphone access is off") }
    }

    /// Back to idle (or to an error), with everything of the dictation let go.
    private func end(_ error: String?) {
        stopTimers()
        live = nil
        source = nil
        anchor = nil
        hand = nil
        preview = ""
        slowStart = false
        phase = error.map(Phase.error) ?? .idle
        if error == nil { mark("idle") }
        if let error, target == .sink { sink?.dictation(error: Voice.code(for: error), message: error) }
        scheduleUnload()
    }

    /// An error after the dictation has already ended (the capture lost):
    /// on the composer's line, or said to the sink.
    private func failed(_ message: String) {
        phase = .error(message)
        if target == .sink { sink?.dictation(error: Voice.code(for: message), message: message) }
    }

    private func stopTimers() {
        capTimer?.cancel()
        capTimer = nil
        slowTimer?.cancel()
        slowTimer = nil
    }

    // MARK: - notes, announcements

    private func show(note text: String, for seconds: TimeInterval) {
        noteTimer?.cancel()
        note = text
        let clear = DispatchWorkItem { [weak self] in self?.note = nil }
        noteTimer = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: clear)
    }

    private func clearNote() {
        noteTimer?.cancel()
        noteTimer = nil
        note = nil
    }

    /// A brief line for whoever the press was for: the composer's note, or
    /// the sink's `error` (it draws its own line; the pane's isn't on screen).
    private func tell(_ text: String, code: String, for seconds: TimeInterval) {
        if target == .sink {
            mark("told:\(code)")
            sink?.dictation(error: code, message: text)
        } else {
            show(note: text, for: seconds)
        }
    }

    /// VoiceOver, once per change of state — never for a partial.
    private func announce(_ text: String) {
        announced.append(text)
        mark("announce:\(text)")
        guard let element = window ?? NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func mark(_ event: String, count: Int? = nil) {
        timeline.append((Int(Date().timeIntervalSince(origin) * 1000), event, count))
    }

    static func words(for error: Error) -> String {
        switch error as? VoiceCaptureError {
        case .notAuthorized: return Voice.denied
        case .noInput: return "No microphone is connected"
        case .headless: return "Dictation isn't available in headless Copper"
        default: return "The microphone couldn't start — try again"
        }
    }

    // MARK: - the engine, warm and then let go

    /// The pane is open with voice ready: load the model now (a third of a
    /// second once this Mac has prepared it), so the first dictation doesn't wait.
    /// The sidebar addon that dictates (AddonVoice.wantsWarm) needs no agent
    /// of Copper's, so it warms the model without one.
    func warm() {
        guard #available(macOS 15, *), VoicePrefs.supported, prefs.enabled, Agent.shared.open,
              Agent.shared.ready || AddonVoice.wantsWarm,
              seededModel == nil, ModelStore.shared.state == .ready, let dir = ModelStore.shared.modelDir else { return }
        startWarm(dir)
    }

    /// Listen is starting: the model loaded (or loading) whether or not the
    /// pane's agent is set up — its decodes wait for the load.
    func ensureWarm() {
        guard #available(macOS 15, *), engineState == .cold, let dir = ModelStore.shared.modelDir else { return }
        unloadTimer?.cancel()
        startWarm(dir)
    }

    /// One load at a time; nothing when loaded. Past `slowLoad` the mic
    /// shows the model is being prepared.
    @available(macOS 15, *)
    private func startWarm(_ dir: URL) {
        guard engineState == .cold, warmTask == nil else { return }
        warmGeneration += 1
        let id = warmGeneration
        engineState = .warming
        engineSlow = false
        warmFailed = false
        if active { mark("engine loading") }
        let slow = DispatchWorkItem { [weak self] in
            guard let self, self.warmGeneration == id, self.engineState == .warming else { return }
            self.engineSlow = true
            Voice.log.info("voice: speech model still loading after \(Voice.slowLoad, privacy: .public) s — preparing")
            if self.active {
                self.mark("engine preparing")
                self.announce("Preparing speech model")
            }
        }
        warmTimer?.cancel()
        warmTimer = slow
        DispatchQueue.main.asyncAfter(deadline: .now() + Voice.slowLoad, execute: slow)
        let delay = benchWarmDelay
        warmTask = Task { @MainActor in
            let started = Date()
            if let delay { try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)) }
            var ok = true
            do { try await VoiceEngine.shared.prepare(modelDir: dir) { _ in } } catch { ok = false }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard self.warmGeneration == id else { return ok }
            self.warmTimer?.cancel()
            self.warmTimer = nil
            self.warmTask = nil
            self.engineSlow = false
            self.engineState = ok ? .warm : .cold
            self.warmFailed = !ok
            if ok { Voice.log.info("voice warm in \(ms) ms") } else { Voice.log.error("voice warm failed after \(ms) ms") }
            if self.active { self.mark(ok ? "engine warm" : "engine failed") }
            self.scheduleUnload()
            return ok
        }
    }

    /// For a decode: the load in flight, if one is (the first on this Mac
    /// can take a minute), finished.
    static func untilWarm() async {
        if let task = shared.warmTask { _ = await task.value }
    }

    /// The model went away or changed: whatever was loaded or loading is not
    /// this one. A load in flight finishes unheard.
    private func resetEngine() {
        warmGeneration += 1
        warmTask = nil
        warmTimer?.cancel()
        warmTimer = nil
        engineSlow = false
        engineState = .cold
    }

    /// Ten minutes without a dictation lets the model go (100–200 MB) —
    /// never while Listen is capturing (it calls this when it stops).
    func scheduleUnload() {
        unloadTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.active, !Listen.shared.capturing, !PageVoice.shared.listening,
                  self.engineState != .warming else { return }
            self.resetEngine()
            if #available(macOS 15, *) { Task { await VoiceEngine.shared.unload() } }
            Voice.log.info("voice model unloaded after 10 idle minutes")
        }
        unloadTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Voice.idleUnload, execute: work)
    }

    /// The bench: the model let go now, as after idle minutes, and every
    /// load from here on held `delay` seconds first; then warmed as the
    /// pane opening does (when `start`).
    func benchCold(delay: TimeInterval?, start: Bool) async {
        resetEngine()
        if #available(macOS 15, *) { await VoiceEngine.shared.unload() }
        benchWarmDelay = delay
        if start { warm() }
    }

    /// The bench: loaded through `warm`, as the open pane has it.
    func benchWarmed() async -> Bool {
        warm()
        if let task = warmTask { return await task.value }
        return engineState == .warm
    }

    // MARK: - bench

    /// The frozen states the pane is pictured in (`voice seed`).
    func seed(_ scenario: String, in browser: Browser) -> String? {
        cancel("seed")
        stopTimers()
        clearNote()
        seededModel = nil
        seededWarming = false
        self.browser = browser
        self.window = Windows.window(of: browser)
        aim(at: nil)
        let words = "open the Copper agent pane, check the API logs on the staging server and file a bug for the failing Swift build"
        switch scenario {
        case "idle", "idle-with-mic": phase = .idle; preview = ""
        case "dictating": phase = .dictating; preview = words
        case "dictating-short": phase = .dictating; preview = "open the Copper"
        case "finishing": phase = .finishing; preview = words
        case "denied": phase = .error(Voice.denied); preview = ""
        case "preparing": phase = .idle; seededModel = .preparing
        case "warming": phase = .idle; seededWarming = true; note = Voice.preparingNote
        case "finishing-warming": phase = .finishing; preview = ""; seededWarming = true
        case "downloading": phase = .idle; seededModel = .downloading(0.42)
        case "failed": phase = .idle; seededModel = .failed("seeded")
        case "hint": phase = .idle; note = "Hold to talk"
        case "inserted": phase = .idle; note = "Inserted — press Return to send"
        case "off": phase = .idle; preview = ""
        default: return "voice seed idle|dictating|dictating-short|finishing|finishing-warming|denied|preparing|warming|downloading|failed|hint|inserted|off"
        }
        return nil
    }

    func benchState() -> [String: Any] {
        var out: [String: Any] = [
            "phase": Voice.name(phase), "previewWords": preview.split(whereSeparator: \.isWhitespace).count,
            "note": note ?? NSNull(), "session": session, "enabled": prefs.enabled, "trigger": prefs.trigger.rawValue,
            "finish": prefs.finish.rawValue, "paneOpen": Agent.shared.open, "draft": Agent.shared.draft,
            "agentReady": Agent.shared.ready, "agentBusy": Agent.shared.busy, "model": ModelStore.shared.stateName,
            "testSource": testSource != nil, "keysConsumed": VoiceKeys.consumed, "keysPassed": VoiceKeys.passed,
            "announced": announced, "partials": partials, "engine": engineState.rawValue, "engineSlow": engineSlow,
            "refusedPreparing": refusedPreparing, "undoFollowed": ComposerInsert.followed,
            "listen": Listen.name(Listen.shared.phase),
            "target": target.rawValue,
            "timeline": timeline.map { row -> [String: Any] in
                var r: [String: Any] = ["ms": row.ms, "event": row.event]
                if let n = row.count { r["n"] = n }
                return r
            },
        ]
        switch mic(agentReady: Agent.shared.ready) {
        case .hidden: out["mic"] = "hidden"
        case .unavailable(let why): out["mic"] = "unavailable: \(why)"
        case .waiting(let why): out["mic"] = "waiting: \(why)"
        case .preparing: out["mic"] = "preparing: \(Voice.preparingHelp)"
        case .ready: out["mic"] = "ready"
        }
        switch line {
        case .live(let lead, let words)?: out["line"] = words.isEmpty ? lead : "\(lead) \(words)"
        case .plain(let text)?: out["line"] = text
        case .denied?: out["line"] = Voice.denied
        case nil: out["line"] = NSNull()
        }
        if case .error(let message) = phase { out["message"] = message }
        if let lastInsert { out["inserted"] = lastInsert.piece; out["insertedVia"] = lastInsert.via; out["caret"] = lastInsert.caret }
        out["sendCalled"] = lastSent != nil
        if let lastSent { out["sent"] = lastSent }
        if let lastDelivered { out["delivered"] = lastDelivered }
        return out
    }

    /// Tests and the bench: a dictation that has just been let go, landing
    /// `text` exactly as a decode's words land — handed to `sink`, or, with
    /// none, put in the composer at `range` of the draft (its end when nil).
    /// No microphone, no model, no window. With `sendReady` false a "Send
    /// right away" is held back as an agent that isn't set up holds it.
    func benchLand(_ text: String, for sink: DictationSink?, range: NSRange? = nil, sendReady: Bool = false) {
        cancel("bench")
        stopTimers()
        session += 1
        aim(at: sink)
        timeline = []
        lastInsert = nil
        lastSent = nil
        lastDelivered = nil
        origin = Date()
        if sink == nil {
            let draft = Agent.shared.draft
            let at = range ?? NSRange(location: (draft as NSString).length, length: 0)
            anchor = ComposerInsert.Anchor(draft: draft, range: ComposerInsert.clamp(at, in: draft), editor: nil, window: nil)
        } else {
            anchor = nil
        }
        let saved = benchAgentReady
        benchAgentReady = sendReady
        defer { benchAgentReady = saved }
        live = nil
        phase = .finishing
        land(text, decodeFailed: false, session: session)
    }

    static func name(_ phase: Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .arming: return "arming"
        case .dictating: return "dictating"
        case .finishing: return "finishing"
        case .error: return "error"
        }
    }
}

/// A file instead of the microphone, for tests: its samples in 50 ms blocks
/// at real time (or `speed` times it), then room-quiet until stopped, as a
/// microphone keeps hearing the room after someone stops talking.
final class VoiceFileSource: VoiceAudioSource, @unchecked Sendable {
    private let samples: [Swift.Float]
    private let speed: Double
    private let failAt: Double?
    private let queue = DispatchQueue(label: "com.collinrijock.copper.voice.file", qos: .userInitiated)
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var run: Run?
    private var drainedFlag = false

    private final class Run {
        let onBlock: @Sendable ([Swift.Float]) -> Void
        let onStop: @Sendable (VoiceCaptureStop) -> Void
        var timer: DispatchSourceTimer?
        var position = 0
        var finished = false
        init(onBlock: @escaping @Sendable ([Swift.Float]) -> Void, onStop: @escaping @Sendable (VoiceCaptureStop) -> Void) {
            self.onBlock = onBlock
            self.onStop = onStop
        }
    }

    /// `speed` 1 is real time; 0 feeds as fast as the queue goes. `failAt`
    /// (seconds of audio) ends the capture with an error there.
    init(samples: [Swift.Float], speed: Double = 1, failAt: Double? = nil) {
        self.samples = samples
        self.speed = speed
        self.failAt = failAt
        queue.setSpecific(key: onQueueKey, value: true)
    }

    /// Every sample of the file has been handed over.
    var drained: Bool { lock.withLock { drainedFlag } }

    func start(onBlock: @escaping @Sendable ([Swift.Float]) -> Void,
               onStop: @escaping @Sendable (VoiceCaptureStop) -> Void) throws {
        let fresh = Run(onBlock: onBlock, onStop: onStop)
        try lock.withLock {
            guard run == nil else { throw VoiceCaptureError.busy }
            run = fresh
            drainedFlag = false
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let every = speed > 0 ? 0.05 / speed : 0.001
        timer.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick(fresh) }
        fresh.timer = timer
        timer.resume()
    }

    private func tick(_ run: Run) {
        guard !run.finished else { return }
        if let failAt, run.position >= Int(failAt * 16_000) {
            finish(run, .failed("test failure"))
            return
        }
        var block: [Swift.Float]
        if run.position < samples.count {
            block = Array(samples[run.position..<min(run.position + 800, samples.count)])
            if block.count < 800 { block += VoiceBench.roomQuiet(seconds: Double(800 - block.count) / 16_000) }
            if run.position + 800 >= samples.count { lock.withLock { drainedFlag = true } }
        } else {
            block = VoiceBench.roomQuiet(seconds: 0.05)
        }
        run.position += 800
        run.onBlock(block)
    }

    private func finish(_ run: Run, _ reason: VoiceCaptureStop) {
        lock.withLock { if self.run === run { self.run = nil } }
        run.timer?.cancel()
        guard !run.finished else { return }
        run.finished = true
        run.onStop(reason)
    }

    func stop() {
        guard let current = lock.withLock({ run }) else { return }
        if DispatchQueue.getSpecific(key: onQueueKey) == true { finish(current, .requested) }
        else { queue.sync { finish(current, .requested) } }
    }
}
