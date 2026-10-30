import AppKit
import WebKit

// Fork (page-capture): a call goes on while you look at another tab, and the
// call you are looking at is the one that hears you.
//
// Seen. Copper's stage holds only the tab on screen (Stage.swift): every
// other tab's view is out of any window, and to WebKit a view out of any
// window — or in a window that is covered — is a hidden page. On a Mac WebKit
// does not cut a hidden page's microphone or camera
// (InterruptAudioOnPageVisibilityChangeEnabled is off outside iOS), so the
// call keeps sending. What a hidden page cannot do is ask again:
//
// - getUserMedia() from a hidden page waits until it is visible
//   (WebCore MediaDevices::getUserMedia, GetUserMediaRequiresFocus);
// - a request WebKit would grant on the page's earlier grant waits too
//   (UserMediaPermissionRequestManagerProxy::processUserMediaPermissionValidRequest
//   keeps it in m_pregrantedRequests until viewIsBecomingVisible);
// - and the `devicechange` event is held until then (MediaDevices::
//   scheduledEventTimerFired → whenVisible).
//
// So a call that loses its microphone while you are in another tab — AirPods
// taken out or claimed by the phone, the Mac's input changed — asks for it
// back and hears nothing until you return: you were talking, nobody heard you.
// While a page captures, then, it never goes hidden. Wherever its view is it
// ignores occlusion (WebKit's own switch, as Backstage and the Room use it),
// so a covered window still counts as seen; and when it leaves the stage — you
// picked another tab — it is hung in the Room (Fork/SpaceWarm.swift), the
// window off every screen where a page is laid out as if in view, until the
// stage takes it back or the capture ends. A closed tab's page is never kept:
// its view has let go of its delegate and its tab (Tab.discard) and goes.
// Not in headless runs, where every view already ignores occlusion.
//
// Heard. WebKit lets one page capture at a time: a page that starts its
// microphone or camera pauses ("mutes") capture in every other page
// (WebPageProxy::activateMediaStreamCaptureInPage → WebProcessProxy::
// muteCaptureInPagesExcept), and nothing ever un-pauses it — Safari has a
// button in its address field for that; Copper had nothing, so a call went
// silent for good the moment another tab tried its microphone. Now the call
// on screen gets it back: on its own once no other page is capturing anything
// (taking it back pauses theirs), with one click on the bar while one is. A
// page that muted itself (navigator.mediaSession.setMicrophoneActive(false))
// is left muted. A call page Copper is only warming off screen, never seen,
// waits for its site's Allow until it is (CaptureDesk.unseen).
@MainActor
final class CaptureCalls {
    static let shared = CaptureCalls()

    /// On unless a test world turns it off (`capture.keep`), to compare.
    static var on: Bool { Store.settings.object(forKey: "capture.keep") as? Bool ?? true }

    private final class Watched {
        weak var web: WKWebView?
        var tokens: [NSKeyValueObservation] = []
        /// What the page muted itself (Media Session), never resumed by Copper.
        var own = CaptureOwnMutes()
        init(_ web: WKWebView) { self.web = web }
    }

    private var watched: [ObjectIdentifier: Watched] = [:]
    /// The pages being kept seen: occlusion off, hung in the Room off stage.
    private var kept = Set<ObjectIdentifier>()

    private init() {}

