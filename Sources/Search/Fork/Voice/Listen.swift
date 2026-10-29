import AppKit
import AVFoundation
import Combine
import Foundation
import os

// Listen: a live transcript someone starts from the ⌘E agent pane, which the
// pane's agent can read (Agent.swift: the "Live transcript" chip and the
// pane-private `transcript_read` tool) — and, only when the person allows it
// in Settings › Intelligence › Voice, agents on this Mac (docs/agents.md).
//
// One microphone capture feeds one LiveSession in `.listen` mode, which
// finalizes a line each time the speaker pauses (0.7 s) or at 14.95 s of
// unbroken speech. Each final goes into `Transcript.shared` with its
// wall-clock time; partials only move the card (ListenUI.swift).
//
//   off → arming → live ⇄ paused(reason) → stopped → (Listen again) arming …
//                                        ↘ Forget / New chat / voice off → off
//
// Pause and Stop keep the transcript; Resume and Listen again start a new
// capture and a new LiveSession into the SAME transcript (seq keeps
// counting). The pane closing, sleep, the screen locking, the microphone
// going away pause it, with the reason; the window closing stops it; nothing
// ever resumes by itself. Unlike a dictation, switching to another app does
// not pause it: a meeting goes on in another app.
//
// One capture at a time: while Listen is live or paused the dictation mic and
// ⌃⇧D are off ("Stop Listen to dictate"), and while a dictation runs the
// Listen door is.
//
// Words stay in memory (Transcript.swift); the log carries counts and times only.

@MainActor
final class Listen: ObservableObject {
    static let shared = Listen()

    enum Phase: Equatable {
        /// No transcript card (never started, or forgotten).
        case off
        /// Asking for the microphone, or opening it.
        case arming
        case live
        /// Not capturing, with why: "you paused", "pane closed", …
        case paused(String)
        /// Stopped by the person; the transcript stays until Forget.
        case stopped
    }

    @Published private(set) var phase: Phase = .off
    /// The phrase in flight — a guess that changes. The card's grey line only.
    @Published private(set) var partial = ""
    /// The card's transcript list is open. Kept here, so closing the pane doesn't fold it.
    @Published var expanded = false
    /// When the capture now running went live (nil when none is).
    @Published private(set) var liveSince: Date?
    /// Listening time before the capture now running: what the card's clock adds to.
    @Published private(set) var elapsedBefore: TimeInterval = 0

    nonisolated static let youPaused = "you paused"
    nonisolated static let paneClosed = "pane closed"
    nonisolated static let slept = "Mac went to sleep"
    nonisolated static let deviceLost = "microphone disconnected"
    nonisolated static let locked = "screen locked"
    nonisolated static let denied = "microphone access is off"
    nonisolated static let modelGone = "speech model isn't ready"
    /// The dictation mic's tooltip (and ⌃⇧D's note) while Listen holds the microphone.
    nonisolated static let blocksDictation = "Stop Listen to dictate"

    /// The window and browser Listen was started from.
    private(set) weak var browser: Browser?
    private(set) weak var window: NSWindow?
    /// The current capture's number; bumped by every start and every end.
    private var capture = 0
    /// Captures that have ended but whose last phrase is still being decoded:
    /// their finals still land.
    private var draining: Set<Int> = []
    /// When each capture's first sample was heard: a final's t0/t1 count from it.
    private var starts: [Int: Date] = [:]
    private var source: VoiceAudioSource?
    private var live: LiveSession?
    private var booted = false
    private var bag: Set<AnyCancellable> = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    private static let log = Logger(subsystem: "com.collinrijock.copper", category: "voice")

    // MARK: - test hooks (bench only)

    /// A file instead of the microphone (`voice listen start --source PATH`).
    var testSource: (() -> VoiceAudioSource)?
    /// With a test source: the permission macOS would report, and the answer
    /// a question would get after `seconds` — no prompt is ever shown.
    var benchPermission: (status: AVAuthorizationStatus, grant: Bool, seconds: Double)?
    /// VoiceOver announcements made, in order (bench).
    private(set) var announced: [String] = []
    /// Partials and finals heard since the last start (bench; counts only).
    private(set) var partials = 0
    private(set) var finals = 0

