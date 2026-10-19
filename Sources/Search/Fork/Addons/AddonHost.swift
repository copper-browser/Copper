import AppKit
import Combine
import WebKit

// The web view an addon runs in, one per window and slot, and the two doors
// into it: the `copper-addon://` scheme its files come through, and the
// `copperAddon` message handler its `window.copper` calls arrive on.
//
// It is built the first time the slot shows an addon and then kept: ⌘E
// hides the slot's SwiftUI view, not the page, so a conversation in the
// addon survives the pane being closed and opened again — the page only
// hears `visibility`. It is let go when the slot has no addon any more (the
// cloud took it away, the person turned it off) or its window closes.
//
// What the page may touch is narrow on purpose (contract §5.4):
//
// - Its own website-data store (`AddonSlotHost.store`), never a browsing
//   profile: no cookie, no sign-in and no storage is shared with the pages
//   the person browses.
// - Files only from the installed bundle of the addon in the slot, served by
//   `AddonFiles` (as SceneFiles serves the backdrop, so WebKit issues no
//   file sandbox extension), with a Content-Security-Policy that keeps the
//   network out — `copper.fetch` is the only way out, and it holds the
//   addon to its manifest's hosts.
// - No navigation away from `copper-addon://<id>/`; an http(s) link the
//   person clicks opens in a tab instead, and `window.open` is refused.
// - Messages count only from this view's main frame, at the addon's origin.
//
// A page that fails to load, or whose process keeps dying, gives the slot
// back to its own view (AgentSlot falls back to the native pane) until the
// addon changes.

// MARK: - files

/// `copper-addon://<id>/<path>`: the files of the addon in the asking web
/// view's slot. `/` is the entry; a path outside the bundle, or one that
/// isn't there, is a 404.
final class AddonFiles: NSObject, WKURLSchemeHandler {
    static let shared = AddonFiles()
    static let scheme = "copper-addon"

