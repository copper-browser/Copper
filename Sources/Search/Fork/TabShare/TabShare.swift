import AppKit
import WebKit

// Sharing one Copper tab with a page that asked to share your screen — the
// "Tab" choice Chrome's getDisplayMedia picker has and WebKit's does not.
// docs/screen-sharing.md tells the whole story; in short:
//
//   page            TabShareScript: getDisplayMedia wrapped; WebKit's own call
//                   made at once, plus an "ask" to Copper
//   WebKit          asks Copper's UI delegate (TabShareDelegate.swift)
//   Copper          the picker (TabSharePicker.swift): a tab, a window, the
//                   screen, or cancel. Window and screen go on to WebKit's
//                   system picker; a tab is shared here; cancel refuses.
//   a tab           TabShareCapture pictures it, TabShareStage keeps it
//                   painting off screen, the page draws each picture into a
//                   canvas whose capture track is the stream it gets
//   the end         Stop on the bar (TabShareBar.swift), the shared tab
//                   closed, the page's track.stop() or its leaving
//
// This file is the bookkeeping: the page's messages, the asks waiting for
// WebKit's request, the picker that is up, and the shares that are live.
@MainActor
final class TabShare: NSObject, ObservableObject {
    static let shared = TabShare()

    // MARK: - hooks (Tab.swift)

    /// Tab.swift `Web.configuration`: the page script's way back, once per
    /// configuration (a tab opened by a link shares its opener's controller,
    /// handler and all). In a test world, WebKit's mock capture devices when
    /// asked for (TabShareTesting).
    nonisolated static func configure(_ configuration: WKWebViewConfiguration) {
        MainActor.assumeIsolated {
            configuration.userContentController.addScriptMessageHandler(Relay.shared, contentWorld: .page, name: TabShareScript.handler)
            TabShareTesting.prepare(configuration)
        }
    }

    /// Tab.swift `arm(hiding:)`: the wrapper, in every frame, before the
    /// page's own scripts — every time the controller's scripts are laid
    /// down again.
    static func arm(_ controller: WKUserContentController) {
        controller.addUserScript(script)
    }

