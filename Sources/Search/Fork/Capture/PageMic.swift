import AppKit
import WebKit

// Fork (page-mic): a second page's microphone never pauses a call.
//
// WebKit lets one page capture at a time: when it starts a page's microphone
// it pauses ("mutes") capture in every other page
// (WebPageProxy::activateMediaStreamCaptureInPage → WebProcessProxy::
// muteCaptureInPagesExcept), on a Mac with no preference, private WKPreferences
// key or _WKFeature to turn that off (looked for on macOS 27's WebKit:
// docs/capture.md › Two pages, one microphone). Meet in one tab and a
// transcriber asking for the microphone in another: the call goes silent.
//
// So a page asking for the microphone alone while another page is capturing
// is served Copper's own microphone (VoiceCapture, AVAudioEngine, which
// already lets go on sleep and a lost device), bridged into the page as an
// audio track the way a shared tab's sound is (PCMPlayerScript): WebKit never
// starts a capture for it, so it pauses nothing. The site is asked first,
// exactly as WebKit's own request would be (CaptureDesk.asked: a remembered
// Allow, the bar, Don't allow). PageMicRules.route says when.
//
//   page         PageMic.script wraps getUserMedia (main frame only). While
//                Copper has said another page is capturing (`watch`), an
//                audio-only call asks Copper first (`route`); otherwise
//                WebKit's own call is made at once, unchanged.
//   Copper       `route`: WebKit's way, or the bar's answer and a
//                VoiceCapture; `audio` long-polls its sound; `stop` ends it.
//   the end      the page's track.stop(), its leaving, its tab closing or
//                sleeping, a device lost, the Mac sleeping — the page hears
//                `ended`.
@MainActor
final class PageMic {
    static let shared = PageMic()
    static let handler = "copperMic"

    @MainActor final class Session {
        let id: String
        weak var web: WKWebView?
        let tab: Tab.ID?
        let origin: String
        let frame: TabShareRules.FrameKey
        let label: String
        let feed = PCMFeed()
        let started = Date()
        var capture: VoiceCapture?
        var tone: DispatchSourceTimer?

        init(id: String, web: WKWebView, tab: Tab.ID?, origin: String, frame: TabShareRules.FrameKey, label: String) {
            self.id = id
            self.web = web
            self.tab = tab
            self.origin = origin
            self.frame = frame
            self.label = label
        }
    }

    private(set) var sessions: [Session] = []
    private var watchdog: Timer?
    /// Pages waiting to hear whether another page is capturing — one per
    /// web view, the newest (the page's script keeps one out) — and what
    /// each was last told.
    private var watchers: [ObjectIdentifier: (web: WeakView, reply: TabShareCapture.Reply, seen: Bool)] = [:]
    /// The last few ends and routes (the bench's).
    private var log: [[String: Any]] = []

    final class WeakView {
        weak var view: WKWebView?
        init(_ view: WKWebView) { self.view = view }
    }

    // MARK: - hooks

