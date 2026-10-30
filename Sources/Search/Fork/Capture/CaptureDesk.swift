import AppKit
import AVFoundation
import Combine
import SwiftUI
import WebKit

// Fork (page-capture): one window's side of pages asking for the camera and
// the microphone — the requests waiting for an answer, the bar that asks
// (CaptureBar.swift), and what macOS itself allows Copper. The rules for who
// is asked what, and what is remembered, are CaptureChoices.swift; keeping a
// call's page alive and heard while you look at another tab is
// CaptureCalls.swift. docs/capture.md tells the whole story.
//
// Browser.swift's WKUIDelegate method hands every request here, and only
// here: WebKit holds the page's getUserMedia() until its decision handler is
// called, and raises if one is ever dropped, so each one is wrapped in a
// `CaptureAnswer` that is called exactly once — with "no" if nothing else
// called it before it goes.

/// One page's request: WebKit's decision handler, called exactly once.
final class CaptureAnswer {
    private var decide: ((WKPermissionDecision) -> Void)?
    /// The page that asked, and the host it was on when it asked: a page that
    /// has since closed or gone elsewhere is no longer waiting.
    private(set) weak var web: WKWebView?
    let host: String

    init(web: WKWebView?, host: String, _ decide: @escaping (WKPermissionDecision) -> Void) {
        self.web = web
        self.host = host
        self.decide = decide
    }

    func callAsFunction(_ decision: WKPermissionDecision) {
        guard let decide else { return }
        self.decide = nil
        decide(decision)
    }

    /// Still worth asking about: the page is open, on the site that asked.
    /// A closed tab's view can outlive it for a while, but it has let go of
    /// its delegate (Tab.discard): nobody is waiting there any more.
    var waiting: Bool {
        guard decide != nil, let web, web.uiDelegate != nil else { return false }
        guard let now = web.url?.host(), !host.isEmpty else { return true }
        return now.caseInsensitiveCompare(host) == .orderedSame
    }

    deinit { decide?(.deny) }
}

/// What macOS lets Copper use (System Settings › Privacy & Security). WebKit
/// checks it before Copper is ever asked — a device macOS refuses is refused
/// to the page without a word, and one it hasn't been asked about yet is
/// asked about by WebKit first — so Copper looks again when a page is refused
/// and when you answer Allow, and says so in the bar instead of failing quietly.
@MainActor
enum CaptureSystem {
    enum State: Equatable {
        case ready
        /// macOS hasn't asked yet about these.
        case undetermined(CaptureDevices)
        /// macOS refuses these; `restricted` when it is not yours to change
        /// (a managed Mac, Screen Time).
        case blocked(CaptureDevices, restricted: Bool)
    }

    /// WebKit's stand-in devices, for test worlds only (`capture.mock`,
    /// CapturePreferences.configure): no hardware, no macOS question.
    static var mock: Bool { CapturePreferences.mock }

    private static func type(_ device: CaptureDevices) -> AVMediaType { device == .camera ? .video : .audio }

