import Foundation
import WebKit

// browser_network_requests: what an agent's tab fetched — method, address,
// status, kind — heard from WebKit itself, not from a script in the page.
//
// WebKit's resource-load delegate (`_setResourceLoadDelegate:`, SPI since
// macOS 10.15, what Safari's own tooling listens to) reports every request a
// page makes, in every frame, with its HTTP method and the response's status.
// Nothing is added to the page, so a page can't see it, spoof it or break it.
//
// Only tabs an agent works on are listened to (`AgentTabs.prepare` calls
// `watch`), from that moment on: the pages people browse pay nothing. Each
// page keeps its last `cap` requests, cleared when its main frame loads a new
// document, so the list is "since this page loaded", as Playwright's is.

@MainActor
final class NetLog: NSObject {
    struct Entry {
        let id: UInt64
        let method: String
        let url: String
        let kind: String
        var status: Int?
        var error: String?
        /// Order of asking, per log; `done` once WebKit says it ended.
        var seq: UInt64 = 0
        var done = false
        /// When it was asked, and when its answer began (a status) or it ended.
        var at = Date()
        var answeredAt: Date? = nil
    }

    static let cap = 300
    private static var logs: [ObjectIdentifier: NetLog] = [:]
    private static let setter = NSSelectorFromString("_setResourceLoadDelegate:")

    private weak var web: WKWebView?
    private(set) var entries: [Entry] = []
    /// The last request's `seq`, and the main-frame document's (a new page).
    private(set) var sequence: UInt64 = 0
    private(set) var documentAt: UInt64 = 0

    private init(_ web: WKWebView) { self.web = web }

    /// Start listening to this tab's page, once per web view.
    static func watch(_ tab: Tab) {
        guard let web = tab.built, log(for: web) == nil, web.responds(to: setter) else { return }
        let log = NetLog(web)
        logs[ObjectIdentifier(web)] = log // the delegate property is weak
        web.perform(setter, with: log)
    }

    /// A dead view's address is soon a new view's: an entry counts only while
    /// its own view is alive, or a new page would be read from (and never
    /// listened to under) the log of the one before it.
    static func log(for web: WKWebView) -> NetLog? {
        logs = logs.filter { $0.value.web != nil }
        return logs[ObjectIdentifier(web)].flatMap { $0.web === web ? $0 : nil }
    }
    static var available: Bool { WKWebView.instancesRespond(to: setter) }

    // MARK: - _WKResourceLoadDelegate

    @objc(webView:resourceLoad:didSendRequest:)
    func sent(_ web: WKWebView, _ load: NSObject, _ request: URLRequest) {
        record(load, method: request.httpMethod, url: request.url)
    }

