import AppKit
import Foundation
import WebKit

// What `window.copper` does on the Mac (contract §5.2): one function per
// bridge method, called by AddonSlotHost with a message it has already
// checked came from the slot's own page. Every method that reaches past the
// page needs its capability in the manifest; a missing one is `denied`,
// whatever the page asks.
//
// Nothing secret crosses into the page: the cloud's session, model keys and
// the person's cookies all stay native. `copper.fetch` goes out from here,
// without cookies, only to the manifest's hosts; `copper.oauth.authorize`
// hands back only the redirect URL it was told to wait for.

struct AddonBridgeError: Error, Equatable {
    var code: String
    var message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

@MainActor
enum AddonBridge {
    static func call(_ method: String, _ params: [String: Any], host: AddonSlotHost, entry: AddonInstalled) async throws -> Any {
        let granted = entry.granted
        func need(_ capability: AddonCapability) throws {
            guard granted.contains(capability) else {
                throw AddonBridgeError("denied", "\(method) needs the \"\(capability.rawValue)\" capability in manifest.json")
            }
        }
        func text(_ key: String) throws -> String {
            guard let value = params[key] as? String else { throw AddonBridgeError("bad_request", "\(method) needs \(key) as a string") }
            return value
        }
        switch method {
        case "info":
            return [
                "bridge": Addons.bridge, "platform": Addons.platform, "appVersion": Fork.version, "slot": host.slot.rawValue,
                "addon": ["id": entry.id, "version": entry.version],
                // Everything the bridge has is there on the Mac, so what the
                // manifest asks for is what it gets.
                "capabilities": AddonCapability.allCases.filter(granted.contains).map(\.rawValue),
                "theme": ["dark": host.dark],
            ] as [String: Any]
        case "identity":
            try need(.identity)
            let cloud = Cloud.shared
            guard let account = cloud.account, let link = cloud.link else { return NSNull() }
            return ["email": account.email, "name": account.displayName, "userId": account.userId.uuidString.lowercased(), "cloud": link.host]
        case "settings":
            return entry.settings.object
        case "storage.get":
            try need(.storage)
            return try AddonStorage.shared(entry.id).get(try text("key"))
        case "storage.set":
            try need(.storage)
            try AddonStorage.shared(entry.id).set(try text("key"), params["value"] ?? NSNull())
            return true
        case "storage.remove":
            try need(.storage)
            try AddonStorage.shared(entry.id).remove(try text("key"))
            return true
        case "storage.keys":
            try need(.storage)
            return AddonStorage.shared(entry.id).keys()
        case "fetch":
            try need(.fetch)
            return try await AddonFetch.run(params, rules: entry.hostRules)
        case "oauth.authorize":
            try need(.oauth)
            return try await AddonOAuth.authorize(params, rules: entry.hostRules, host: host)
        case "openUrl":
            try need(.openURL)
            guard let url = URL(string: try text("url")), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw AddonBridgeError("bad_request", "openUrl takes an http or https address")
            }
            guard let browser = host.browser else { throw AddonBridgeError("unavailable", "The window is gone") }
            browser.open(url, foreground: true)
            return true
        case "page.current":
            try need(.page)
            return currentPage(host.browser)
        case "ui.close":
            Agent.shared.open = false
            return true
        case "agent.state":
            try need(.agent)
            return agentState()
        case "agent.setModel":
            try need(.agent)
            guard let tier = Intelligence.Tier(rawValue: try text("id")) else {
                throw AddonBridgeError("bad_request", "No model \"\(params["id"] as? String ?? "")\"; agent.state() lists them")
            }
            Intelligence.shared.keys.tier = tier
            return true
        case "agent.send":
            try need(.agent)
            let words = try text("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { throw AddonBridgeError("bad_request", "agent.send needs some text") }
            guard !Agent.shared.busy else { throw AddonBridgeError("bad_request", "The agent is still answering; stop it first") }
            guard let browser = host.browser else { throw AddonBridgeError("unavailable", "The window is gone") }
            Agent.shared.ask(words, in: browser)
            return true
        case "agent.stop":
            try need(.agent)
            // Stop on an idle agent would only leave a "Stopped" line behind.
            if Agent.shared.busy { Agent.shared.stop() }
            return true
        case "agent.clear":
            try need(.agent)
            Agent.shared.clear()
            return true
        default:
            throw AddonBridgeError("bad_request", "No bridge method \"\(method)\"")
        }
    }