    /// CaptureHook.listen: the page script's way back.
    static func listen(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: handler, contentWorld: .page)
        controller.addScriptMessageHandler(Relay.shared, contentWorld: .page, name: handler)
    }

    /// CaptureHook.arm: the wrapper, in main frames only.
    static func arm(_ controller: WKUserContentController) {
        controller.addUserScript(userScript)
    }

    private static let userScript = WKUserScript(source: PageMicScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true)

    /// A tab whose page is using Copper's microphone: Sleep.swift keeps it awake.
    func serves(_ tab: Tab.ID) -> Bool {
        sessions.contains { $0.tab == tab }
    }

    /// CaptureCalls.changed: a page's capture started, paused or ended.
    /// Each page waiting hears whether another page is capturing, when that
    /// is not what it was last told.
    func captureChanged() {
        for (id, entry) in watchers {
            guard let web = entry.web.view else { watchers[id] = nil; continue }
            let now = Self.anyCapturing(besides: web)
            guard now != entry.seen else { continue }
            watchers[id] = nil
            entry.reply(["busy": now])
        }
    }

    /// TabShare.committed (Browser `didCommit`): a new document's page has
    /// nothing of the old one's.
    func committed(_ view: WKWebView) {
        for session in sessions where session.web === view { stop(session.id, reason: "the page went away") }
    }

    // MARK: - who captures

    /// Any page capturing anything through WebKit, live or paused.
    static func anyCapturing(besides web: WKWebView? = nil) -> Bool {
        AgentTabs.all.contains { tab in
            guard let other = tab.built, other !== web else { return false }
            return CaptureCalls.onCall(other)
        }
    }

    // MARK: - the page's messages

    final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Relay()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            let reply = TabShareCapture.Reply(replyHandler)
            MainActor.assumeIsolated { PageMic.shared.received(message, reply: reply) }
        }
    }

    private func received(_ message: WKScriptMessage, reply: TabShareCapture.Reply) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String, let web = message.webView else {
            return reply(nil)
        }
        // Who asks, as WebKit says, never as the message says: the handler
        // is in the page's world, where any script can post anything.
        let info = message.frameInfo
        let main = info.isMainFrame
        let origin = TabShareRules.origin(scheme: info.securityOrigin.protocol, host: info.securityOrigin.host,
                                          port: info.securityOrigin.port)
        let frame = TabShare.frame(of: info)
        switch op {
        case "watch":
            guard main else { return reply(nil) }
            let now = Self.anyCapturing(besides: web)
            let seen = body["busy"] as? Bool
            if seen != now { return reply(["busy": now]) }
            let id = ObjectIdentifier(web)
            // One per page: an older one (a document since replaced) is let go.
            if let older = watchers[id] { older.reply(["busy": now]) }
            watchers = watchers.filter { $0.value.web.view != nil }
            watchers[id] = (WeakView(web), reply, now)
        case "route":
            route(web, info: info, origin: origin, frame: frame, main: main, body: body, reply: reply)
        case "audio", "stop":
            guard let id = body["mic"] as? String, let session = sessions.first(where: { $0.id == id }),
                  session.web === web, session.origin == origin, session.frame.same(frame) else {
                return op == "stop" ? reply(true) : reply(["ended": true, "reason": "no such microphone"])
            }
            if op == "stop" {
                reply(true)
                stop(id, reason: "the page stopped it")
            } else {
                session.feed.next(after: (body["after"] as? NSNumber)?.intValue ?? 0, reply: reply)
            }
        default:
            reply(nil)
        }
    }

    /// `route`: WebKit's way, or — the site allowed — Copper's microphone.
    private func route(_ web: WKWebView, info: WKFrameInfo, origin: String, frame: TabShareRules.FrameKey, main: Bool,
                       body: [String: Any], reply: TabShareCapture.Reply) {
        let mock = CapturePreferences.mock
        let route = PageMicRules.route(mainFrame: main, audio: body["audio"] as? Bool ?? false, video: body["video"] as? Bool ?? false,
                                       othersCapturing: Self.anyCapturing(besides: web), selfCapturing: CaptureCalls.onCall(web),
                                       macOSAllows: mock || VoiceCapture.authorization == .authorized, headless: Headless.on)
        note(["host": info.securityOrigin.host, "route": route.rawValue])
        guard route == .copper else { return reply(["route": PageMicRules.Route.webkit.rawValue]) }
        let label = body["label"] as? String
        let tab = CaptureDesk.tab(for: web)
        let desk = (tab.map { AgentTabs.owner(of: $0) } ?? Windows.current).capture
        CaptureDesk.log("\(info.securityOrigin.host) asked for the microphone while another page is capturing — Copper's own, if allowed")
        desk.asked(by: web, origin: info.securityOrigin, type: .microphone) { [weak self, weak web] decision in
            MainActor.assumeIsolated {
                guard let self, let web, web.uiDelegate != nil else { return reply(["route": "denied"]) }
                guard decision == .grant else { return reply(["route": "denied"]) }
                self.start(web, tab: tab?.id, origin: origin, frame: frame, label: label, reply: reply)
            }
        }
    }

    private func start(_ web: WKWebView, tab: Tab.ID?, origin: String, frame: TabShareRules.FrameKey, label: String?,
                       reply: TabShareCapture.Reply) {
        let device = PageMicRules.device(named: label, among: AudioInputs.all().map(\.name))
        let session = Session(id: TabShare.newID(), web: web, tab: tab, origin: origin, frame: frame,
                              label: PageMicRules.label(device: device, fallback: AudioInputs.defaultName))
        let id = session.id
        let sink = session.feed.sink
        if CapturePreferences.mock {
            session.tone = Self.tone(into: sink)
        } else {
            let capture = VoiceCapture(device: device)
            do {
                try capture.start(onBlock: { block in
                    sink.push(PCM.int16(block), frames: block.count, rate: PageMicRules.rate, channels: PageMicRules.channels)
                }, onStop: { [weak self] reason in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.stop(id, reason: Self.words(reason)) } }
                })
            } catch {
                // Not to be had here after all: WebKit's own, which asks again
                // and finds the site allowed.
                CaptureDesk.log("Copper's microphone didn't open (\(error.localizedDescription)) — WebKit's own instead")
                return reply(["route": PageMicRules.Route.webkit.rawValue])
            }
            session.capture = capture
        }
        sessions.append(session)
        startWatchdog()
        note(["host": web.url?.host() ?? "", "started": session.label])
        reply(["route": PageMicRules.Route.copper.rawValue, "mic": id, "label": session.label,
               "rate": PageMicRules.rate, "channels": PageMicRules.channels])
    }

    func stop(_ id: String, reason: String) {
        guard let at = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: at)
        session.capture?.stop()
        session.capture = nil
        session.tone?.cancel()
        session.tone = nil
        session.feed.end(reason)
        note(["ended": reason, "seconds": (Date().timeIntervalSince(session.started) * 10).rounded() / 10])
        if sessions.isEmpty { watchdog?.invalidate(); watchdog = nil }
    }

    func stopAll(reason: String) {
        for session in sessions { stop(session.id, reason: reason) }
    }

    /// Once a second: a page that closed, slept or stopped asking has let go.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func check() {
        for session in sessions {
            guard let web = session.web, web.uiDelegate != nil else { stop(session.id, reason: "the page went away"); continue }
            if let tab = session.tab, AgentTabs.find(tab)?.built !== web { stop(session.id, reason: "the tab closed"); continue }
            if PageMicRules.quiet(sinceAsked: Date().timeIntervalSince(session.feed.lastAsked)) {
                stop(session.id, reason: "the page stopped listening")
                continue
            }
            session.tab.flatMap { AgentTabs.find($0) }?.touch()
        }
    }

    private static func words(_ reason: VoiceCaptureStop) -> String {
        switch reason {
        case .requested: return "stopped"
        case .deviceLost: return "the microphone went away"
        case .sleep: return "the Mac went to sleep"
        case .sessionResigned: return "another user took the Mac"
        case .failed(let why): return why
        }
    }

    /// Test worlds (`capture.mock`): a quiet tone instead of the microphone,
    /// as WebKit's own stand-in beeps.
    private static func tone(into sink: PCMSink) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "copper.pagemic.tone"))
        let rate = PageMicRules.rate, frames = Int(rate / 20)
        var phase = 0.0
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler {
            var block = [Swift.Float](repeating: 0, count: frames)
            for i in 0..<frames {
                block[i] = Swift.Float(0.1 * sin(phase))
                phase += 2 * .pi * 660 / rate
            }
            phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
            sink.push(PCM.int16(block), frames: frames, rate: rate, channels: 1)
        }
        timer.resume()
        return timer
    }

    private func note(_ entry: [String: Any]) {
        var entry = entry
        entry["at"] = ISO8601DateFormatter().string(from: Date())
        log.append(entry)
        if log.count > 20 { log.removeFirst(log.count - 20) }
    }

    var report: [String: Any] {
        ["anyCapturing": Self.anyCapturing(), "watchers": watchers.values.filter { $0.web.view != nil }.count,
         "sessions": sessions.map { session -> [String: Any] in
             var row = session.feed.report
             row["id"] = String(session.id.prefix(8))
             row["host"] = session.web?.url?.host() ?? NSNull()
             row["label"] = session.label
             row["mock"] = session.tone != nil
             return row
         },
         "log": log]
    }
}