    private static let script = WKUserScript(source: TabShareScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    // MARK: - the picker

    enum Choice: Equatable {
        case tab(UUID)
        case window
        case screen
        case cancel
    }

    /// WebKit is waiting on Copper's answer, and the picker is up.
    struct Picking: Identifiable {
        let id = UUID()
        /// The window the picker is drawn in.
        let browser: ObjectIdentifier
        /// The site of the frame that asked: the one a tab's pictures go to.
        let host: String
        /// The site whose page that frame sits in, when it is another's.
        var within: String? = nil
        let caller: Tab.ID?
        /// The tabs on offer; empty when the page cannot be handed a tab
        /// (its frame has no wrapper), and then only a window or the screen.
        let tabs: [TabShareRules.Candidate]
        let canShareTab: Bool
        let systemAudio: Bool
        /// The matched ask's token (Copper's own, never the page's id).
        fileprivate let ask: UUID?
        /// The page that asked: gone, its question is too (a new document in
        /// it ends the question at once: `committed`).
        fileprivate weak var view: WKWebView?
        fileprivate let decide: (Int) -> Void
    }

    @Published private(set) var picking: Picking?
    /// The picker's typed filter and highlighted row.
    @Published var query = ""
    @Published var highlighted = 0

    /// The rows the picker shows now: the filtered tabs, then a window, the
    /// screen.
    var rows: [Choice] {
        guard let picking else { return [] }
        return TabShareRules.filter(picking.tabs, query).map { .tab($0.id) } + [.window, .screen]
    }

    // MARK: - shares

    final class Share: Identifiable {
        let id: String
        let source: Tab.ID
        let consumer: Tab.ID?
        weak var consumerView: WKWebView?
        /// The origin of the frame that asked, and that frame and its
        /// document: only they are handed pictures, and a new document in
        /// that frame ends the share.
        let origin: String
        let frame: TabShareRules.FrameKey
        let host: String
        let started = Date()
        let capture: TabShareCapture
        init(id: String, source: Tab.ID, consumer: Tab.ID?, consumerView: WKWebView?, origin: String,
             frame: TabShareRules.FrameKey, host: String, capture: TabShareCapture) {
            self.id = id
            self.source = source
            self.consumer = consumer
            self.consumerView = consumerView
            self.origin = origin
            self.frame = frame
            self.host = host
            self.capture = capture
        }
    }

    @Published private(set) var shares: [Share] = []
    /// The last few ends, newest last (the bench's).
    private(set) var ended: [[String: Any]] = []
    /// Every request WebKit made of the delegate and what Copper answered
    /// (the bench's; never more than twenty).
    private(set) var decisions: [[String: Any]] = []

    // MARK: - asks

    private struct Ask {
        /// Copper's name for it. The page's own id is the page's to choose,
        /// and means something only together with the frame that sent it.
        let token = UUID()
        let key: TabShareRules.AskKey
        weak var view: WKWebView?
        let want: TabShareRules.Want
        /// The page's `video` as it asked, for its displaySurface hint.
        let video: Any?
        let audio: Bool
        let includeSelf: Bool
        let reply: TabShareCapture.Reply
        var matched = false
    }

    private var asks: [Ask] = []
    private var watchdog: Timer?

    // MARK: - WebKit's request

    /// `_webView:requestDisplayCapturePermissionForOrigin:…` (TabShareDelegate).
    func request(from view: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                 in browser: Browser, decide: @escaping (Int) -> Void) {
        let key = TabShareRules.origin(scheme: origin.protocol, host: origin.host, port: origin.port)
        let frameOrigin = TabShareRules.origin(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host,
                                               port: frame.securityOrigin.port)
        let frameKey = Self.frame(of: frame)
        expireAsks()
        let caller = Self.tab(for: view)
        var askID: UUID?
        var ask: Ask?
        let open = asks.filter { !$0.matched }
        if let found = TabShareRules.match(open.map(\.key), view: ObjectIdentifier(view), origin: frameOrigin, frame: frameKey),
           let token = open.first(where: { $0.key == found && $0.view === view })?.token,
           let at = asks.firstIndex(where: { $0.token == token }) {
            asks[at].matched = true
            askID = token
            ask = asks[at]
        }
        // One picker at a time. WebKit already cancels a page's earlier
        // request when it makes another; another page's waits its turn by
        // being refused — it can ask again.
        if let open = picking {
            if open.view === view {
                close(open, with: .cancel, note: "replaced")
            } else {
                note(["origin": key, "decision": "deny", "why": "another picker is up"])
                decide(0)
                if let askID { answer(askID, ["choice": "cancel"]) }
                return
            }
        }
        let top = origin.host.isEmpty ? (caller?.address?.host() ?? "This page") : origin.host
        // The picker names the site that would be handed the pictures — the
        // frame's — and the page around it when that is another site's.
        let names = TabShareRules.names(frame: frame.securityOrigin.host, top: top)
        let owner = caller.flatMap { Windows.owner(of: $0) } ?? browser
        let canShareTab = ask != nil
        let candidates = canShareTab ? Self.candidates(in: owner, caller: caller?.id) : []
        let picking = Picking(browser: ObjectIdentifier(owner), host: names.host, within: names.within, caller: caller?.id,
                              tabs: TabShareRules.offer(candidates, includeCaller: ask?.includeSelf ?? false),
                              canShareTab: canShareTab, systemAudio: systemAudio, ask: askID, view: view,
                              decide: decide)
        note(["origin": key, "frame": frameOrigin, "mainFrame": frame.isMainFrame, "systemAudio": systemAudio,
              "ask": ask?.key.id ?? NSNull(), "offered": picking.tabs.count, "decision": "picker",
              "frameKnown": frameKey.frame != nil, "documentKnown": frameKey.document != nil])
        query = ""
        self.picking = picking
        highlighted = TabShareRules.highlight(for: ask?.video, rows: rows.count, tabs: picking.tabs.count)
        startWatchdog()
        if let queued = TabShareTesting.takeAnswer() {
            choose(queued)
        } else if Headless.on, !TabShareTesting.holds {
            // Nobody can click a picker on a Mac nobody sits at.
            Headless.log("tab share: \(picking.host) asked to share the screen — declined (headless)")
            choose(.cancel)
        }
    }

    /// The person's answer (the picker, its keys, or the bench in a test run).
    func choose(_ choice: Choice) {
        guard let picking else { return }
        close(picking, with: choice, note: nil)
    }

    private func close(_ picking: Picking, with choice: Choice, note why: String?) {
        if self.picking?.id == picking.id { self.picking = nil }
        defer { idleWatchdog() }
        var entry: [String: Any] = ["host": picking.host, "ask": picking.ask.flatMap { token in asks.first { $0.token == token }?.key.id } ?? NSNull()]
        if let why { entry["why"] = why }
        switch choice {
        case .cancel:
            entry["decision"] = "deny"
            if let ask = picking.ask { answer(ask, ["choice": "cancel"]) }
            picking.decide(0) // WKDisplayCapturePermissionDecisionDeny → NotAllowedError
        case .screen:
            entry["decision"] = "screenPrompt"
            if let ask = picking.ask { answer(ask, ["choice": "native"]) }
            picking.decide(1) // WKDisplayCapturePermissionDecisionScreenPrompt
        case .window:
            entry["decision"] = "windowPrompt"
            if let ask = picking.ask { answer(ask, ["choice": "native"]) }
            picking.decide(2) // WKDisplayCapturePermissionDecisionWindowPrompt
        case .tab(let id):
            // Only a tab the picker offered: never a private one, never the
            // calling page unless it asked to be offered itself.
            guard picking.tabs.contains(where: { $0.id == id }),
                  let askID = picking.ask, let ask = asks.first(where: { $0.token == askID }),
                  let source = AgentTabs.find(id), let view = picking.view, ask.view === view,
                  let reply = start(source, for: view, consumer: picking.caller, origin: ask.key.origin, frame: ask.key.frame,
                                    host: picking.host, want: ask.want) else {
                entry["decision"] = "deny"
                entry["why"] = "tab unavailable"
                if let ask = picking.ask { answer(ask, ["choice": "cancel"]) }
                picking.decide(0)
                break
            }
            entry["decision"] = "tab"
            entry["share"] = reply["share"]
            answer(askID, reply)
            // WebKit's own request is refused on purpose: the page's wrapper
            // has its stream already and lets WebKit's rejection go.
            picking.decide(0)
        }
        note(entry)
    }

    // MARK: - starting and stopping

    private func start(_ source: Tab, for view: WKWebView, consumer: Tab.ID?, origin: String, frame: TabShareRules.FrameKey,
                       host: String, want: TabShareRules.Want) -> [String: Any]? {
        if source.asleep { _ = source.wake() } else if source.hollow { source.revive() }
        guard !source.isBlank else { return nil }
        _ = source.web // built, so it can be hung where it paints
        let id = Self.newID()
        let capture = TabShareCapture(share: id, tab: source, want: want)
        let consumerTab = consumer.flatMap { AgentTabs.find($0) }
        let share = Share(id: id, source: source.id, consumer: consumer, consumerView: view, origin: origin, frame: frame,
                          host: host, capture: capture)
        capture.beforeTick = { [weak self, weak source, weak consumerTab] in
            guard let self, let source else { return }
            TabShareStage.keep(source, fallback: Self.size(of: consumerTab))
            if self.keepsCallerPainting, let consumerTab { TabShareStage.keep(consumerTab) }
        }
        TabShareStage.keep(source, fallback: Self.size(of: consumerTab))
        if keepsCallerPainting, let consumerTab { TabShareStage.keep(consumerTab) }
        shares.append(share)
        capture.start()
        startWatchdog()
        let pixels = TabShareRules.pixels(for: source.built?.bounds.size ?? TabShareStage.stageSize, want: want)
        return ["choice": "tab", "share": id, "width": pixels.width, "height": pixels.height, "fps": capture.fps,
                "label": source.label, "maxWidth": TabShareRules.maxWidth, "maxHeight": TabShareRules.maxHeight]
    }

    /// The calling page keeps painting while you are on the tab it shares:
    /// a call page that draws or paces its own sending on animation frames
    /// (a hidden page gets none) keeps going, and the stream never slows to
    /// a background tab's pace. Measured: docs/screen-sharing.md.
    var keepsCallerPainting = true

    func stop(_ id: String, reason: String) {
        guard let at = shares.firstIndex(where: { $0.id == id }) else { return }
        let share = shares.remove(at: at)
        share.capture.stop(reason)
        let others = shares
        if let tab = AgentTabs.find(share.source) {
            if !others.contains(where: { $0.source == tab.id || $0.consumer == tab.id }) { TabShareStage.release(tab) }
        } else {
            TabShareStage.forget(share.source)
        }
        if let consumer = share.consumer {
            if let tab = AgentTabs.find(consumer) {
                if !others.contains(where: { $0.source == consumer || $0.consumer == consumer }) { TabShareStage.release(tab) }
            } else {
                TabShareStage.forget(consumer)
            }
        }
        ended.append(["share": id, "reason": reason, "seconds": (Date().timeIntervalSince(share.started) * 10).rounded() / 10,
                      "published": share.capture.published])
        if ended.count > 10 { ended.removeFirst(ended.count - 10) }
        idleWatchdog()
    }

    private func idleWatchdog() {
        if shares.isEmpty, picking == nil { watchdog?.invalidate(); watchdog = nil }
    }

    /// The tab is shared, or is the page sharing one: Sleep.swift keeps it awake.
    func involves(_ id: Tab.ID) -> Bool {
        shares.contains { $0.source == id || $0.consumer == id }
    }

    func stopAll(reason: String) {
        for share in shares { stop(share.id, reason: reason) }
    }

    /// Once a second: a share whose tab is gone, whose page is gone or has
    /// stopped asking for pictures, is over. Its tabs are kept from sleeping.
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
        expireAsks()
        // A picker whose page or window closed has nobody to answer, and
        // would refuse every other page's question while it stood. (A page
        // that went elsewhere ends it at once: `committed`. Its address
        // alone is no sign — a page that changes it with pushState is
        // still the page that asked.)
        if let picking {
            let gone = picking.view == nil || picking.caller.map { AgentTabs.find($0) == nil } == true
                || !Windows.all.contains { ObjectIdentifier($0) == picking.browser }
            if gone { close(picking, with: .cancel, note: "the page went away") }
        }
        for share in shares {
            guard let source = AgentTabs.find(share.source), source.built != nil, !source.asleep else {
                stop(share.id, reason: "the shared tab closed")
                continue
            }
            if let consumer = share.consumer, AgentTabs.find(consumer) == nil {
                stop(share.id, reason: "the sharing tab closed")
                continue
            }
            // The calling tab slept or was rebuilt: its page, and the stream
            // it held, are gone. (Leaving the page says so itself: pagehide.)
            if share.consumerView == nil {
                stop(share.id, reason: "the sharing page went away")
                continue
            }
            if TabShareRules.quiet(sinceAsked: Date().timeIntervalSince(share.capture.lastAsked), everAsked: share.capture.asked > 0) {
                stop(share.id, reason: share.capture.asked > 0 ? "the sharing page stopped asking" : "the sharing page never asked")
                continue
            }
            // A tab in use is never idle: the sleep sweep skips both.
            source.touch()
            share.consumer.flatMap { AgentTabs.find($0) }?.touch()
            share.capture.label = source.label
        }
    }