    /// A JSON number (not a boolean) as a Double.
    nonisolated static func number(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// `{url, title}` of the tab in front, or null. A private tab is null
    /// too: an addon has no business knowing where one is.
    static func currentPage(_ browser: Browser?) -> Any {
        guard let tab = browser?.active, !tab.shy, let url = tab.address else { return NSNull() }
        return ["url": url.absoluteString, "title": tab.title]
    }

    /// `copper.agent.state()`: the one conversation the ⌘E pane shows.
    static func agentState() -> [String: Any] {
        let agent = Agent.shared
        let brain = Intelligence.shared
        return [
            "available": true,
            "busy": agent.busy,
            "models": Intelligence.Tier.allCases.map { ["id": $0.rawValue, "name": $0.title, "ready": brain.modelReady, "detail": $0.blurb] },
            "model": brain.tier.rawValue,
            "items": agent.items.map(item),
        ]
    }

    static func item(_ item: Agent.Item) -> [String: Any] {
        var out: [String: Any] = ["id": item.id.uuidString.lowercased(), "at": AddonTime.text(item.at)]
        switch item.kind {
        case .user:
            out["role"] = "user"
            out["text"] = item.text
        case .assistant:
            // Words on the way to a tool call are part of the activity, not
            // the answer (Agent.Item.aside).
            out["role"] = item.aside ? "activity" : "assistant"
            out["text"] = item.text
        case .tool:
            out["role"] = "activity"
            out["text"] = item.title.isEmpty ? item.tool : item.title
            let detail = [item.text, item.warning].filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty { out["detail"] = detail }
        case .note:
            out["role"] = item.ok ? "activity" : "error"
            out["text"] = item.text
        case .drive:
            out["role"] = "drive"
            out["text"] = item.title.isEmpty ? item.text : item.title
            if !item.title.isEmpty, !item.text.isEmpty { out["detail"] = item.text }
        }
        if item.running { out["busy"] = true }
        return out
    }
}

// MARK: - storage

/// `copper.storage`: one JSON object per addon in
/// `addons/data/<id>/storage.json` (0600), shared by every window's page,
/// at most 1 MB in all, keys at most 128 characters. Native rather than the
/// page's localStorage, so every window sees the same values at once and
/// "clear website data" in a browsing profile never touches them.
final class AddonStorage {
    static let maxBytes = 1024 * 1024
    static let maxKey = 128

    private static var open: [String: AddonStorage] = [:]

    @MainActor static func shared(_ id: String) -> AddonStorage {
        if let known = open[id] { return known }
        let storage = AddonStorage(file: AddonSync.shared.store.dataDir(id).appendingPathComponent("storage.json"))
        open[id] = storage
        return storage
    }

    let file: URL
    private var values: [String: Any]

    init(file: URL) {
        self.file = file
        values = (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }

    func get(_ key: String) throws -> Any {
        try check(key)
        return values[key] ?? NSNull()
    }

    func set(_ key: String, _ value: Any) throws {
        try check(key)
        guard JSONSerialization.isValidJSONObject([value]) else { throw AddonBridgeError("bad_request", "storage keeps JSON values") }
        var next = values
        next[key] = value
        try save(next)
    }

    func remove(_ key: String) throws {
        try check(key)
        guard values[key] != nil else { return }
        var next = values
        next[key] = nil
        try save(next)
    }

    func keys() -> [String] { values.keys.sorted() }

    private func check(_ key: String) throws {
        guard !key.isEmpty, key.count <= AddonStorage.maxKey else {
            throw AddonBridgeError("bad_request", "storage keys are 1–\(AddonStorage.maxKey) characters")
        }
    }

    private func save(_ next: [String: Any]) throws {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys]) } catch {
            throw AddonBridgeError("bad_request", "storage keeps JSON values")
        }
        guard data.count <= AddonStorage.maxBytes else {
            throw AddonBridgeError("bad_request", "storage is limited to 1 MB per addon")
        }
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AddonStore.writeAtomically(data, to: file, mode: 0o600)
        } catch {
            throw AddonBridgeError("internal", "storage couldn't be written: \(error.localizedDescription)")
        }
        values = next
    }
}