    static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8", "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8", "xml": "application/xml; charset=utf-8",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg",
        "mp4": "video/mp4", "webm": "video/webm",
    ]

    static func type(of path: String) -> String {
        types[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// What a request gets: pure, so the containment rules can be tested
    /// without a web view.
    struct Answer {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    static func answer(_ url: URL, id: String, folder: URL, entry: String) -> Answer {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == id else { return missing }
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = entry }
        // The bundle path rule again: no `..`, no `.`, nothing outside
        // `A-Za-z0-9._@-`. Every file a bundle can hold passes it.
        guard Addons.validPath(path) else { return missing }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        // A development folder can hold a symbolic link out of itself.
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else { return missing }
        let type = AddonFiles.type(of: path)
        var body = data
        if type.hasPrefix("text/html"), let html = String(data: data, encoding: .utf8) {
            body = Data(AddonCSP.inject(html).utf8)
        }
        return Answer(status: 200, headers: [
            "Content-Type": type,
            "Content-Length": String(body.count),
            "Content-Security-Policy": AddonCSP.policy,
            "X-Content-Type-Options": "nosniff",
            // A development folder changes under the page; an installed
            // bundle never does, but is small and local either way.
            "Cache-Control": "no-cache",
        ], body: body)
    }

    private static let missing = Answer(status: 404, headers: ["Content-Type": "text/plain; charset=utf-8",
                                                               "Content-Security-Policy": AddonCSP.policy],
                                        body: Data("Not in this addon".utf8))

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        // WebKit calls scheme handlers on the main thread.
        let served = MainActor.assumeIsolated { () -> Answer in
            guard let host = AddonSlotHost.host(of: webView), let entry = host.entry else { return AddonFiles.missing }
            return AddonFiles.answer(url, id: entry.id, folder: AddonSync.shared.folder(of: entry), entry: entry.entry)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: served.status, httpVersion: "HTTP/1.1", headerFields: served.headers) else {
            return task.didFailWithError(URLError(.cannotParseResponse))
        }
        task.didReceive(response)
        task.didReceive(served.body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: - navigation

enum AddonNavigation: Equatable {
    case allow
    case openInTab(URL)
    case cancel

    /// The slot page stays on its own origin. A link the person clicked to
    /// a web page opens beside it, in a tab; everything else (a script
    /// sending the page elsewhere, a form, a frame) is refused.
    static func decide(_ url: URL?, id: String, linkActivated: Bool) -> AddonNavigation {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == AddonFiles.scheme, url.host?.lowercased() == id { return .allow }
        if linkActivated, scheme == "https" || scheme == "http" { return .openInTab(url) }
        return .cancel
    }
}

// MARK: - the host

/// A type of its own, so the bench and the slot's holder can tell the
/// addon's page from a tab's at a glance.
final class AddonWebView: WKWebView {}

/// Holds the message handler weakly: WebKit keeps a strong reference to
/// every handler, and the host keeps the web view.
private final class AddonMessages: NSObject, WKScriptMessageHandler {
    weak var host: AddonSlotHost?
    init(_ host: AddonSlotHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.received(message) }
    }
}

@MainActor
final class AddonSlotHost: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    private struct Key: Hashable {
        let browser: ObjectIdentifier
        let slot: AddonSlot
    }

    private static var all: [Key: AddonSlotHost] = [:]
    static let handlerName = "copperAddon"

    /// The one website-data store every addon page uses: persistent (an
    /// addon's own sign-in to its service survives a relaunch), apart from
    /// every browsing profile, and — like `Spaces.store(forProfile:)` —
    /// salted with the test world so a probe never reads the real one.
    static let store: WKWebsiteDataStore = {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\u{1}copper-addons\u{1}\(Store.world ?? "")".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let text = String(format: "AD0A0000-%04X-4000-8000-%012llX", UInt16(truncatingIfNeeded: hash >> 48), hash & 0xFFFF_FFFF_FFFF)
        guard let id = UUID(uuidString: text) else { return .nonPersistent() }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    /// `bridge.js`, the same bytes on every platform (contract §5), from
    /// Search_Search.bundle as CanvasPage finds canvas.html.
    static let bridgeSource: String? = {
        let name = "Search_Search.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        var candidates: [URL] = []
        for root in roots {
            let bundle = root.appendingPathComponent(name)
            if let inner = Bundle(url: bundle)?.resourceURL { candidates.append(inner.appendingPathComponent("bridge.js")) }
            candidates.append(bundle.appendingPathComponent("bridge.js"))
            candidates.append(bundle.appendingPathComponent("Contents/Resources/bridge.js"))
        }
        for file in candidates {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return nil
    }()

    /// The host for a window's slot, made the first time it is asked for.
    static func host(for browser: Browser, slot: AddonSlot) -> AddonSlotHost {
        prune()
        let key = Key(browser: ObjectIdentifier(browser), slot: slot)
        if let known = all[key] { return known }
        let host = AddonSlotHost(browser: browser, slot: slot)
        all[key] = host
        return host
    }

    static func host(of web: WKWebView) -> AddonSlotHost? {
        all.values.first { $0.web === web }
    }

    /// The front window's host for a slot, if it has one yet.
    static func front(_ slot: AddonSlot) -> AddonSlotHost? {
        all[Key(browser: ObjectIdentifier(Windows.current), slot: slot)]
    }

    /// Every host follows what AddonSync says its slot shows now.
    static func sync() {
        prune()
        for host in all.values { host.follow(AddonSync.shared.active(host.slot)) }
    }

    /// Hosts whose window went: their pages go with them.
    private static func prune() {
        for (key, host) in all where host.browser == nil {
            host.unload()
            all[key] = nil
        }
    }

    static func describe() -> [[String: Any]] {
        all.values.map { host in
            ["slot": host.slot.rawValue, "addon": host.entry?.id ?? "", "version": host.entry?.version ?? "",
             "loaded": host.loaded, "visible": host.visible, "failed": host.failed ?? "",
             "url": host.web?.url?.absoluteString ?? "", "front": host.browser === Windows.current]
        }
    }

    weak var browser: Browser?
    let slot: AddonSlot

    /// What the page is showing (or loading).
    @Published private(set) var entry: AddonInstalled?
    /// Set when the page couldn't be shown; the slot uses its own view.
    @Published private(set) var failed: String?
    /// The page finished loading.
    @Published private(set) var loaded = false
    private(set) var web: AddonWebView?
    private(set) var visible = false

    private var messages: AddonMessages?
    private var crashes: [Date] = []
    private var appearance: NSKeyValueObservation?
    private var lastDark: Bool?
    private var watches: Set<AnyCancellable> = []
    private var agentDue = false
    private var lastAgent: Data?
    private var pageTimer: Timer?
    private var lastPage: Data?
    /// `copper.oauth.authorize` windows this page opened.
    var oauth: [AddonOAuth] = []

    /// ⌘E: the pane's own state, not the view's lifecycle — SwiftUI tells
    /// a removed view late (after its transition), or not at all for a
    /// window that isn't drawing.
    private var shownWatch: AnyCancellable?

    private init(browser: Browser, slot: AddonSlot) {
        self.browser = browser
        self.slot = slot
        super.init()
        shownWatch = Agent.shared.$open.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { self?.setVisible(open && self?.failed == nil) }
        }
    }

    var dark: Bool {
        let appearance = web?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: following the slot

    /// Show `next` (or nothing): the same page stays, with new settings
    /// told; a different addon or version is a new page.
    func follow(_ next: AddonInstalled?) {
        guard let next else {
            unload()
            return
        }
        if let entry, entry.pageKey == next.pageKey, web != nil {
            let changed = entry.settings != next.settings
            self.entry = next
            if changed { emit("settings", next.settings.any) }
            return
        }
        load(next)
    }

    private func load(_ next: AddonInstalled) {
        cancelOAuth()
        entry = next
        failed = nil
        loaded = false
        crashes = []
        lastAgent = nil
        lastPage = nil
        guard let source = AddonSlotHost.bridgeSource else {
            fail("This Copper is missing bridge.js, so addons can't run")
            return
        }
        guard let url = URL(string: "\(AddonFiles.scheme)://\(next.id)/") else {
            fail("\(next.id) is not a name an address can carry")
            return
        }
        let web = self.web ?? build(bridge: source)
        self.web = web
        watch(next)
        web.load(URLRequest(url: url))
    }

    private func build(bridge source: String) -> AddonWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = AddonSlotHost.store
        config.setURLSchemeHandler(AddonFiles.shared, forURLScheme: AddonFiles.scheme)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = Web.userAgentName
        // At document start, main frame only, before any addon script.
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let messages = AddonMessages(self)
        config.userContentController.add(messages, name: AddonSlotHost.handlerName)
        self.messages = messages
        let web = AddonWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        // The slot's own ground shows until the page paints, with no white
        // flash in between in a dark window.
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.isInspectable = AddonSlotHost.inspectable
        appearance = web.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.themeMaybeChanged() }
        }
        return web
    }

    /// Web Inspector on the slot: test worlds and development builds, or
    /// with `addons.developer` set (docs/addons.md, Developer mode).
    static var inspectable: Bool { Store.testing || Store.settings.bool(forKey: "addons.developer") }

    /// Let the page go: the slot shows its own view again.
    func unload() {
        cancelOAuth()
        watches.removeAll()
        pageTimer?.invalidate()
        pageTimer = nil
        appearance = nil
        if let web {
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: AddonSlotHost.handlerName)
            web.removeFromSuperview()
        }
        web = nil
        messages = nil
        entry = nil
        loaded = false
        failed = nil
    }

    private func fail(_ why: String) {
        failed = why
        loaded = false
        AddonSync.shared.noteFromHost("\(entry?.id ?? "addon"): \(why) — the \(slot.name) shows its own view")
    }

    /// After a failure: the next look at the slot tries again.
    func retry() {
        guard let entry else { return }
        let again = entry
        self.entry = nil
        load(again)
    }

    // MARK: what the page hears

    func setVisible(_ shown: Bool) {
        guard shown != visible else { return }
        visible = shown
        emit("visibility", ["visible": shown])
        if shown { themeMaybeChanged() }
    }

    private func themeMaybeChanged() {
        let now = dark
        guard now != lastDark else { return }
        lastDark = now
        emit("theme", ["dark": now])
    }

    /// The agent and page events, for the addons granted them.
    private func watch(_ entry: AddonInstalled) {
        watches.removeAll()
        pageTimer?.invalidate()
        pageTimer = nil
        let granted = entry.granted
        if granted.contains(.agent) {
            // At most ten a second: a streaming transcript changes far more
            // often than a page needs to redraw.
            Agent.shared.objectWillChange.merge(with: Intelligence.shared.objectWillChange)
                .sink { [weak self] _ in self?.agentChanged() }
                .store(in: &watches)
        }
        if granted.contains(.page) {
            browser?.objectWillChange
                .sink { [weak self] _ in DispatchQueue.main.async { self?.pageMaybeChanged() } }
                .store(in: &watches)
            // A tab's title and address change without the browser saying
            // so; once a second is plenty for "which page is in front".
            pageTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageMaybeChanged() }
            }
        }
    }

    private func agentChanged() {
        guard !agentDue else { return }
        agentDue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.agentDue = false
            let state = AddonBridge.agentState()
            guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != self.lastAgent else { return }
            self.lastAgent = data
            self.emit("agent", state)
        }
    }

    private func pageMaybeChanged() {
        guard loaded else { return }
        let page = AddonBridge.currentPage(browser)
        let data = try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys, .fragmentsAllowed])
        guard data != lastPage else { return }
        lastPage = data
        emit("page", page)
    }

    /// `window.__copperAddon.emit(name, payload)` (bridge.js).
    func emit(_ name: String, _ payload: Any) {
        guard let web, loaded else { return }
        guard let json = AddonSlotHost.json([name, payload]) else { return }
        web.evaluateJavaScript("window.__copperAddon && window.__copperAddon.emit.apply(null, \(json))", completionHandler: nil)
    }

    private func reply(_ id: Any, ok: Bool, _ payload: Any) {
        guard let web else { return }
        let json = AddonSlotHost.json([id, ok, payload])
            ?? AddonSlotHost.json([id, false, ["code": "internal", "message": "The answer couldn't be encoded"]])
            ?? "[]"
        web.evaluateJavaScript("window.__copperAddon && window.__copperAddon.reply.apply(null, \(json))", completionHandler: nil)
    }

    /// JSON is a JavaScript expression too.
    static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: what the page says

    /// Whether a message really comes from this slot's page: this web view,
    /// its main frame, the addon's own origin.
    func trusts(_ message: WKScriptMessage) -> Bool {
        guard let web, let entry, message.webView === web, message.frameInfo.isMainFrame else { return false }
        let origin = message.frameInfo.securityOrigin
        if !origin.host.isEmpty || !origin.protocol.isEmpty {
            return origin.protocol.lowercased() == AddonFiles.scheme && origin.host.lowercased() == entry.id
        }
        // An origin WebKit reports as opaque: the frame's address decides.
        let url = message.frameInfo.request.url
        return url?.scheme?.lowercased() == AddonFiles.scheme && url?.host?.lowercased() == entry.id
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard trusts(message), let entry else { return }
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let id = object["id"] ?? NSNull()
        guard AddonManifest.wholeNumber(object["v"]) == Addons.bridge, let method = object["method"] as? String else {
            reply(id, ok: false, ["code": "bad_request", "message": "Not a bridge v\(Addons.bridge) call"])
            return
        }
        let params = object["params"] as? [String: Any] ?? [:]
        let key = entry.pageKey
        Task { @MainActor in
            let outcome: (Bool, Any)
            do {
                outcome = (true, try await AddonBridge.call(method, params, host: self, entry: entry))
            } catch let problem as AddonBridgeError {
                outcome = (false, ["code": problem.code, "message": problem.message])
            } catch {
                outcome = (false, ["code": "internal", "message": error.localizedDescription])
            }
            // A page that was replaced meanwhile had its promises go with it.
            guard self.entry?.pageKey == key else { return }
            self.reply(id, ok: outcome.0, outcome.1)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let decision = AddonNavigation.decide(action.request.url, id: entry?.id ?? "", linkActivated: action.navigationType == .linkActivated)
        switch decision {
        case .allow: decisionHandler(.allow)
        case .openInTab(let url):
            decisionHandler(.cancel)
            browser?.open(url, foreground: true)
        case .cancel: decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        lastDark = dark
        crashes = crashes.filter { Date().timeIntervalSince($0) < 60 }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failedLoad(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failedLoad(error)
    }

    private func failedLoad(_ error: any Error) {
        let ns = error as NSError
        // A navigation the policy cancelled, or a reload over a load: not a failure.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        fail("the page didn't load: \(ns.localizedDescription)")
    }

    /// The page's process died. Reloaded, unless it keeps happening — then
    /// the slot is given back to its own view rather than flickering.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count >= 3 {
            fail("the page stopped three times in a minute")
            return
        }
        AddonSync.shared.noteFromHost("\(entry?.id ?? "addon"): the page's process stopped; reloading it")
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// `window.open` and `target=_blank`: a link the person clicked to a web
    /// page opens in a tab; a script opening a window gets nothing.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if case .openInTab(let url) = AddonNavigation.decide(action.request.url, id: "", linkActivated: action.navigationType == .linkActivated) {
            browser?.open(url, foreground: true)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        // No modal from a sidebar: logged, and answered at once.
        AddonSync.shared.noteFromHost("\(entry?.id ?? "addon") alert: \(message.prefix(200))")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    // MARK: oauth windows

    private func cancelOAuth() {
        let open = oauth
        oauth = []
        for window in open { window.finish(.failure(AddonBridgeError("cancelled", "The addon's page went away"))) }
    }
}