    @discardableResult
    private func record(_ load: NSObject, method: String? = nil, url: URL? = nil) -> Int {
        let kind = Self.kind(Self.read(load, "resourceType") as? Int ?? -1)
        sequence += 1
        // A new document in the main frame (no parent frame): a new page.
        if kind == "document", Self.read(load, "parentFrame") == nil { entries.removeAll(); documentAt = sequence }
        entries.append(Entry(
            id: Self.id(load),
            method: method ?? (Self.read(load, "originalHTTPMethod") as? String) ?? "GET",
            url: (url ?? (Self.read(load, "originalURL") as? URL))?.absoluteString ?? "",
            kind: kind,
            seq: sequence
        ))
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        return entries.count - 1
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func received(_ web: WKWebView, _ load: NSObject, _ response: URLResponse) {
        update(load) { $0.status = (response as? HTTPURLResponse)?.statusCode ?? $0.status ?? 200; $0.answeredAt = $0.answeredAt ?? Date() }
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func completed(_ web: WKWebView, _ load: NSObject, _ error: Error?, _ response: URLResponse?) {
        update(load) { entry in
            entry.done = true
            entry.answeredAt = entry.answeredAt ?? Date()
            if let http = response as? HTTPURLResponse { entry.status = http.statusCode }
            if let error { entry.error = (error as NSError).localizedDescription }
            else if entry.status == nil { entry.status = 200 } // file:, data: — no HTTP status, but it came
        }
    }

    private func update(_ load: NSObject, _ change: (inout Entry) -> Void) {
        let id = Self.id(load)
        // From the disk cache WebKit reports only the end, never the send.
        let i = entries.lastIndex(where: { $0.id == id }) ?? record(load)
        change(&entries[i])
    }

    private static func id(_ load: NSObject) -> UInt64 {
        (read(load, "resourceLoadID") as? NSNumber)?.uint64Value ?? 0
    }

    /// A property of `_WKResourceLoadInfo`, or nil when this WebKit has no
    /// such property (plain KVC would throw on an unknown key).
    private static func read(_ load: NSObject, _ key: String) -> Any? {
        load.responds(to: NSSelectorFromString(key)) ? load.value(forKey: key) : nil
    }

    /// `_WKResourceLoadInfoResourceType`, in WebKit's order.
    nonisolated static func kind(_ raw: Int) -> String {
        let names = ["manifest", "beacon", "csp-report", "document", "image", "fetch", "font", "media", "object", "ping", "script", "stylesheet", "xhr", "xslt"]
        return names.indices.contains(raw) ? names[raw] : "other"
    }

    // MARK: - what a page asked its server (Jev's waits)

    /// The calls a page makes for data, not for its looks.
    nonisolated static let calls: Set<String> = ["xhr", "fetch"]

    /// Where the log is now: requests after this are the next action's.
    static func mark(_ web: WKWebView) -> UInt64 { log(for: web)?.sequence ?? 0 }

    /// A page's own bookkeeping, never its answer: analytics, logging and
    /// beacons (Google's `log?format=json` is an xhr after every click).
    nonisolated static func noise(_ e: Entry) -> Bool {
        if ["beacon", "ping", "csp-report"].contains(e.kind) { return true }
        guard let url = URL(string: e.url) else { return false }
        let host = url.host?.lowercased() ?? ""
        if ["google-analytics.", "googletagmanager.", "doubleclick.", "analytics.", "stats.", "telemetry.", "sentry."].contains(where: host.contains) { return true }
        return ["log", "logs", "collect", "beacon", "ping", "track", "telemetry", "metrics", "rum", "csi", "jserror", "gen_204"]
            .contains(url.lastPathComponent.lowercased())
    }

    /// Still waited for: not back, no status yet, and asked less than
    /// `expire` ago. A call with a status is answered (a stream that stays
    /// open, a long poll); a call that never said anything is given up on
    /// (WebKit never ends an aborted xhr).
    nonisolated static func pending(_ e: Entry, now: Date = Date(), expire: TimeInterval = 1.5) -> Bool {
        !e.done && e.status == nil && now.timeIntervalSince(e.at) < expire
    }

    /// The page's data calls since `mark` (nil: since the page loaded), less
    /// its bookkeeping; nil when the page left for another since `mark`.
    static func dataCalls(_ web: WKWebView, after mark: UInt64?) -> [Entry]? {
        guard let log = log(for: web), mark.map({ log.documentAt <= $0 }) ?? true else { return nil }
        let since = mark ?? log.documentAt
        return log.entries.filter { $0.seq > since && calls.contains($0.kind) && !noise($0) }
    }

    /// `mark`, or the start of the page now in the tab if it came after:
    /// what to wait on when the last action may have loaded a new page.
    static func current(_ web: WKWebView, _ mark: UInt64?) -> UInt64? {
        guard let log = log(for: web) else { return mark }
        return max(mark ?? log.documentAt, log.documentAt)
    }

    /// Something went to the server that changes things there: a non-GET
    /// request (a document or a data call) since `mark`, not bookkeeping.
    static func posted(_ web: WKWebView, after mark: UInt64) -> Bool {
        guard let log = log(for: web) else { return false }
        return log.entries.contains { $0.seq > mark && (calls.contains($0.kind) || $0.kind == "document") && !noise($0)
            && !["GET", "HEAD", "OPTIONS"].contains($0.method.uppercased()) }
    }

    /// Until the page's data calls since `mark` are answered and nothing new
    /// was answered for `linger` (a reply often asks for the next thing), or
    /// `cap`: what they were. A page that left for another in the meantime
    /// has nothing to wait for here (its load is waited for).
    static func answered(_ web: WKWebView, after mark: UInt64?, cap: TimeInterval = 3, linger: TimeInterval = 0) async -> [Entry] {
        let deadline = Date().addingTimeInterval(cap)
        while let out = dataCalls(web, after: mark), Date() < deadline, !quiet(out, linger: linger) {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return dataCalls(web, after: mark) ?? []
    }

    /// Nothing pending, and the last answer at least `linger` ago (or no call at all).
    nonisolated static func quiet(_ calls: [Entry], now: Date = Date(), linger: TimeInterval = 0.15) -> Bool {
        guard !calls.contains(where: { pending($0, now: now) }) else { return false }
        guard let last = calls.compactMap(\.answeredAt).max() else { return true }
        return now.timeIntervalSince(last) >= linger
    }

    /// `200 GetShoppingResults`, `pending batchexecute`: a call for the trace.
    nonisolated static func brief(_ e: Entry) -> String {
        let outcome = e.error != nil ? "failed" : !e.done ? "pending" : e.status.map(String.init) ?? "?"
        return outcome + " " + String((URL(string: e.url)?.lastPathComponent ?? e.url).prefix(48))
    }

    // MARK: - the tool

    nonisolated static let staticKinds: Set<String> = ["image", "font", "media", "script", "stylesheet", "object", "manifest", "xslt", "other"]

    /// Playwright's lines: `[GET] url => [200]`, the kind after. Static
    /// assets that came back fine are left out unless asked for.
    nonisolated static func lines(_ entries: [Entry], includeStatic: Bool, limit: Int) -> [String] {
        let kept = entries.filter { e in
            includeStatic || !staticKinds.contains(e.kind) || e.error != nil || (e.status ?? 0) >= 400
        }
        return kept.suffix(limit).map { e in
            let outcome: String
            if let error = e.error { outcome = "failed: \(error)" }
            else if let status = e.status { outcome = "[\(status)]" }
            else { outcome = "pending" }
            return "[\(e.method)] \(e.url) => \(outcome) (\(e.kind))"
        }
    }

    nonisolated static var tool: [String: Any] { [
        "name": "browser_network_requests",
        "description": "Requests your tab's page made since it loaded (heard from the moment an agent first used the tab): method, URL, status, kind. Successful static assets are left out unless includeStatic.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "includeStatic": ["type": "boolean", "description": "Also list images, scripts, styles and fonts that loaded fine"],
                "limit": ["type": "number", "description": "Newest N, default 100, at most 300"],
                "reason": Tools.reasonProperty,
                "tab": Tools.tabProperty,
            ] as [String: Any],
            "required": [String](),
        ] as [String: Any],
    ] }

    static func call(_ args: [String: Any], in browser: Browser) throws -> [Tools.Content] {
        let tab = try Tools.current(browser) // prepare() → watch()
        guard available else { throw Tools.Failure(text: "this macOS's WebKit doesn't report requests — read performance.getEntriesByType('resource') with browser_evaluate instead") }
        guard let web = tab.built, let log = log(for: web) else { throw Tools.Failure(text: "the tab has no page yet") }
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 100, 1), cap)
        let shown = lines(log.entries, includeStatic: (args["includeStatic"] as? Bool) ?? false, limit: limit)
        let body = shown.isEmpty ? "No requests since this page loaded (or since an agent first used the tab)." : shown.joined(separator: "\n")
        return [.text("### Network requests\n\(body)\n\n\(Tools.pageLine(tab))")]
    }
}