// MARK: - fetch

/// `copper.fetch`: a request from Copper, not the page — no cookies, no
/// cached credentials, no shared cache — to a host the manifest lists, over
/// https (http only to 127.0.0.1 and localhost). Redirects are followed
/// only while they stay on listed hosts; one that leaves is handed back as
/// the 3xx it was.
enum AddonFetch {
    static let maxBody = 2 * 1024 * 1024
    static let maxResponse = 8 * 1024 * 1024
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    /// Headers that are the transport's to set, or would carry ambient
    /// credentials; dropped as a browser's fetch drops them.
    static let forbidden: Set<String> = ["cookie", "cookie2", "host", "content-length", "connection", "transfer-encoding",
                                         "keep-alive", "upgrade", "te", "trailer", "proxy-authorization", "expect"]

    static func request(_ params: [String: Any], rules: [AddonHostRule]) throws -> URLRequest {
        guard let text = params["url"] as? String, let url = URL(string: text), url.host != nil else {
            throw AddonBridgeError("bad_request", "fetch needs an absolute url")
        }
        guard AddonHostRule.allows(url, rules: rules) else {
            throw AddonBridgeError("denied", "\(url.host ?? text) is not in the manifest's permissions.hosts (or not https)")
        }
        let method = (params["method"] as? String ?? "GET").uppercased()
        guard methods.contains(method) else { throw AddonBridgeError("bad_request", "fetch can't send \(method)") }
        let timeout = min(max((AddonBridge.number(params["timeoutMs"]) ?? 30_000) / 1000, 1), 120)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in params["headers"] as? [String: Any] ?? [:] where !forbidden.contains(name.lowercased()) {
            guard let value = value as? String else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = params["body"] as? String {
            let data = Data(body.utf8)
            guard data.count <= maxBody else { throw AddonBridgeError("bad_request", "fetch bodies are limited to 2 MB") }
            if method != "GET" && method != "HEAD" { request.httpBody = data }
        }
        return request
    }

    static func run(_ params: [String: Any], rules: [AddonHostRule]) async throws -> [String: Any] {
        let request = try request(params, rules: rules)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        let delegate = Fetching(rules: rules)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    /// One request's delegate: the redirect rule, the size cap, the answer.
    private final class Fetching: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let rules: [AddonHostRule]
        var continuation: CheckedContinuation<[String: Any], Error>?
        private var data = Data()
        private var response: HTTPURLResponse?
        private let lock = NSLock()

        init(rules: [AddonHostRule]) { self.rules = rules }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, AddonHostRule.allows(url, rules: rules) else { return completionHandler(nil) }
            var next = request
            next.httpShouldHandleCookies = false
            completionHandler(next)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            self.response = response as? HTTPURLResponse
            lock.unlock()
            if response.expectedContentLength > Int64(AddonFetch.maxResponse) {
                finish(.failure(AddonBridgeError("network", "The answer is larger than 8 MB")))
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.lock()
            data.append(chunk)
            let over = data.count > AddonFetch.maxResponse
            lock.unlock()
            if over {
                finish(.failure(AddonBridgeError("network", "The answer is larger than 8 MB")))
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                let code = (error as? URLError)?.code == .timedOut ? "timeout" : "network"
                finish(.failure(AddonBridgeError(code, error.localizedDescription)))
                return
            }
            lock.lock()
            let response = self.response
            let body = data
            lock.unlock()
            guard let response else { return finish(.failure(AddonBridgeError("network", "No HTTP answer"))) }
            var headers: [String: String] = [:]
            for (name, value) in response.allHeaderFields {
                if let name = name as? String { headers[name.lowercased()] = "\(value)" }
            }
            finish(.success(["status": response.statusCode, "headers": headers, "body": String(decoding: body, as: UTF8.self)]))
        }

        private func finish(_ result: Result<[String: Any], Error>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            switch result {
            case .success(let value): waiting?.resume(returning: value)
            case .failure(let error): waiting?.resume(throwing: error)
            }
        }
    }
}

// MARK: - oauth

/// `copper.oauth.authorize`: a small window on the person's own browsing
/// profile (so their single sign-on is already there) that loads `url` and
/// watches every navigation and redirect. The first one that starts with
/// `redirectPrefix` is stopped before it goes anywhere, the window closes,
/// and the page gets that URL — code and state in it. Nothing listens on a
/// loopback redirect's port; the address is only a marker.
@MainActor
final class AddonOAuth: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let defaultTimeout: TimeInterval = 300