    /// A page has asked for the camera or the microphone: from now on, its
    /// capture is followed.
    func watch(_ web: WKWebView) {
        let id = ObjectIdentifier(web)
        if watched[id]?.web === web { return }
        watched = watched.filter { $0.value.web != nil }
        let entry = Watched(web)
        entry.own = CaptureOwnMutes(live: CaptureCalls.capturing(web))
        // WebKit says so on the main thread, in the middle of its own update;
        // the view is moved on the next turn, never from inside it.
        let follow = { [weak self, weak web] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let web else { return }
                    self.changed(web)
                }
            }
        }
        entry.tokens = [
            web.observe(\.microphoneCaptureState, options: [.new]) { _, _ in follow() },
            web.observe(\.cameraCaptureState, options: [.new]) { _, _ in follow() },
        ]
        watched[id] = entry
    }

    /// The devices capturing live, not paused.
    static func capturing(_ web: WKWebView) -> CaptureDevices {
        var devices: CaptureDevices = []
        if web.microphoneCaptureState == .active { devices.insert(.microphone) }
        if web.cameraCaptureState == .active { devices.insert(.camera) }
        return devices
    }

    /// Capturing anything at all — live, or paused by the page or by WebKit.
    static func onCall(_ web: WKWebView) -> Bool {
        web.microphoneCaptureState != .none || web.cameraCaptureState != .none
    }

    func keeps(_ web: WKWebView) -> Bool { kept.contains(ObjectIdentifier(web)) }

    /// A page that is still some tab's, and still listened to.
    private static func live(_ web: WKWebView) -> Bool {
        web.uiDelegate != nil && CaptureDesk.tab(for: web) != nil
    }

    private func changed(_ web: WKWebView) {
        // Live again since last looked at: whatever the page had muted
        // itself, it has unmuted (CaptureOwnMutes).
        if let entry = watched[ObjectIdentifier(web)], entry.web === web { entry.own.saw(live: CaptureCalls.capturing(web)) }
        if CaptureCalls.on, !Headless.on, CaptureCalls.onCall(web), CaptureCalls.live(web) {
            keep(web)
        } else if keeps(web) {
            letGo(web)
        }
        // One page starting or stopping changes what every other may resume.
        reviewAll()
    }

    private func keep(_ web: WKWebView) {
        let first = kept.insert(ObjectIdentifier(web)).inserted
        if first { CaptureDesk.log("keeping a call's page seen (\(web.url?.host() ?? "?"))") }
        web.detectsOcclusion(false)
        CaptureCalls.reread(web)
        if web.window == nil { hang(web) }
    }

    private func letGo(_ web: WKWebView) {
        kept.remove(ObjectIdentifier(web))
        CaptureDesk.log("the call ended; an ordinary tab again (\(web.url?.host() ?? "?"))")
        let tab = CaptureDesk.tab(for: web)
        // A tab being shared, or sharing one (Fork/TabShare/), stays seen:
        // the share's stage has the say over it until the share ends.
        let shared = tab.map { TabShare.shared.involves($0.id) } ?? false
        if Room.holds(web) {
            // Out of the Room: Room.moved turns occlusion back on — and a
            // shared page goes straight to the share's own stage, not a tick later.
            Room.leave(web)
            if shared, let tab { TabShareStage.keep(tab) }
        } else if !Headless.on, !shared, !(web.window is Backstage.Window),
                  !(tab.map { Backstage.shared.holds($0.id) } ?? false) {
            // (A page an agent is working in keeps the backstage's say over
            // occlusion, wherever it is.)
            web.detectsOcclusion(true)
            CaptureCalls.reread(web)
        }
    }

    /// From Room.moved (PageView.viewDidMoveToWindow): a kept page moved.
    func moved(_ web: WKWebView) {
        // A page nobody had seen, now on a stage: what it asked is answered.
        CaptureDesk.moved(web)
        guard keeps(web) else { return }
        guard web.window == nil else {
            // On a stage again: Room.moved has just turned occlusion back on.
            web.detectsOcclusion(false)
            CaptureCalls.reread(web)
            review(web)
            return
        }
        // Off its stage. On the next turn — the stage that took it out of
        // here may be about to put it back — it goes to the Room, unless its
        // tab closed or the call ended in between.
        let id = ObjectIdentifier(web)
        DispatchQueue.main.async { [weak self, weak web] in
            guard let self else { return }
            // Its tab closed and the view is gone: nothing left to keep.
            guard let web else { self.kept.remove(id); return }
            guard web.window == nil, self.keeps(web) else { return }
            guard CaptureCalls.onCall(web), CaptureCalls.live(web) else { return self.letGo(web) }
            self.hang(web)
            self.review(web)
        }
    }

    private func hang(_ web: WKWebView) {
        Room.park(web, size: CaptureCalls.stageSize)
        CaptureDesk.log("a call's page is off stage; hung in the Room (\(web.url?.host() ?? "?"))")
    }

    // MARK: - one page at a time

    /// What WebKit paused in this page for another's sake: muted, and not
    /// by the page itself.
    func paused(_ web: WKWebView) -> CaptureDevices {
        var devices: CaptureDevices = []
        if web.microphoneCaptureState == .muted { devices.insert(.microphone) }
        if web.cameraCaptureState == .muted { devices.insert(.camera) }
        return devices.subtracting(ownMutes(web))
    }

    /// Which of these devices another page is capturing live right now.
    private func busy(_ devices: CaptureDevices, besides web: WKWebView) -> CaptureDevices {
        var busy: CaptureDevices = []
        for entry in watched.values {
            guard let other = entry.web, other !== web else { continue }
            if devices.contains(.microphone), other.microphoneCaptureState == .active { busy.insert(.microphone) }
            if devices.contains(.camera), other.cameraCaptureState == .active { busy.insert(.camera) }
        }
        return busy
    }

    /// On a browser window's stage (or its side pane), or floated out in a
    /// window of its own (Float.swift) — the page you are on.
    static func onStage(_ web: WKWebView) -> Bool {
        guard let window = web.window else { return false }
        return Windows.isBrowserWindow(window) || CaptureDesk.tab(for: web)?.floating == true
    }

    private func reviewAll() {
        for entry in watched.values {
            if let web = entry.web { review(web) }
        }
    }

    /// The page on screen, paused for another page's sake: resumed on its own
    /// while no other page captures anything, otherwise offered back on the
    /// bar (CaptureTurn).
    private func review(_ web: WKWebView) {
        guard let tab = CaptureDesk.tab(for: web) else { return }
        let desk = AgentTabs.owner(of: tab).capture
        let paused = paused(web)
        guard CaptureCalls.on, !Headless.on, CaptureCalls.onStage(web) else { return desk.clearPaused(tab.id) }
        switch CaptureTurn.on(paused: paused, othersLive: busy(.both, besides: web)) {
        case .nothing:
            desk.clearPaused(tab.id)
        case .resume:
            CaptureDesk.log("resuming the \(paused.words) on \(web.url?.host() ?? "?") — no other page is capturing")
            desk.clearPaused(tab.id)
            resume(web, paused)
        case .offer:
            desk.showPaused(tab.id, site: web.url?.host() ?? "", devices: paused)
        }
    }

    /// Un-paused, as WebKit itself un-pauses a page that starts capture: the
    /// microphone and the camera together (WebKit pauses them together), and
    /// every other page's capture paused — one page at a time, or you would
    /// be talking into two calls. WebKit does that last part only when every
    /// kind of capture, the screen's too, is un-paused at once, which the
    /// public calls can't do; so it is done here, page by page. Whatever a
    /// page muted itself stays as it is.
    func resume(_ web: WKWebView, _ devices: CaptureDevices) {
        for entry in watched.values {
            guard let other = entry.web, other !== web else { continue }
            if other.microphoneCaptureState == .active { other.setMicrophoneCaptureState(.muted) }
            if other.cameraCaptureState == .active { other.setCameraCaptureState(.muted) }
        }
        let own = ownMutes(web)
        if !own.contains(.microphone) { web.setMicrophoneCaptureState(.active) }
        if !own.contains(.camera) { web.setCameraCaptureState(.active) }
    }

    /// The bar's "Use it here".
    func resume(tab id: UUID) {
        guard let web = CaptureDesk.tab(id: id)?.built else { return }
        let paused = paused(web)
        CaptureDesk.log("taking the \(paused.words) back for \(web.url?.host() ?? "?")")
        resume(web, paused)
    }

    /// The page said, through the Media Session API, that it muted itself
    /// (CaptureHook's page script). Only ever a mute (CaptureOwnMutes).
    func page(_ web: WKWebView, muted devices: CaptureDevices) {
        watch(web)
        guard let entry = watched[ObjectIdentifier(web)], entry.web === web else { return }
        entry.own.said(muted: devices)
    }

    private func ownMutes(_ web: WKWebView) -> CaptureDevices {
        guard let entry = watched[ObjectIdentifier(web)], entry.web === web else { return [] }
        return entry.own.muted
    }

    /// A new page in the view: the last one's own mutes went with it — once
    /// its capture has (a page can't wipe its own record mid-call).
    func reset(_ web: WKWebView) {
        guard !CaptureCalls.onCall(web), let entry = watched[ObjectIdentifier(web)], entry.web === web else { return }
        entry.own.forget()
    }

    // MARK: -

    /// WebKit rereads whether a page is seen when its window's occlusion
    /// changes; turning its occlusion switch alone changes nothing until then.
    private static func reread(_ web: WKWebView) {
        guard let window = web.window else { return }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    /// The size the page had on its stage, so its layout doesn't change in the Room.
    private static var stageSize: CGSize? {
        Windows.current.active?.built?.bounds.size
    }

    /// For the bench.
    func report(_ web: WKWebView) -> [String: Any] {
        let entry = watched[ObjectIdentifier(web)]
        return ["kept": keeps(web), "inRoom": Room.holds(web), "watched": entry != nil,
                "paused": paused(web).names, "mutedByPage": entry?.own.muted.names ?? []]
    }

    var keptCount: Int { kept.count }

    /// Pages followed whose view is still alive.
    var watchingCount: Int { watched.values.filter { $0.web != nil }.count }
}