    /// Browser.swift `didCommit`: a new document in the view's main frame.
    /// Every frame of the old one is gone, and so is whatever it was sharing
    /// or asking — at once, whether or not its pagehide said so (a page can
    /// keep its own pagehide listeners from hearing it) and before the new
    /// document can ask for anything. Nothing to do, and no work, when
    /// nothing is shared or asked.
    func committed(_ view: WKWebView) {
        guard !shares.isEmpty || picking != nil || !asks.isEmpty else { return }
        for share in shares where share.consumerView === view { stop(share.id, reason: "the sharing page went away") }
        if let picking, picking.view === view { close(picking, with: .cancel, note: "the page went away") }
        for ask in asks where ask.view === view && !ask.matched { answer(ask.token, ["choice": "none"]) }
    }

    // MARK: - the page's messages

    final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Relay()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            let reply = TabShareCapture.Reply(replyHandler)
            MainActor.assumeIsolated { TabShare.shared.received(message, reply: reply) }
        }
    }

    private func received(_ message: WKScriptMessage, reply: TabShareCapture.Reply) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String, let view = message.webView else {
            reply(nil)
            return
        }
        // Who is asking, as WebKit says — never as the message says. The
        // handler is in the page's world: any script in any frame can post
        // anything to it, so every message is held to the web view, frame,
        // document and origin WebKit names for it.
        let origin = message.frameInfo.securityOrigin
        let from = TabShareRules.origin(scheme: origin.protocol, host: origin.host, port: origin.port)
        let frame = Self.frame(of: message.frameInfo)
        switch op {
        case "ask":
            guard let id = body["id"] as? String, !id.isEmpty, id.count < 200 else { reply(nil); return }
            expireAsks()
            // A page cannot pile asks up: the oldest unanswered go first.
            let mine = asks.filter { $0.view === view && !$0.matched }
            if mine.count >= 4, let oldest = mine.first { answer(oldest.token, ["choice": "none"]) }
            let surface = body["selfBrowserSurface"] as? String
            asks.append(Ask(key: .init(id: id, view: ObjectIdentifier(view), origin: from, frame: frame, at: Date()), view: view,
                            want: TabShareRules.want(from: body["video"]), video: body["video"], audio: (body["audio"] as? Bool) == true,
                            includeSelf: surface == "include" || (body["preferCurrentTab"] as? Bool) == true, reply: reply))
        case "drop", "settled":
            reply(true)
            // Only the frame that made the ask can take it back.
            guard let id = body["id"] as? String,
                  let ask = asks.first(where: { $0.key.id == id && $0.view === view && $0.key.origin == from && $0.key.frame.same(frame) })
            else { return }
            // WebKit's request ended without Copper's answer — a newer request,
            // a navigation, the permissions policy: the picker for it goes.
            if let picking, picking.ask == ask.token { close(picking, with: .cancel, note: "page settled") }
            answer(ask.token, ["choice": "none"])
        case "frame", "stop", "tune":
            let refuse = { op == "stop" ? reply(true) : reply(["ended": true, "reason": "no such share"]) }
            guard let id = body["share"] as? String, let share = shares.first(where: { $0.id == id }), share.consumerView === view else {
                return refuse()
            }
            // The frame that was handed the share holds another document
            // now: the page that asked has gone, and its share with it.
            if share.frame.replaced(by: frame) {
                stop(share.id, reason: "the sharing page went away")
                return refuse()
            }
            // Pictures for the one frame and document that asked, in its origin.
            guard share.origin == from, share.frame.same(frame) else { return refuse() }
            switch op {
            case "frame":
                share.capture.next(after: (body["after"] as? NSNumber)?.intValue ?? 0, reply: reply)
            case "stop":
                reply(true)
                stop(id, reason: "the page stopped it")
            default:
                share.capture.tune(TabShareRules.want(from: body["want"]))
                reply(["fps": share.capture.fps, "width": share.capture.size.width, "height": share.capture.size.height])
            }
        default:
            reply(nil)
        }
    }

    /// The ask's one answer; it leaves the list.
    private func answer(_ token: UUID, _ value: [String: Any]) {
        guard let at = asks.firstIndex(where: { $0.token == token }) else { return }
        let ask = asks.remove(at: at)
        ask.reply(value)
    }

    /// Asks WebKit never followed up within a minute (its request was
    /// refused before reaching Copper and the page never said so) are
    /// answered "none" and dropped; so are asks from views that are gone.
    private func expireAsks() {
        let now = Date()
        for ask in asks where !ask.matched && (now.timeIntervalSince(ask.key.at) > 60 || ask.view == nil) {
            answer(ask.token, ["choice": "none"])
        }
    }

    /// The frame and document WebKit says a message or request came from:
    /// WKFrameInfo's private `_handle` (`_WKFrameHandle.frameID`) and
    /// `_documentIdentifier`, each asked for only where this WebKit answers
    /// to it. A part it lacks is left out, and the origin and the web view
    /// still bind what is handed over (TabShareRules.FrameKey).
    static func frame(of info: WKFrameInfo) -> TabShareRules.FrameKey {
        var key = TabShareRules.FrameKey()
        let handle = NSSelectorFromString("_handle"), frameID = NSSelectorFromString("frameID")
        if info.responds(to: handle), let object = info.perform(handle)?.takeUnretainedValue() as? NSObject,
           object.responds(to: frameID), let number = object.value(forKey: "frameID") as? NSNumber {
            key.frame = number.uint64Value
        }
        let document = NSSelectorFromString("_documentIdentifier")
        if info.responds(to: document), let object = info.perform(document)?.takeUnretainedValue() {
            key.document = (object as? NSUUID)?.uuidString ?? String(describing: object)
        }
        return key
    }

    // MARK: - helpers

    static func tab(for view: WKWebView) -> Tab? {
        AgentTabs.all.first { $0.built === view }
    }

    static func size(of tab: Tab?) -> NSSize? {
        guard let web = tab?.built, web.bounds.width > 200, web.bounds.height > 200 else { return nil }
        return web.bounds.size
    }

    /// 128 random bits: a share's id is all a page has to name it by.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        // Never sixteen zero bytes, should the system's generator ever say no:
        // a UUID's 122 random bits instead.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Every tab a window could offer: its own space's (pins and rows), then
    /// every other space's, each under that space's name.
    static func candidates(in browser: Browser, caller: Tab.ID?) -> [TabShareRules.Candidate] {
        func candidate(_ tab: Tab, space: String?) -> TabShareRules.Candidate {
            let host = (tab.address ?? tab.pending)?.host() ?? ""
            return .init(id: tab.id, title: tab.label, host: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                         space: space, isCaller: tab.id == caller, isBlank: tab.isBlank, isPrivate: tab.shy)
        }
        let here = Spaces.shared.current(in: browser)
        var list = browser.tabs.map { candidate($0, space: nil) }
        for space in Spaces.shared.all where space.id != here {
            list += Spaces.shared.row(space.id).map { candidate($0, space: space.title) }
        }
        return list
    }

    private func note(_ entry: [String: Any]) {
        var entry = entry
        entry["at"] = ISO8601DateFormatter().string(from: Date())
        decisions.append(entry)
        if decisions.count > 20 { decisions.removeFirst(decisions.count - 20) }
    }

    // MARK: - the bench

    var report: [String: Any] {
        var out: [String: Any] = [
            "shares": shares.map { share -> [String: Any] in
                var row = share.capture.report
                row["id"] = share.id
                row["source"] = AgentTabs.find(share.source).map(AgentTabs.short) ?? share.source.uuidString
                row["consumer"] = share.consumer.flatMap { AgentTabs.find($0) }.map(AgentTabs.short) ?? NSNull()
                row["host"] = share.host
                row["label"] = share.capture.label
                row["sourceHung"] = TabShareStage.isHung(share.source)
                row["consumerHung"] = share.consumer.map(TabShareStage.isHung) ?? false
                row["sourceWindow"] = AgentTabs.find(share.source)?.built?.window.map { String(describing: type(of: $0)) } ?? "none"
                row["sourceIgnoresOcclusion"] = AgentTabs.find(share.source)?.built?.headlessIgnoresOcclusion ?? NSNull()
                return row
            },
            "asks": asks.map { ["id": $0.key.id, "origin": $0.key.origin, "matched": $0.matched] },
            "decisions": decisions,
            "ended": ended,
            "stage": TabShareStage.report,
            "keepsCallerPainting": keepsCallerPainting,
        ]
        if let picking {
            out["picker"] = [
                "host": picking.host, "within": picking.within ?? NSNull(), "canShareTab": picking.canShareTab, "systemAudio": picking.systemAudio,
                "query": query, "highlighted": highlighted,
                "rows": rows.map { choice -> String in
                    switch choice {
                    case .tab(let id): return "tab " + (AgentTabs.find(id).map { AgentTabs.short($0) + " " + $0.label } ?? id.uuidString)
                    case .window: return "window"
                    case .screen: return "screen"
                    case .cancel: return "cancel"
                    }
                },
            ]
        } else {
            out["picker"] = NSNull()
        }
        return out
    }
}