    private init() {}

    // MARK: - launch

    /// At launch (Voice.boot): what pauses, stops and forgets a Listen. Idempotent.
    func boot() {
        guard !booted else { return }
        booted = true
        Agent.shared.$open.removeDuplicates().sink { [weak self] open in
            guard let self, !open else { return }
            self.pause(Listen.paneClosed)
        }.store(in: &bag)
        // Voice off hides every trace of voice in the pane: the transcript goes too.
        VoicePrefs.shared.$enabled.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self, !on else { return }
            DispatchQueue.main.async { self.forget() }
        }.store(in: &bag)
        ModelStore.shared.$state.removeDuplicates().sink { [weak self] state in
            guard let self, state != .ready else { return }
            self.pause(Listen.modelGone)
        }.store(in: &bag)
        // A transcript begun (here, or by a seed) has the agent's chip on;
        // one forgotten anywhere takes the card away.
        Transcript.shared.$id.removeDuplicates().dropFirst().sink { [weak self] id in
            guard let self else { return }
            if id != nil {
                Agent.shared.transcriptContext = true
            } else if self.phase != .off {
                DispatchQueue.main.async { if Transcript.shared.id == nil { self.drop() } }
            }
        }.store(in: &bag)

        let center = NotificationCenter.default
        tokens.append((center, center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, window === Listen.shared.window { Listen.shared.stop() }
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Listen.shared.pause(Listen.slept) }
        }))
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Listen.shared.pause(Listen.locked) }
        }))
        let distributed = DistributedNotificationCenter.default()
        tokens.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Listen.shared.pause(Listen.locked) }
        }))
    }

    // MARK: - what the pane shows

    /// The microphone is Listen's: starting, live, or paused. Dictation waits.
    var holdsMic: Bool {
        switch phase {
        case .arming, .live, .paused: return true
        case .off, .stopped: return false
        }
    }

    /// A capture is running (or opening) right now.
    var capturing: Bool { phase == .arming || phase == .live }

    /// Listening time so far, at `date`.
    func duration(at date: Date = Date()) -> TimeInterval {
        elapsedBefore + (liveSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }

    /// What the header's Listen door shows.
    enum Door: Equatable {
        /// Voice is off (or can't be on this Mac).
        case hidden
        /// Listen is capturing: a click does nothing; the card has the controls.
        case on(String)
        /// A dictation has the microphone: disabled.
        case busy(String)
        /// The speech model isn't ready: dimmed; a click opens Settings › Intelligence › Voice.
        case waiting(String)
        case ready
    }

    var door: Door {
        let voice = Voice.shared
        switch voice.speechModel() {
        case .hidden: return .hidden
        default: break
        }
        // Live: the card has the controls. Paused or stopped, a click listens
        // on into the same transcript, as the card's Resume and Listen again do.
        if capturing { return .on("Listening — Pause or Stop in the card below") }
        if voice.active { return .busy("Finish dictating to Listen") }
        switch voice.speechModel() {
        case .waiting(let why), .unavailable(let why): return .waiting(why)
        case .preparing: return .waiting(Voice.preparingHelp)
        case .hidden: return .hidden
        case .ready: return .ready
        }
    }

    /// The door clicked: Listen starts (or, paused or stopped, listens on into
    /// the same transcript); the speech model not ready opens Settings › Intelligence › Voice.
    func doorPressed(in browser: Browser) {
        switch door {
        case .hidden, .on, .busy: return
        case .waiting: browser.openSettings(.intelligence, at: "voice.enabled")
        case .ready: start(in: browser)
        }
    }

    // MARK: - one capture

    /// Starts listening from this browser's pane. A transcript is begun when
    /// there is none; otherwise this listens on into it (Resume, Listen again).
    func start(in browser: Browser) {
        switch phase {
        case .arming, .live: return
        case .off, .paused, .stopped: break
        }
        guard VoicePrefs.supported, VoicePrefs.shared.enabled, !Voice.shared.active else { return }
        if Transcript.shared.id == nil {
            Transcript.shared.begin()
            elapsedBefore = 0
            Agent.shared.transcriptContext = true
        }
        self.browser = browser
        window = Windows.window(of: browser)
        capture += 1
        let id = capture
        partial = ""
        partials = 0
        finals = 0
        phase = .arming

        if testSource == nil {
            // The real microphone: never in headless Copper, and in a test
            // world only when the run says so (as for a dictation).
            if Headless.on { halt(id, "not available in headless Copper"); return }
            if Store.testing, ProcessInfo.processInfo.environment["SEARCH_VOICE_MIC"] != "1" {
                halt(id, "microphone is off in test worlds")
                return
            }
        }
        let fake = testSource == nil ? nil : benchPermission
        let status = fake?.status ?? (testSource != nil ? .authorized : VoiceCapture.authorization)
        switch status {
        case .authorized:
            open(id)
        case .notDetermined:
            // The first use asks. Allow starts what was asked for: a click,
            // not a hold, so there is nothing to have let go of meanwhile.
            Task { @MainActor in
                let granted: Bool
                if let fake {
                    try? await Task.sleep(nanoseconds: UInt64(fake.seconds * 1_000_000_000))
                    granted = fake.grant
                } else {
                    granted = await VoiceCapture.requestAccess()
                }
                guard self.capture == id, self.phase == .arming else { return }
                if granted { self.open(id) } else { self.halt(id, Listen.denied) }
            }
        default:
            halt(id, Listen.denied)
        }
    }

    /// Resume, or Listen again: a new capture into the same transcript.
    func resume(in browser: Browser) { start(in: browser) }

    private func open(_ id: Int) {
        guard #available(macOS 15, *) else { halt(id, "needs macOS 15"); return }
        guard let dir = ModelStore.shared.modelDir else { halt(id, Listen.modelGone); return }
        Voice.shared.ensureWarm()
        let decode: @Sendable ([Swift.Float]) async throws -> String = { samples in
            await Voice.untilWarm()
            // A no-op once warm; loads again if something let the model go.
            try await VoiceEngine.shared.prepare(modelDir: dir) { _ in }
            return try await VoiceEngine.shared.transcribe(samples).text
        }
        let session = LiveSession(mode: .listen, decode: decode) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { Listen.shared.heard(event, capture: id) } }
        }
        let source = testSource?() ?? VoiceCapture()
        let began = Date()
        do {
            try source.start(onBlock: { block in session.feed(block) }, onStop: { reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { Listen.shared.stopped(reason, capture: id) } }
            })
        } catch {
            session.cancel()
            halt(id, Listen.reason(for: error))
            return
        }
        // Times only go forward in one transcript: a capture heard faster than
        // real time (a file, in the bench) can end "later" than now, and the
        // next one resumes from there. With the microphone this is `began`.
        starts[id] = max(began, Transcript.shared.segments.last?.end ?? began)
        self.source = source
        live = session
        liveSince = Date()
        phase = .live
        Transcript.shared.setLive(true)
        Listen.log.info("listen: capture \(id) live")
        announce("Listening")
    }

    /// Pause (the card), or something that took the microphone away. The
    /// phrase in flight is still decoded into the transcript.
    func pause(_ reason: String = Listen.youPaused) {
        guard capturing else { return }
        endCapture(keepLast: true)
        phase = .paused(reason)
        announce("Listen paused")
    }

    /// Stop (the card), or the window closing. The transcript stays.
    func stop() {
        guard holdsMic else { return }
        endCapture(keepLast: true)
        phase = .stopped
        announce("Listen stopped")
    }

    /// Forget (the card), voice turned off: no capture, no transcript, no card.
    func forget() {
        drop()
        if Transcript.shared.id != nil { Transcript.shared.forget() }
    }

    /// New chat: Listen stops and its transcript is forgotten.
    func newChat() {
        forget()
    }

    /// Everything of Listen let go, the transcript left to whoever called.
    private func drop() {
        let was = phase
        endCapture(keepLast: false)
        draining = []
        starts = [:]
        elapsedBefore = 0
        expanded = false
        phase = .off
        if was == .live || was == .arming { announce("Listen stopped") }
    }

    /// Could not start (or go on): paused, with why. The transcript stays.
    private func halt(_ id: Int, _ reason: String) {
        guard id == capture else { return }
        endCapture(keepLast: false)
        phase = .paused(reason)
        Listen.log.info("listen: capture \(id) did not start")
        announce("Listen paused")
    }

    /// The capture now running ends: the microphone off before this returns;
    /// with `keepLast` the phrase in flight is decoded and lands, else dropped.
    private func endCapture(keepLast: Bool) {
        let id = capture
        capture += 1
        if let liveSince { elapsedBefore += max(Date().timeIntervalSince(liveSince), 0) }
        liveSince = nil
        partial = ""
        let session = live, src = source
        live = nil
        source = nil
        src?.stop()
        if let session {
            if keepLast {
                draining.insert(id)
                Task { @MainActor in
                    _ = await session.finish()
                    // After the final's own hop to the main queue.
                    DispatchQueue.main.async { MainActor.assumeIsolated { Listen.shared.drained(id) } }
                }
            } else {
                session.cancel()
                starts[id] = nil
            }
        } else {
            starts[id] = nil
        }
        if Transcript.shared.live { Transcript.shared.setLive(false) }
        Voice.shared.scheduleUnload()
    }

    private func drained(_ id: Int) {
        draining.remove(id)
        starts[id] = nil
    }

    private func heard(_ event: LiveEvent, capture id: Int) {
        switch event {
        case .partial(let text):
            guard id == capture, phase == .live else { return }
            partials += 1
            partial = text
        case .final(let segment):
            guard id == capture || draining.contains(id), let began = starts[id] else { return }
            let start = began.addingTimeInterval(Double(segment.t0ms) / 1000)
            let end = began.addingTimeInterval(Double(segment.t1ms) / 1000)
            guard Transcript.shared.append(segment.text, start: start, end: end) != nil else { return }
            finals += 1
            if id == capture { partial = "" }
        }
    }

    /// The capture ended without being asked: sleep, a session switch, a
    /// lost device, an error. Paused, with why; never resumed by itself.
    private func stopped(_ reason: VoiceCaptureStop, capture id: Int) {
        guard id == capture, phase == .live else { return }
        switch reason {
        case .requested: break
        case .sleep: pause(Listen.slept)
        case .sessionResigned: pause(Listen.locked)
        case .deviceLost: pause(Listen.deviceLost)
        case .failed: pause("microphone stopped")
        }
    }

    static func reason(for error: Error) -> String {
        switch error as? VoiceCaptureError {
        case .notAuthorized: return Listen.denied
        case .noInput: return "no microphone is connected"
        case .headless: return "not available in headless Copper"
        case .busy: return "microphone is busy"
        default: return "microphone couldn't start"
        }
    }

    /// VoiceOver, once per change of state — never per line.
    private func announce(_ text: String) {
        announced.append(text)
        guard let element = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - words

    /// "02:14", or "1:02:14" past an hour.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(max(seconds, 0))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "Listening · 02:14", "Paused · you paused", "Transcript · 14:02".
    func title(at date: Date = Date()) -> String {
        switch phase {
        case .off: return ""
        case .arming: return "Starting microphone…"
        case .live: return "Listening · \(Listen.clock(duration(at: date)))"
        case .paused(let why): return "Paused · \(why)"
        case .stopped: return "Transcript · \(Listen.clock(duration(at: date)))"
        }
    }

    static func name(_ phase: Phase) -> String {
        switch phase {
        case .off: return "off"
        case .arming: return "arming"
        case .live: return "live"
        case .paused: return "paused"
        case .stopped: return "stopped"
        }
    }

    // MARK: - bench

    /// The card frozen in a state, with a made-up meeting in the transcript
    /// (`voice seed listening|listen-expanded|listen-paused|listen-stopped`).
    func seed(_ scenario: String, in browser: Browser) -> String? {
        let wanted: Phase
        switch scenario {
        case "listening", "listen-expanded": wanted = .live
        case "listen-paused": wanted = .paused(Listen.youPaused)
        case "listen-stopped": wanted = .stopped
        default: return "voice seed listening|listen-expanded|listen-paused|listen-stopped"
        }
        forget()
        self.browser = browser
        window = Windows.window(of: browser)
        let now = Date()
        let began = now.addingTimeInterval(-134)
        Transcript.shared.begin(at: began)
        let lines: [(Double, Double, String)] = [
            (2, 6.5, "Okay, let's get started. First item is the release on Thursday."),
            (8, 14.2, "The build is green on main, but the accessibility fix still needs a review before it can go in."),
            (16, 20.4, "Priya, can you take that one? I'd like it merged by Wednesday night."),
            (22, 27.8, "Sure. I'll also check the colour contrast against the design guide while I'm there."),
            (31, 39.6, "Next, pricing. The new tier goes live on the first, and support needs the updated FAQ by Monday."),
            (42, 47.1, "Let's keep the old plan for existing customers until the end of the year."),
            (52, 58.9, "Action items: Priya on the review, Sam on the FAQ, and I'll send the notes after this."),
            (63, 66.0, "Anything else before we wrap up?"),
        ]
        for (t0, t1, text) in lines {
            Transcript.shared.append(text, start: began.addingTimeInterval(t0), end: began.addingTimeInterval(t1))
        }
        Agent.shared.transcriptContext = true
        expanded = scenario == "listen-expanded"
        partial = ""
        switch wanted {
        case .live:
            elapsedBefore = 0
            liveSince = began
            partial = "one more thing on the pricing page, the annual toggle"
            Transcript.shared.setLive(true)
        case .stopped:
            elapsedBefore = 842
            liveSince = nil
        default:
            elapsedBefore = 134
            liveSince = nil
        }
        phase = wanted
        announced = []
        return nil
    }

    func benchState(last: Int = 5) -> [String: Any] {
        let transcript = Transcript.shared
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let origin = transcript.startedAt
        var out: [String: Any] = [
            "phase": Listen.name(phase), "partial": partial, "live": transcript.live,
            "segments": transcript.segments.count, "latestSeq": transcript.latestSeq, "oldestSeq": transcript.oldestSeq,
            "transcript": transcript.id ?? NSNull(), "duration_s": VoiceBench.rounded(duration(), 2),
            "title": title(), "expanded": expanded, "announced": announced, "partials": partials, "finals": finals,
            "draining": draining.count, "chip": Agent.shared.transcriptContext, "paneOpen": Agent.shared.open,
            "testSource": testSource != nil,
        ]
        if case .paused(let why) = phase { out["reason"] = why }
        switch door {
        case .hidden: out["door"] = "hidden"
        case .on(let why): out["door"] = "on: \(why)"
        case .busy(let why): out["door"] = "busy: \(why)"
        case .waiting(let why): out["door"] = "waiting: \(why)"
        case .ready: out["door"] = "ready"
        }
        out["last"] = transcript.segments.suffix(max(last, 0)).map { segment -> [String: Any] in
            var row: [String: Any] = ["seq": segment.seq, "start": iso.string(from: segment.start), "end": iso.string(from: segment.end),
                                      "text": segment.text]
            if let origin {
                row["t0_s"] = VoiceBench.rounded(segment.start.timeIntervalSince(origin), 2)
                row["t1_s"] = VoiceBench.rounded(segment.end.timeIntervalSince(origin), 2)
            }
            return row
        }
        if let origin { out["startedAt"] = iso.string(from: origin) }
        return out
    }

    /// The microphone going away, as the capture reports it (bench).
    func benchDeviceLost() { stopped(.deviceLost, capture: capture) }

    /// Once the capture now running has had its say: no decode running or
    /// due, and every final that came of it in the transcript (bench).
    func benchSettle() async {
        if let live { await live.drain() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let limit = Date().addingTimeInterval(30)
        while !draining.isEmpty, Date() < limit { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
}