    /// Whether `prefix` is a redirect this addon may wait for: loopback
    /// http with a port, or https on one of its hosts.
    static func validPrefix(_ prefix: String, rules: [AddonHostRule]) -> Bool {
        guard let url = URL(string: prefix), let host = url.host, !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "http": return AddonHostRule.isLoopback(host) && url.port != nil
        case "https": return AddonHostRule.allows(url, rules: rules)
        default: return false
        }
    }

    static func authorize(_ params: [String: Any], rules: [AddonHostRule], host: AddonSlotHost) async throws -> Any {
        guard let text = params["url"] as? String, let url = URL(string: text), url.host != nil else {
            throw AddonBridgeError("bad_request", "oauth.authorize needs url")
        }
        guard AddonHostRule.allows(url, rules: rules) else {
            throw AddonBridgeError("denied", "\(url.host ?? text) is not in the manifest's permissions.hosts (or not https)")
        }
        guard let prefix = params["redirectPrefix"] as? String, validPrefix(prefix, rules: rules) else {
            throw AddonBridgeError("bad_request", "redirectPrefix must be http://127.0.0.1:<port>/…, http://localhost:<port>/… or https on an allowed host")
        }
        let timeout = min(max((AddonBridge.number(params["timeoutMs"]) ?? defaultTimeout * 1000) / 1000, 5), 30 * 60)
        let window = AddonOAuth(url: url, prefix: prefix, owner: host)
        host.oauth.append(window)
        return try await withCheckedThrowingContinuation { continuation in
            window.continuation = continuation
            window.open(timeout: timeout)
        }
    }

    let url: URL
    let prefix: String
    weak var owner: AddonSlotHost?
    var continuation: CheckedContinuation<Any, Error>?
    private var window: NSWindow?
    private var web: WKWebView?
    private var timer: Timer?

    init(url: URL, prefix: String, owner: AddonSlotHost) {
        self.url = url
        self.prefix = prefix
        self.owner = owner
    }

    private func open(timeout: TimeInterval) {
        let config = WKWebViewConfiguration()
        // The person's own profile: the space in front's, else the shared one.
        config.websiteDataStore = Spaces.profileStore ?? Store.websites
        config.applicationNameForUserAgent = Web.userAgentName
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: config)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Sign in — \(owner?.entry?.name ?? "Addon")"
        window.contentView = web
        window.delegate = self
        if let parent = owner?.browser.flatMap(Windows.window(of:)) {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.midY - 340))
        } else {
            window.center()
        }
        self.window = window
        self.web = web
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failure(AddonBridgeError("timeout", "Sign-in took too long"))) }
        }
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: url))
    }

    func finish(_ result: Result<Any, Error>) {
        guard let waiting = continuation else { return }
        continuation = nil
        timer?.invalidate()
        timer = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        window?.delegate = nil
        window?.close()
        window = nil
        web = nil
        owner?.oauth.removeAll { $0 === self }
        switch result {
        case .success(let value): waiting.resume(returning: value)
        case .failure(let error): waiting.resume(throwing: error)
        }
    }

    /// Every navigation, a server redirect included, passes here first.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let next = action.request.url?.absoluteString, next.hasPrefix(prefix) {
            decisionHandler(.cancel)
            finish(.success(["url": next]))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let next = webView.url?.absoluteString, next.hasPrefix(prefix) {
            webView.stopLoading()
            finish(.success(["url": next]))
        }
    }

    /// A loopback redirect that slipped past (nothing listens there).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String
        if let failing, failing.hasPrefix(prefix) { finish(.success(["url": failing])) }
    }

    func windowWillClose(_ notification: Notification) {
        finish(.failure(AddonBridgeError("cancelled", "The sign-in window was closed")))
    }
}