    static func status(_ device: CaptureDevices) -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: type(device))
    }

    static func state(_ devices: CaptureDevices) -> State {
        guard !mock else { return .ready }
        var undetermined: CaptureDevices = [], blocked: CaptureDevices = [], restricted = false
        for device in [CaptureDevices.microphone, .camera] where devices.contains(device) {
            switch status(device) {
            case .authorized: break
            case .notDetermined: undetermined.insert(device)
            case .restricted: blocked.insert(device); restricted = true
            default: blocked.insert(device)
            }
        }
        if !blocked.isEmpty { return .blocked(blocked, restricted: restricted) }
        if !undetermined.isEmpty { return .undetermined(undetermined) }
        return .ready
    }

    /// macOS's own question, for what it hasn't asked about yet — only ever
    /// after you answered Allow in the bar. True when everything was allowed.
    static func request(_ devices: CaptureDevices) async -> Bool {
        var all = true
        for device in [CaptureDevices.microphone, .camera] where devices.contains(device) {
            if !(await AVCaptureDevice.requestAccess(for: type(device))) { all = false }
        }
        return all
    }

    /// System Settings › Privacy & Security, on the device's own list.
    static func settingsURL(_ devices: CaptureDevices) -> URL {
        let pane = devices.contains(.microphone) ? "Privacy_Microphone" : "Privacy_Camera"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// The sites' remembered answers, one set for every window, kept in
/// Copper's settings (`capture.sites`). The older per-type keys are read
/// once and folded in (CaptureChoices.load).
@MainActor
enum CaptureBook {
    static var choices: CaptureChoices = load() {
        didSet {
            guard choices != oldValue else { return }
            if choices.allowed.isEmpty {
                Store.settings.removeObject(forKey: CaptureChoices.key)
            } else {
                Store.settings.set(choices.encoded, forKey: CaptureChoices.key)
            }
        }
    }

    private static func load() -> CaptureChoices {
        let (choices, spent) = CaptureChoices.load(from: Store.settings.dictionaryRepresentation())
        if !spent.isEmpty {
            for key in spent { Store.settings.removeObject(forKey: key) }
            if !choices.allowed.isEmpty { Store.settings.set(choices.encoded, forKey: CaptureChoices.key) }
        }
        return choices
    }

    /// Settings › Privacy › Forget choices: every site asks again.
    static func forgetAll() {
        choices.forgetAll()
        // Anything written under the old shape, too.
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix(CaptureChoices.prefix) && key.contains("|") {
            Store.settings.removeObject(forKey: key)
        }
    }
}

@MainActor
final class CaptureDesk: ObservableObject {
    /// What the bar at the bottom of the window says, if anything.
    enum Bar: Equatable {
        /// A site waiting for an answer.
        case ask(CaptureQuestion)
        /// Just refused — a few seconds to change your mind.
        case refused(site: String, devices: CaptureDevices)
        /// macOS keeps Copper from these; `restricted`: not yours to change.
        case system(CaptureDevices, restricted: Bool)
        /// macOS allows them now: the pages it refused can load again and ask.
        case restored(CaptureDevices)
        /// The tab on screen had these paused by WebKit for another page
        /// that is still using them (CaptureCalls).
        case paused(site: String, devices: CaptureDevices, tab: UUID)
        /// A listed site asking for Copper's on-device speech to text
        /// (Fork/Voice/PageVoice.swift) — asked once no camera or microphone
        /// question is waiting.
        case voice(host: String, tab: UUID?)

        /// The question, when the bar is asking one.
        var question: CaptureQuestion? {
            if case let .ask(question) = self { return question }
            return nil
        }
    }

    @Published private(set) var bar: Bar?

    private weak var browser: Browser?
    private var queue = CaptureQueue<CaptureAnswer>()
    /// The last refusal: what, where, and the tabs to reload if you take it back.
    private var refusal: (site: String, devices: CaptureDevices, tabs: [UUID])?
    private var refusalHush: DispatchWorkItem?
    /// What macOS refuses Copper, and the tabs that were refused for it.
    private var blocked: (devices: CaptureDevices, restricted: Bool, tabs: [UUID])?
    /// … and, once macOS allows it, those tabs, for a few seconds.
    private var restored: (devices: CaptureDevices, tabs: [UUID])?
    private var restoredHush: DispatchWorkItem?
    /// The tab on screen whose capture another page holds (CaptureCalls).
    private var pausedTab: (tab: UUID, site: String, devices: CaptureDevices)?
    /// Pages waiting to hear whether they may use on-device speech to text,
    /// oldest first (`askVoice`).
    private var voiceAsks: [VoiceAsk] = []
    private var activeWatch: NSObjectProtocol?
    private var tabsWatch: AnyCancellable?
    /// When the bar started asking what it asks now. An answer from the bar
    /// counts once the question has been up long enough to be read: a double
    /// click on one site's Allow never answers the next site's question, and
    /// a page widening its question (the camera, too) as you click never gets
    /// what you didn't read.
    private var askedSince = Date.distantPast
    static let readTime: TimeInterval = 0.5

    /// How long "Don't allow" can be taken back from the bar.
    static let refusalSeconds: TimeInterval = 8

    /// Every window's desk, for what concerns all of them (a page loading
    /// again drops what it asked, wherever that is waiting).
    private static let desks = NSHashTable<CaptureDesk>.weakObjects()

    init(browser: Browser) {
        self.browser = browser
        CaptureDesk.desks.add(self)
        // Back from System Settings: if macOS now allows it, the bar goes.
        activeWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckSystem() }
        }
        // A tab closed: a question it asked, or its paused bar, goes with it.
        // (`$tabs` speaks before the change; look once it is made.)
        tabsWatch = browser.$tabs.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.queue.isEmpty || self.pausedTab != nil || !self.voiceAsks.isEmpty else { return }
                    self.recheck()
                }
            }
        }
    }

    deinit {
        if let activeWatch { NotificationCenter.default.removeObserver(activeWatch) }
    }

    // MARK: - requests in

    /// A page asking (Browser's WKUIDelegate method). Granted at once when
    /// the site was already allowed these devices; otherwise it waits for the
    /// bar, behind anything already waiting — never refused for coming second.
    func asked(by web: WKWebView, origin: WKSecurityOrigin, type: WKMediaCaptureType,
               _ decide: @escaping (WKPermissionDecision) -> Void) {
        let tab = CaptureDesk.tab(for: web)
        // Asked in the window the tab is in (or would be shown in), whichever
        // window WebKit happened to hand the request to.
        if let tab, let owner = Optional(AgentTabs.owner(of: tab)), owner !== browser {
            return owner.capture.asked(by: web, origin: origin, type: type, decide)
        }
        // WebKit hands over the top-level page's origin, also for a frame.
        let host = origin.host.isEmpty ? (tab?.address?.host() ?? "") : origin.host
        let site = host.isEmpty ? "" : CaptureChoices.site(host: host, port: origin.port)
        let devices = CaptureDevices(webKitType: type.rawValue)
        let answer = CaptureAnswer(web: web, host: host, decide)
        // From the first request on, the page is watched: a call keeps its
        // page heard while you are in another tab (CaptureCalls).
        CaptureCalls.shared.watch(web)
        // Held back by WebKit behind a request you just refused (CaptureRefusal).
        let id = ObjectIdentifier(web)
        if let refused = CaptureDesk.refusals[id], refused.web === web, refused.refusal.refuses(site, devices, at: Date()) {
            CaptureDesk.log("refused \(devices.words) for \(site) — part of the last Don't allow")
            answer(.deny)
            return
        }
        // A camera request the page never made through getUserMedia: on some
        // WebKit versions a screen share asks this way (Screen sharing has its
        // own question in newer ones). Asked about, never remembered.
        let page = CaptureDesk.wants[id]?.web === web ? CaptureDesk.wants[id] : nil
        let unsaid = devices == .camera && page != nil && page?.wants.devices.contains(.camera) == false
        if unsaid { CaptureDesk.log("a camera request from \(site) its page never made through getUserMedia — asked about, not remembered") }
        // A page with no host is asked about on its own, every time.
        let keep = !unsaid && !site.isEmpty
        // A page Copper is only warming off screen has not been seen: what the
        // site was allowed waits until it is on a stage (CaptureDesk.unseen).
        if keep, CaptureBook.choices.covers(site, devices), CaptureDesk.unseen(web) {
            CaptureDesk.log("holding \(devices.words) for \(site) until its page is on screen")
            CaptureDesk.unseenAsks.append(Held(answer: answer, origin: origin, type: type))
            return
        }
        let settled = queue.ask(site: site, devices: devices, tab: tab?.id, handle: answer, choices: CaptureBook.choices, keep: keep)
        if !settled.granted.isEmpty {
            CaptureDesk.log("granted \(devices.words) to \(site) (remembered)")
            apply(settled)
            return
        }
        // Nobody to ask on a Mac nobody sits at (docs/headless.md).
        if Headless.on {
            Headless.log("declined \(devices.words) for \(site.isEmpty ? "a page with no host" : site)")
            apply(queue.dropAll())
            return
        }
        CaptureDesk.log("asking about \(devices.words) for \(site.isEmpty ? "a page with no host" : site)")
        refresh()
    }

    /// The question for the oldest request, with what its page has asked for
    /// that WebKit is still holding back (CaptureWants).
    private func question() -> CaptureQuestion? {
        queue.question(CaptureBook.choices) { request in
            guard let web = request.handle.web else { return [] }
            return CaptureDesk.wants[ObjectIdentifier(web)]?.wants.devices ?? []
        }
    }

    // MARK: - the page's own word (CaptureHook's script)

    /// Pages' getUserMedia() calls in flight, per web view.
    private struct PageWants {
        weak var web: WKWebView?
        var wants = CaptureWants()
    }
    private static var wants: [ObjectIdentifier: PageWants] = [:]
    /// The last Don't allow per web view, for requests it covered that
    /// WebKit had yet to pass on.
    private struct PageRefusal {
        weak var web: WKWebView?
        let refusal: CaptureRefusal
    }
    private static var refusals: [ObjectIdentifier: PageRefusal] = [:]
    /// How long such a refusal holds: long enough for WebKit to pass on what
    /// it held back, never a standing block.
    static let refusalHold: TimeInterval = 10

    /// A page started a getUserMedia() call.
    static func began(_ devices: CaptureDevices, in web: WKWebView) {
        wants = wants.filter { $0.value.web != nil }
        refusals = refusals.filter { $0.value.web != nil && $0.value.refusal.until > Date() }
        let id = ObjectIdentifier(web)
        if wants[id]?.web !== web { wants[id] = PageWants(web: web) }
        wants[id]?.wants.began(devices)
        // The bar may now ask about more in one go.
        if let tab = tab(for: web) { AgentTabs.owner(of: tab).capture.refresh() }
    }

    /// … and heard back. (The page's entry stays, empty: it says the page
    /// script is there, so a request it did not see means something.)
    static func ended(_ devices: CaptureDevices, in web: WKWebView) {
        let id = ObjectIdentifier(web)
        guard wants[id]?.web === web else { return }
        wants[id]?.wants.ended(devices)
        // The bar may now ask about less (a call that gave up on its camera).
        if let tab = tab(for: web) { AgentTabs.owner(of: tab).capture.refresh() }
    }

    /// A new page in the view: whatever the last one had in flight, or was
    /// refused, or muted itself, went with it (as WebKit forgets its own
    /// refusals then) — and what it asked and is still waiting on the bar,
    /// or held, is no longer waited on: WebKit refused it as the page went.
    static func reset(_ web: WKWebView) {
        let id = ObjectIdentifier(web)
        wants = wants.filter { $0.value.web != nil }
        wants[id] = PageWants(web: web)
        refusals[id] = nil
        unseenAsks.removeAll { $0.answer.web === web }
        for desk in desks.allObjects { desk.gone(web) }
        CaptureCalls.shared.reset(web)
    }

    /// This page's waiting requests, answered no and off the bar.
    private func gone(_ web: WKWebView) {
        let voice = voiceAsks.filter { $0.web === web }
        guard queue.waiting.contains(where: { $0.handle.web === web }) || !voice.isEmpty else { return }
        apply(queue.drop { $0.handle.web === web })
        voiceAsks.removeAll { $0.web === web }
        for ask in voice { ask(false) }
        refresh()
    }

    // MARK: - pages nobody has seen

    /// A remembered Allow, waiting for its page to be seen.
    private struct Held {
        let answer: CaptureAnswer
        let origin: WKSecurityOrigin
        let type: WKMediaCaptureType
    }
    private static var unseenAsks: [Held] = []

    /// A page in the Room that is not a call you left: one Copper is warming
    /// off screen (another space's tab after launch, the launch's own before
    /// its window is up — Fork/SpaceWarm.swift). WebKit counts it as seen, so
    /// it can ask; nobody has seen it. A call page opened at launch would
    /// otherwise start the camera in a tab you never looked at, and then be
    /// kept going in the Room as a call. WebKit holds its own grants for a
    /// hidden page until it is visible; Copper holds the site's Allow until
    /// the page is on a stage. A call you left is in the Room too, and is
    /// answered at once (CaptureCalls).
    static func unseen(_ web: WKWebView) -> Bool {
        Room.holds(web) && !CaptureCalls.shared.keeps(web)
    }

    /// A page view moved (CaptureCalls.moved): a held page now on a stage is
    /// answered as if it had just asked; held pages that went are told no.
    static func moved(_ web: WKWebView) {
        guard !unseenAsks.isEmpty else { return }
        unseenAsks.removeAll { !$0.answer.waiting }
        guard CaptureCalls.onStage(web), unseenAsks.contains(where: { $0.answer.web === web }) else { return }
        let mine = unseenAsks.filter { $0.answer.web === web }
        unseenAsks.removeAll { $0.answer.web === web }
        // On the next turn, not from inside AppKit's move.
        DispatchQueue.main.async { [weak web] in
            MainActor.assumeIsolated {
                guard let web else { return } // (each answer, let go, says no)
                let desk = (tab(for: web).map { AgentTabs.owner(of: $0) } ?? Windows.current).capture
                for entry in mine {
                    desk.asked(by: web, origin: entry.origin, type: entry.type) { entry.answer($0) }
                }
            }
        }
    }

    // MARK: - the bar's answers

    /// The question an answer is for. From the bar (`shown`): the one it
    /// showed, if it is still the one asked and has been up long enough to be
    /// read — otherwise none, and the bar shows what is asked now. From the
    /// bench: whatever is asked now.
    private func current(_ shown: CaptureQuestion?) -> CaptureQuestion? {
        guard let question = question() else { return nil }
        guard let shown else { return question }
        guard question.reads(like: shown), Date().timeIntervalSince(askedSince) >= CaptureDesk.readTime else {
            CaptureDesk.log("an answer for a question that changed, or was up too briefly to be read — not taken")
            return nil
        }
        return question
    }

    /// Allow: the site keeps these devices, and every waiting request they
    /// cover — from any tab, in any window — is granted. macOS is asked first
    /// if it hasn't been; one it refuses turns the bar into the way to fix it.
    func allow(_ shown: CaptureQuestion? = nil) {
        prune()
        guard let question = current(shown) else { return refresh() }
        // Perhaps a screen share (CaptureQueue.ask's `keep`): macOS's camera
        // switch says nothing about it.
        guard question.keep else { return grant(question) }
        guard case let .undetermined(devices) = CaptureSystem.state(question.devices) else { return admit(question) }
        Task { @MainActor [weak self] in
            _ = await CaptureSystem.request(devices)
            guard let self else { return }
            self.prune()
            // What you answered, and no more: by now the page may have asked
            // for more, which is the bar's next question.
            guard self.queue.waiting.contains(where: { $0.keep && $0.site == question.site }) else { return self.refresh() }
            self.admit(question)
        }
    }

    /// Allow, as far as macOS lets Copper: what it refuses is refused to the
    /// pages (and the bar says so), the rest is let in — the camera switched
    /// off for Copper never costs a call its microphone.
    private func admit(_ question: CaptureQuestion) {
        guard case let .blocked(blocked, restricted) = CaptureSystem.state(question.devices) else { return grant(question) }
        let rest = question.devices.subtracting(blocked)
        if !rest.isEmpty { grant(question.asking(rest)) }
        apply(queue.deny(question.asking(blocked)))
        showSystem(blocked, restricted: restricted, tab: question.tab)
    }

    private func grant(_ question: CaptureQuestion) {
        var choices = CaptureBook.choices
        let settled = queue.allow(question, choices: &choices)
        // A page with no host can be let in, but there is no site to remember.
        if !question.site.isEmpty { CaptureBook.choices = choices }
        CaptureDesk.log("allowed \(question.devices.words) for \(question.site) — \(settled.granted.count) request(s)")
        apply(settled)
        // Another window may have been waiting on the same site.
        for browser in Windows.all where browser !== self.browser { browser.capture.recheck() }
        refresh()
    }

    /// Don't allow: this page is told no. Nothing is written down — WebKit
    /// itself refuses the page's further asks until it loads again, unless you
    /// click in the page to ask — and for a few seconds the bar offers to
    /// take it back.
    func deny(_ shown: CaptureQuestion? = nil) {
        prune()
        guard let question = current(shown) else { return refresh() }
        let settled = queue.deny(question)
        CaptureDesk.log("refused \(question.devices.words) for \(question.site) — \(settled.denied.count) request(s)")
        // What the same pages asked for that WebKit has yet to pass on is
        // refused too, as the bar said, when it arrives.
        let until = Date().addingTimeInterval(CaptureDesk.refusalHold)
        for web in settled.denied.compactMap({ $0.handle.web }) where question.keep {
            CaptureDesk.refusals[ObjectIdentifier(web)] = PageRefusal(web: web, refusal: CaptureRefusal(site: question.site, devices: question.devices, until: until))
        }
        apply(settled)
        var tabs: [UUID] = []
        for id in settled.denied.compactMap(\.tab) where !tabs.contains(id) { tabs.append(id) }
        if !question.site.isEmpty, question.keep {
            refusal = (question.site, question.devices, tabs)
            refusalHush?.cancel()
            let hush = DispatchWorkItem { [weak self] in
                self?.refusal = nil
                self?.refresh()
            }
            refusalHush = hush
            DispatchQueue.main.asyncAfter(deadline: .now() + CaptureDesk.refusalSeconds, execute: hush)
        }
        refresh()
    }

    /// The refusal taken back: the site is allowed, and the pages refused
    /// load again so they can ask — WebKit keeps a page's "no" until then.
    func allowRefused() {
        guard let refusal else { return }
        if case let .blocked(devices, restricted) = CaptureSystem.state(refusal.devices) {
            self.refusal = nil
            for tab in refusal.tabs { showSystem(devices, restricted: restricted, tab: tab) }
            if refusal.tabs.isEmpty { showSystem(devices, restricted: restricted) }
            return
        }
        CaptureBook.choices.allow(refusal.site, refusal.devices)
        CaptureDesk.refusals = CaptureDesk.refusals.filter { $0.value.refusal.site != refusal.site }
        CaptureDesk.log("allowed \(refusal.devices.words) for \(refusal.site) after a refusal — reloading \(refusal.tabs.count) tab(s)")
        for id in refusal.tabs { CaptureDesk.tab(id: id)?.reload() }
        self.refusal = nil
        refusalHush?.cancel()
        refresh()
    }

    /// The tab that asked, brought to the front: on another window's stage,
    /// that window; otherwise here, in whichever space it is. (Its owner by
    /// AgentTabs is the main window when no window shows its space, and a
    /// Show in a second window would have changed the first one.)
    func showAsker() {
        let asker: UUID?
        switch bar {
        case let .ask(question)?: asker = question.tab
        case let .voice(_, tab)?: asker = tab
        default: asker = nil
        }
        guard let id = asker, let tab = CaptureDesk.tab(id: id), let browser else { return }
        if let there = Windows.all.first(where: { $0 !== browser && $0.activeID == id }), let window = Windows.window(of: there) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        browser.select(tab)
    }

    // MARK: - macOS

    /// macOS refuses Copper these devices: say so, with the way to change it.
    /// `tab`: the page that was refused for it, to reload once it is fixed.
    func showSystem(_ devices: CaptureDevices, restricted: Bool, tab: UUID? = nil) {
        guard !Headless.on, !devices.isEmpty else { return }
        var tabs = blocked?.tabs ?? []
        if let tab, !tabs.contains(tab) { tabs.append(tab) }
        blocked = ((blocked?.devices ?? []).union(devices), restricted || blocked?.restricted == true, tabs)
        CaptureDesk.log("macOS refuses Copper the \(devices.words)\(restricted ? " (restricted)" : "")")
        refresh()
    }

    func openSystemSettings() {
        guard let blocked else { return }
        NSWorkspace.shared.open(CaptureSystem.settingsURL(blocked.devices))
    }

    func dismissSystem() {
        blocked = nil
        refresh()
    }

    /// Back from System Settings: if macOS allows it now, the pages it
    /// refused are offered a reload — WebKit keeps a page's "no" until then.
    private func recheckSystem() {
        guard let held = blocked, case .ready = CaptureSystem.state(held.devices) else { return }
        blocked = nil
        CaptureDesk.log("macOS allows Copper the \(held.devices.words) now")
        if !held.tabs.isEmpty {
            restored = (held.devices, held.tabs)
            restoredHush?.cancel()
            let hush = DispatchWorkItem { [weak self] in
                self?.restored = nil
                self?.refresh()
            }
            restoredHush = hush
            DispatchQueue.main.asyncAfter(deadline: .now() + CaptureDesk.refusalSeconds, execute: hush)
        }
        refresh()
    }

    // MARK: - one page at a time (CaptureCalls)

    func showPaused(_ tab: UUID, site: String, devices: CaptureDevices) {
        guard pausedTab?.tab != tab || pausedTab?.devices != devices else { return }
        CaptureDesk.log("the \(devices.words) on \(site) is paused for another tab")
        pausedTab = (tab, site, devices)
        refresh()
    }

    func clearPaused(_ tab: UUID) {
        guard pausedTab?.tab == tab else { return }
        pausedTab = nil
        refresh()
    }

    /// "Use it here".
    func resumePaused() {
        guard let held = pausedTab else { return }
        pausedTab = nil
        CaptureCalls.shared.resume(tab: held.tab)
        refresh()
    }

    func reloadRestored() {
        guard let restored else { return }
        for id in restored.tabs { CaptureDesk.tab(id: id)?.reload() }
        self.restored = nil
        restoredHush?.cancel()
        refresh()
    }

    // MARK: - keeping the bar true

    /// Another window's Allow, or a tab gone: settle what that changes.
    func recheck() {
        prune()
        apply(queue.settle(CaptureBook.choices))
        refresh()
    }

    /// Requests whose page closed or went to another site are no longer
    /// waiting (WebKit gave up on them): answered no, and off the bar.
    private func prune() {
        apply(queue.drop { !$0.handle.waiting })
        if voiceAsks.contains(where: { !$0.waiting }) {
            let gone = voiceAsks.filter { !$0.waiting }
            voiceAsks.removeAll { !$0.waiting }
            for ask in gone { ask(false) }
        }
    }

    private func apply(_ settled: CaptureQueue<CaptureAnswer>.Settled) {
        for request in settled.granted { request.handle(.grant) }
        for request in settled.denied { request.handle(.deny) }
    }

    func refresh() {
        prune()
        apply(queue.settle(CaptureBook.choices))
        // The paused tab closed, or has its device back.
        if let held = pausedTab, CaptureDesk.tab(id: held.tab)?.built.map({ CaptureCalls.shared.paused($0).isEmpty }) ?? true {
            pausedTab = nil
        }
        settleVoice()
        // A page waiting on an answer comes first; then what macOS refuses.
        let next: Bar?
        if let question = question() {
            next = .ask(question)
        } else if let voice = voiceAsks.first {
            next = .voice(host: voice.host, tab: voice.tab)
        } else if let blocked {
            next = .system(blocked.devices, restricted: blocked.restricted)
        } else if let pausedTab {
            next = .paused(site: pausedTab.site, devices: pausedTab.devices, tab: pausedTab.tab)
        } else if let refusal {
            next = .refused(site: refusal.site, devices: refusal.devices)
        } else if let restored {
            next = .restored(restored.devices)
        } else {
            next = nil
        }
        // Something new to read: the bar's answers wait until it can be read.
        if let now = next?.question, bar?.question?.reads(like: now) != true { askedSince = Date() }
        if case .voice = next, bar != next { askedSince = Date() }
        if bar != next { withAnimation(Motion.settle) { bar = next } }
    }

    /// For the bench: requests waiting, oldest first.
    var waiting: [[String: Any]] {
        queue.waiting.map { ["site": $0.site, "devices": $0.devices.names, "tab": $0.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? NSNull()] }
            + voiceAsks.map { ["site": $0.host, "devices": ["voice"], "tab": $0.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? NSNull()] }
    }

    // MARK: - on-device speech to text (Fork (page-voice))

    /// One page asking for Copper's on-device speech to text: its answer,
    /// given exactly once — no, if nothing else gave it before it goes.
    private final class VoiceAsk {
        let host: String
        let tab: UUID?
        private(set) weak var web: WKWebView?
        private var answer: ((Bool) -> Void)?

        init(host: String, tab: UUID?, web: WKWebView?, _ answer: @escaping (Bool) -> Void) {
            self.host = host
            self.tab = tab
            self.web = web
            self.answer = answer
        }

        func callAsFunction(_ yes: Bool) {
            guard let answer else { return }
            self.answer = nil
            answer(yes)
        }

        /// Still worth asking about: the page is open, on the host that asked.
        @MainActor var waiting: Bool {
            guard answer != nil, let web, web.uiDelegate != nil else { return false }
            return web.url?.host()?.caseInsensitiveCompare(host) == .orderedSame
        }

        deinit { answer?(false) }
    }

    /// A listed site asking for on-device speech to text (PageVoice.start):
    /// the same bar as the camera and the microphone, in the window that holds
    /// the page's tab, after any question about them — never refused for
    /// coming second. The answer, yes or no, is kept for the host
    /// (`PageVoice.consentKey`; Settings › Privacy › Forget choices forgets it).
    func askVoice(host: String, from web: WKWebView?, _ answer: @escaping (Bool) -> Void) {
        let tab = web.flatMap { CaptureDesk.tab(for: $0) }
        if let tab, let owner = Optional(AgentTabs.owner(of: tab)), owner !== browser {
            return owner.capture.askVoice(host: host, from: web, answer)
        }
        if let known = PageVoice.consent(host) { return answer(known) }
        // Nobody to ask on a Mac nobody sits at; nothing is written down.
        if Headless.on {
            Headless.log("declined on-device speech to text for \(host)")
            return answer(false)
        }
        CaptureDesk.log("asking about on-device speech to text for \(host)")
        voiceAsks.append(VoiceAsk(host: host, tab: tab?.id, web: web, answer))
        refresh()
    }

    /// The bar's Allow or Don't allow on a voice question. From the bar
    /// (`shown`): only for the one it showed, up long enough to be read, as
    /// for the camera and the microphone. Every page of that host waiting is
    /// answered.
    func answerVoice(_ shown: Bar? = nil, allow yes: Bool) {
        prune()
        guard question() == nil, let first = voiceAsks.first else { return refresh() }
        if let shown {
            guard shown == .voice(host: first.host, tab: first.tab),
                  Date().timeIntervalSince(askedSince) >= CaptureDesk.readTime else {
                CaptureDesk.log("an answer for a question that changed, or was up too briefly to be read — not taken")
                return refresh()
            }
        }
        Store.settings.set(yes, forKey: PageVoice.consentKey(first.host))
        CaptureDesk.log("\(yes ? "allowed" : "refused") on-device speech to text for \(first.host)")
        settleVoice()
        // Another window may have been waiting on the same host.
        for browser in Windows.all where browser !== self.browser { browser.capture.recheck() }
        refresh()
    }

    /// Voice questions a kept answer now settles (this bar's, another window's).
    private func settleVoice() {
        guard !voiceAsks.isEmpty else { return }
        var settled: [(VoiceAsk, Bool)] = []
        voiceAsks.removeAll { ask in
            guard let known = PageVoice.consent(ask.host) else { return false }
            settled.append((ask, known))
            return true
        }
        for (ask, known) in settled { ask(known) }
    }

    /// For the bench's pictures: the bar as if a page had asked.
    func seed(_ bar: Bar?) {
        self.bar = bar
    }

    // MARK: - finding tabs

    /// The tab showing this page, wherever it is: any window, any space.
    static func tab(for web: WKWebView) -> Tab? {
        AgentTabs.all.first { $0.built === web }
    }

    static func tab(id: UUID) -> Tab? { AgentTabs.find(id) }

    static func log(_ text: String) {
        guard Store.testing || ProcessInfo.processInfo.environment["SEARCH_CAPTURE_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("copper[capture]: \(text)\n".utf8))
    }
}
