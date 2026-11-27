import AppKit
import WebKit

// browser_read: many pages in one call. A planner reading ten pages used to
// spend 2.6 calls on each (navigate, wait, evaluate or extract, tabs), and a
// navigate could answer before its page was there, so the next read landed
// on the old one. Here every address opens at once in a background tab of
// its own (never the user's), each is read only once it has really loaded
// (its own document, complete, titled, quiet a moment), and what comes back
// is the asked values (`want`, through jev_extract's model) or the page's
// text, short. The tabs close after. A human check is reported, never
// answered.

extension Tools {
enum Read {
    static let name = "browser_read"
    static let most = 12
    /// Read tabs open now, across parallel calls: together they keep to `most`.
    @MainActor static var inUse = 0
    /// No DOM change for this long after the load: the page has drawn its content.
    static let quiet: TimeInterval = 0.4
    /// A loaded page that never goes quiet (a ticker, a carousel) is read after this.
    static let restless: TimeInterval = 2.5
    static let defaultChars = 3000
    static let charRange = 200...20_000
    /// What the model is shown of a page for `want`: its head and its tail.
    /// Cost lever: was 24k (jev_extract's `full`); most asked values sit in the first part or the last.
    static let wantChars = 10_000
    /// Links shown with a page's text (and given to the `want` reader): a
    /// search or list page answers with where to go next, no click chain.
    static let links = 20
    /// `search`: queries per call, results read per query (`top`), results
    /// listed per query, and per read result its text and links (~2.5k chars a page).
    static let searchMost = 4
    static let topRange = 0...6
    static let defaultTop = 3
    static let listed = 6
    static let searchChars = 2000
    static let searchLinks = 6

    static var tool: [String: Any] {
        [
            "name": name,
            "description": "Read 1-12 pages, or search the web, in one call; prefer it to navigate/evaluate page by page. Each loads fully in a background tab. Per page: final URL, title, status, and the want values or text + links.",
            "inputSchema": ["type": "object", "properties": [
                "urls": ["type": "array", "items": ["type": "string"], "description": "1-12 full URLs"] as [String: Any],
                "search": ["type": "array", "items": ["type": "string"], "description": "1-4 web searches (words, not URLs), all at once: each lists its top results (title, URL, snippet) and reads its first `top` pages"] as [String: Any],
                "top": ["type": "number", "description": "Results read per search, 0-6; default \(defaultTop)"],
                "want": ["type": "string", "description": "Values to pull per page (JSON); omit for text"],
                "max_chars": ["type": "number", "description": "Text per page; default \(defaultChars)"],
                "reason": Tools.reasonProperty,
            ] as [String: Any]] as [String: Any],
        ]
    }

    // MARK: - the ask

    struct Ask: Equatable {
        var urls: [URL]
        var want: String?
        var maxChars: Int
        var search: [String] = []
        var top = defaultTop
        /// Links shown under each page's text.
        var links = Read.links
    }

    static func parse(_ args: [String: Any]) throws -> Ask {
        let queries: [Any]
        if let list = args["search"] as? [Any] { queries = list }
        else if let one = args["search"] as? String { queries = [one] }
        else { queries = [] }
        let search = queries.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard search.count == queries.count, search.count <= searchMost, args["search"] == nil || !search.isEmpty else {
            throw Failure(text: "search: 1 to \(searchMost) queries (words, not addresses) per call")
        }
        let raw: [Any]
        if let list = args["urls"] as? [Any] { raw = list }
        else if let one = args["urls"] as? String { raw = [one] } // one address, not in a list
        else if !search.isEmpty { raw = [] }
        else { throw Failure(text: "urls required: a list of 1 to \(most) full addresses (or search: 1 to \(searchMost) queries)") }
        guard (search.isEmpty ? 1...most : 0...most).contains(raw.count) else {
            throw Failure(text: "urls: 1 to \(most) addresses per call; got \(raw.count). Split them over several calls.")
        }
        let urls = try raw.map { item -> URL in
            guard let text = item as? String, let url = Address.url(from: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Failure(text: "not a web address: \(item) — pass full URLs such as https://example.com/page")
            }
            return url
        }
        let want = (args["want"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = try Tools.number(args, "max_chars", within: 1e9).map { Int($0) } ?? (search.isEmpty ? defaultChars : searchChars)
        let top = try Tools.number(args, "top", within: 1e9).map { Int($0) } ?? defaultTop
        return Ask(urls: urls, want: want?.isEmpty == false ? want : nil,
                   maxChars: min(max(chars, charRange.lowerBound), charRange.upperBound),
                   search: search, top: min(max(top, topRange.lowerBound), topRange.upperBound),
                   links: search.isEmpty ? links : searchLinks)
    }

    // MARK: - when a page is ready

    /// What one look at a page says.
    struct Probe: Equatable {
        var href: String
        var state: String
        var title: String
        /// An HTML document (JSON and plain text have no title to wait for).
        var html: Bool
        /// Milliseconds since the DOM last changed.
        var quietMs: Double
        /// This document's own mark (set by the first look at it), to tell it from the next one.
        var doc = ""
    }

    enum Verdict: Equatable { case wait, ready, timeout }

    /// Its own document (a fresh tab's first is about:blank), loaded, titled;
    /// a page that never names itself is loaded once it has kept still a
    /// while (Arrival.untitled), as a navigation's answer is.
    static func loaded(_ p: Probe, loading: Bool) -> Bool {
        !loading && p.state == "complete" && !p.href.isEmpty && p.href != "about:blank"
            && (!p.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !p.html || p.quietMs >= Arrival.untitled * 1000)
    }

    /// `loadedFor`: how long the page has looked `loaded`; `elapsed`: since it was opened.
    static func verdict(_ p: Probe?, loading: Bool, loadedFor: TimeInterval, elapsed: TimeInterval) -> Verdict {
        if let p, loaded(p, loading: loading), p.quietMs >= quiet * 1000 || loadedFor >= restless { return .ready }
        return elapsed >= Arrival.cap ? .timeout : .wait
    }

    /// At the cap: worth reading only when its own document has its content in.
    static func partial(_ p: Probe?) -> Bool {
        guard let p else { return false }
        return !p.href.isEmpty && p.href != "about:blank" && p.state != "loading"
    }

    /// A page that is a human check (Cloudflare's "Just a moment...", a
    /// CAPTCHA): its title says so, or its text does and it is short — an
    /// article that talks about CAPTCHAs is not one.
    static func humanCheck(title: String, text: String) -> String? {
        let low = title.lowercased()
        for words in ["just a moment", "attention required", "client challenge", "checking your browser", "ddos-guard"] where low.contains(words) {
            return words
        }
        if let hit = Ultrafast.humanCheck(title) { return hit }
        return text.count < 1500 ? Ultrafast.humanCheck(text) : nil
    }

    /// One evaluation's view of the page: address, title and text all from the same document.
    struct Capture: Equatable {
        var doc: String
        var href: String
        var title: String
        var text: String
        /// The links in the page's main part, when asked for (`links` in capture).
        var links: [Link] = []
    }

    struct Link: Equatable {
        var text: String
        var url: String
        /// On a results page: the words of the result's block around the link.
        var snippet = ""
    }

    /// Where a link on the page's own site seems to lead when one other
    /// site's address rides in its query (a search result's redirect:
    /// `/url?q=https://…`, or the address base64url-encoded, maybe behind a
    /// two-letter tag): only a hint beside the link's real address, which
    /// may well be a login, a consent or a page of its own. Nil for any other link.
    static func target(_ link: String, page: String) -> String? {
        guard let parts = URLComponents(string: link), let host = parts.host?.lowercased(),
              host == URLComponents(string: page)?.host?.lowercased() else { return nil }
        func away(_ value: String) -> String? {
            guard let to = URLComponents(string: value), ["http", "https"].contains(to.scheme?.lowercased() ?? ""),
                  let there = to.host?.lowercased(), !there.isEmpty, there != host else { return nil }
            return value
        }
        let found = Set((parts.queryItems ?? []).compactMap(\.value).compactMap { value in
            away(value) ?? [value, String(value.dropFirst(2))].lazy.compactMap({ away(unbase64($0) ?? "") }).first
        })
        // Two or more (a comparison, a share of several pages): no one place it goes.
        return found.count == 1 ? found.first : nil
    }

    /// A link back to this same page with more parameters (its sorting,
    /// filters, next pages): every one of the page's own parameters kept as
    /// it is. Another value for one of them (`?id=`, `?v=`) is another page.
    static func variant(_ link: URLComponents?, of page: URLComponents?) -> Bool {
        guard let link, let page, link.host?.lowercased() == page.host?.lowercased(), link.path == page.path else { return false }
        let has = Set((link.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" })
        return (page.queryItems ?? []).allSatisfy { has.contains("\($0.name)=\($0.value ?? "")") }
    }

    /// base64url (no padding) as text; nil when it isn't.
    static func unbase64(_ text: String) -> String? {
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        plain += String(repeating: "=", count: (4 - plain.count % 4) % 4)
        return Data(base64Encoded: plain).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Longest destination listed (a redirect's, else the link's): longer ones are opaque tracking wrappers or session links; their words stay in the text.
    static let linkChars = 200

    /// The links block under a page's text: at most `links`, each at its real
    /// address, a redirect's destination as a hint after it, one per
    /// address (two pages on the way to one place are both listed), none
    /// back to this same page with more parameters.
    static func linkLines(_ links: [Link], page: String, most: Int = Read.links) -> String {
        let here = URLComponents(string: page)
        var seen = Set<String>(), lines: [String] = []
        for link in links where lines.count < most {
            let hint = target(link.url, page: page), to = hint ?? link.url
            guard to.count <= linkChars, !variant(URLComponents(string: link.url), of: here),
                  seen.insert(link.url.split(separator: "#").first.map(String.init) ?? link.url).inserted else { continue }
            lines.append("- [\(Tools.oneLine(link.text, limit: 80))](\(link.url))" + (hint.map { " → \($0)" } ?? ""))
        }
        return lines.isEmpty ? "" : "\n\nLinks:\n" + lines.joined(separator: "\n")
    }

    enum Taken: Equatable { case page(Capture), again, failed(Status, String) }

    /// A capture is read only when it is the document the probe found ready
    /// (`doc`): a redirect or a new document between the two is waited out,
    /// and at the cap reported, never read with the other one's address.
    /// `moved`: a navigation started or landed since the probe, or is under
    /// way (Nav.still) — the same document id can be the one being left.
    static func taken(_ capture: Capture?, doc: String?, elapsed: TimeInterval, moved: Bool = false) -> Taken {
        let late = elapsed >= Arrival.cap
        guard !moved else {
            return late ? .failed(.timeout, "the page was still navigating at \(Int(Arrival.cap)) s; nothing read") : .again
        }
        guard let capture else {
            return late ? .failed(.timeout, "the page did not answer a read by \(Int(Arrival.cap)) s; nothing read") : .again
        }
        guard let doc, !doc.isEmpty, capture.doc == doc else {
            return late ? .failed(.timeout, "the page changed documents as it was read; nothing read") : .again
        }
        return .page(capture)
    }

    /// A human check seen for `checking` s: keep waiting for it to clear itself?
    static func waitOut(checking: TimeInterval, elapsed: TimeInterval) -> Bool {
        checking < Ultrafast.humanCheckGrace && elapsed < Arrival.cap
    }

    /// An HTTP status that makes the page an error page.
    static func httpError(_ status: Int?) -> String? {
        guard let status, status >= 400 else { return nil }
        return "HTTP \(status): the site answered with an error page"
    }

    /// A read tab's navigation policy (Browser's policy hooks): a page may
    /// load and redirect, but a read never starts a download, hands an
    /// address to another app, or follows a link Copper itself acts on
    /// (`native`: a canvas join, an extension's sign-in answer). Nil: allowed; else why not.
    static func refusal(scheme: String, download: Bool, native: Bool = false) -> String? {
        if download { return "it is a file download; a read saves nothing." }
        if native { return "it is a link Copper acts on itself (a join or sign-in); a read follows none." }
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else { return "it leads to another app (\(scheme):); a read opens none." }
        return nil
    }

    // MARK: - the answer

    enum Status: String { case ok, timeout, blocked, error }

    struct Result: Equatable {
        var asked: String
        var url = ""
        var title = ""
        var status: Status = .error
        /// The asked values (JSON) or the page's text.
        var body = ""
        var note = ""
        /// `want` was asked but the reader gave no values: the body is the page's text.
        var extractFailed = false
        /// A search's results page: its result links.
        var links: [Link] = []
    }

    /// One block per page, in the order asked, inside one fence: titles,
    /// text and values are the pages' words.
    static func format(_ results: [Result], seconds: Double) -> String {
        let head = "browser_read: \(results.count) page\(results.count == 1 ? "" : "s") in \(String(format: "%.1f", seconds)) s (\(counts(results))); tabs closed."
        return head + "\n" + Tools.fence(blocks(results).joined(separator: "\n"))
    }

    /// "2 ok, 1 timeout; 1 extract failed, text instead"
    static func counts(_ results: [Result]) -> String {
        var counts: [String] = []
        for status in [Status.ok, .timeout, .blocked, .error] {
            let n = results.filter { $0.status == status }.count
            if n > 0 { counts.append("\(n) \(status.rawValue)") }
        }
        let failed = results.filter(\.extractFailed).count
        return counts.joined(separator: ", ") + (failed > 0 ? "; \(failed) extract failed, text instead" : "")
    }

    static func blocks(_ results: [Result]) -> [String] {
        results.enumerated().map { pair -> String in
            let (i, r) = pair
            var line = "[\(i + 1)] \(r.status.rawValue) · " + (r.url.isEmpty || r.url == r.asked ? r.asked : "\(r.asked) → \(r.url)")
            if !r.title.isEmpty { line += " · " + Tools.pageWords(r.title) }
            if !r.note.isEmpty { line += " — " + r.note }
            return r.body.isEmpty ? line : line + "\n" + r.body
        }
    }

    // MARK: - the run

    /// How long a call waits for free read tabs: parallel calls and other
    /// planner sessions on one browser queue for the pool, they don't fail.
    static let poolWait: TimeInterval = 60
    /// Calls waiting for read tabs, first come first served: a big call is not passed over by small ones.
    @MainActor static var line: [UUID] = []

    /// A waiting call's turn: first in line and its pages fit.
    static func admitted(_ me: UUID, line: [UUID], inUse: Int, count: Int) -> Bool {
        line.first == me && inUse + count <= most
    }

    /// The pool stayed full for the whole wait: every page a timeout, nothing opened. Nil: keep waiting.
    static func poolFull(waited: TimeInterval, urls: [URL]) -> [Result]? {
        guard waited >= poolWait else { return nil }
        return urls.map { Result(asked: $0.absoluteString, status: .timeout,
                                 note: "waited \(Int(poolWait)) s for a free read tab (\(most) in use by other calls); nothing read") }
    }

    @MainActor
    static func run(_ args: [String: Any], in browser: Browser) async throws -> [Content] {
        let ask = try parse(args)
        let keys = Intelligence.shared.effective
        if ask.want != nil, !Intelligence.shared.modelReady {
            throw Failure(text: "want needs a model (Settings › Intelligence › Model access) to read for you; call again without want for each page's text")
        }
        let started = Date()
        if !ask.search.isEmpty { return [.text(try await search(ask, keys: keys, in: browser, started: started))] }
        var results = try await pages(ask.urls, ask: ask, keys: keys, in: browser)
        try await rescue(&results, ask: ask) { try await pages($0, ask: ask, keys: keys, in: browser, results: true) }
        let seconds = Date().timeIntervalSince(started)
        Tools.summary?.line = "read \(results.count) · \(results.filter { $0.status == .ok }.count) ok · " + String(format: "%.1f s", seconds)
        return [.text(format(results, seconds: seconds))]
    }

    /// Each address in a read tab of its own, all at once (`results`: a
    /// search's results pages, read for their result links).
    @MainActor
    static func pages(_ urls: [URL], ask: Ask, keys: Intelligence.Keys, in browser: Browser, results: Bool = false) async throws -> [Result] {
        guard !urls.isEmpty else { return [] }
        // Parallel calls share one pool of read tabs; a call waits its turn
        // for room (poolWait), then reports the wait.
        let queued = Date(), me = UUID()
        line.append(me)
        defer { line.removeAll { $0 == me } }
        while !admitted(me, line: line, inUse: inUse, count: urls.count) {
            try Task.checkCancellation()
            if let full = poolFull(waited: Date().timeIntervalSince(queued), urls: urls) { return full }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        line.removeFirst()
        inUse += urls.count
        defer { inUse -= urls.count }
        let started = Date()
        // Behind the user's tab, at the end of the row; each staged so it paints.
        let tabs = urls.map { url -> Tab in
            let tab = browser.open(url, foreground: false, atEnd: true, readOnly: true)
            AgentTabs.prepare(tab)
            return tab
        }
        defer { for tab in tabs { Tools.close(tab) } }
        var out = urls.map { Result(asked: $0.absoluteString) }
        await withTaskGroup(of: (Int, Result).self) { group in
            for (i, tab) in tabs.enumerated() {
                group.addTask { @MainActor in
                    (i, await one(tab, asked: urls[i], ask: ask, keys: keys, started: started, results: results))
                }
            }
            for await (i, result) in group { out[i] = result }
        }
        return out
    }

    // MARK: - search

    /// Where a query's results are read: an engine whose results page needs
    /// no script, rarely asks for a human check, and links each result's real
    /// address (in its redirect's query, which `target` reads).
    /// shortcut: one fixed engine, no setting; make it a preference if users ask.
    static func engine(_ query: String, on base: String = fallbacks[0].base) -> URL? {
        // Google's own escaping (`+` and all), its query on the engine's page.
        Google.url(for: query)?.absoluteString.split(separator: "?", maxSplits: 1).last.flatMap { URL(string: base + "?" + $0) }
    }

    // MARK: - when a search is blocked

    /// Engines a search that gave nothing is run again on, in this order:
    /// results pages with no script whose links carry their real targets.
    static let fallbacks: [(name: String, base: String)] = [("duckduckgo", "https://html.duckduckgo.com/html/"), ("bing", "https://www.bing.com/search")]
    /// Less text than this on a results page (the engine's own words only): no results in it.
    static let thin = 500
    static let unusable = "If results are unusable, open the official site's own URL directly"

    /// A search engine's results address: the engine and the words searched. Nil for any other page.
    static func searchQuery(_ url: URL) -> (engine: String, query: String)? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else { return nil }
        let labels = host.split(separator: "."), path = parts.path.count > 1 && parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        let engine: String
        if labels.contains("google"), path == "/search" { engine = "google" }
        else if labels.contains("bing"), path == "/search" { engine = "bing" }
        else if labels.contains("duckduckgo"), ["", "/", "/html", "/lite"].contains(path) { engine = "duckduckgo" }
        else { return nil }
        // A query's `+` is a space; `%2B` is the plus sign.
        guard let raw = parts.percentEncodedQueryItems?.first(where: { $0.name == "q" })?.value,
              let words = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
              !words.isEmpty else { return nil }
        return (engine, words)
    }

    /// Why a results page holds no results: a human check, an error page, or
    /// (`text`: its body is the page's text, at most `chars`) too few words. Nil: it has some.
    static func trouble(_ r: Result, text: Bool, chars: Int) -> String? {
        if r.status == .blocked || r.url.contains("/sorry/") { return "blocked" }
        if r.status == .error { return "failed" }
        let words = r.body.components(separatedBy: "\n\nLinks:").first ?? ""
        return text && r.status == .ok && words.count < min(thin, chars / 2) ? "gave no usable results" : nil
    }

    /// The engines to try after `engine` gave nothing, in order.
    static func chain(after engine: String) -> [(name: String, base: String)] {
        fallbacks.filter { $0.name != engine }
    }

    /// "search blocked on google and duckduckgo; results from bing. If results are unusable, …"
    static func label(_ why: String, on failed: [String], from engine: String) -> String {
        "search \(why) on \(failed.joined(separator: " and ")); results from \(engine). \(unusable)"
    }

    /// Results listed in a page's slot: title, real address, snippet.
    static func listing(_ hits: [Link]) -> String {
        hits.enumerated().map { n, hit in
            "\(n + 1). \(Tools.pageWords(hit.text)) \(hit.url)" + (hit.snippet.isEmpty ? "" : "\n   " + hit.snippet)
        }.joined(separator: "\n")
    }

    /// Reads results pages (`pages` with `results`; a fixture in tests).
    typealias Load = @MainActor ([URL]) async throws -> [Result]

    /// One query's results from a fallback engine; `failed`: the engines that gave none first.
    struct Rescued { var page: Result; var hits: [Link]; var engine: String; var failed: [String] }

    /// Each query (`from`: the engine that gave nothing) run again on the
    /// engines after it until one lists results (`load`: reads results pages). Nil: none did.
    @MainActor
    static func retry(_ queries: [String], from: [String], load: Load) async throws -> [Rescued?] {
        var out: [Rescued?] = queries.map { _ in nil }
        var failed = from.map { [$0] }
        for next in fallbacks {
            let now = queries.indices.filter { out[$0] == nil && chain(after: from[$0]).contains { $0.name == next.name } && engine(queries[$0], on: next.base) != nil }
            guard !now.isEmpty else { continue }
            let found = try await load(now.compactMap { engine(queries[$0], on: next.base) })
            for (i, page) in zip(now, found) {
                let got = hits(page.links, page: page.url.isEmpty ? page.asked : page.url, count: listed)
                if page.status == .ok, !got.isEmpty { out[i] = Rescued(page: page, hits: got, engine: next.name, failed: failed[i]) } else { failed[i].append(next.name) }
            }
        }
        return out
    }

    /// A read search page that holds no results (`trouble`): the same words
    /// on the next engine, and the next; the first that lists results takes its slot.
    @MainActor
    static func rescue(_ results: inout [Result], ask: Ask, load: Load) async throws {
        let stuck = results.indices.compactMap { i -> (slot: Int, engine: String, query: String, why: String)? in
            guard let url = URL(string: results[i].asked), let found = searchQuery(url),
                  let why = trouble(results[i], text: ask.want == nil, chars: ask.maxChars) else { return nil }
            return (i, found.engine, found.query, why)
        }
        guard !stuck.isEmpty else { return }
        let again = try await retry(stuck.map(\.query), from: stuck.map(\.engine), load: load)
        for (one, got) in zip(stuck, again) {
            guard let got else {
                let tried = chain(after: one.engine).map(\.name).joined(separator: ", ")
                results[one.slot].note += (results[one.slot].note.isEmpty ? "" : "; ") + "search \(one.why) on \(one.engine); no results from \(tried) either. \(unusable)"
                continue
            }
            results[one.slot] = Result(asked: results[one.slot].asked, url: got.page.url, title: got.page.title, status: .ok,
                                       body: listing(got.hits), note: label(one.why, on: got.failed, from: got.engine))
        }
    }

    /// One search round in one call: each query's results page gives its
    /// result links; the first `top` of each are read like `urls`, with them.
    @MainActor
    static func search(_ ask: Ask, keys: Intelligence.Keys, in browser: Browser, started: Date) async throws -> String {
        let engines = ask.search.compactMap { engine($0) }
        var found = try await pages(engines, ask: ask, keys: keys, in: browser, results: true)
        var lists = found.map { hits($0.links, page: $0.url.isEmpty ? $0.asked : $0.url, count: max(listed, ask.top)) }
        // A query its engine listed nothing for: the next engine's results.
        let empty = lists.indices.filter { lists[$0].isEmpty }
        if !empty.isEmpty {
            let again = try await retry(empty.map { ask.search[$0] }, from: empty.map { _ in fallbacks[0].name }) { try await pages($0, ask: ask, keys: keys, in: browser, results: true) }
            for (i, got) in zip(empty, again) {
                let why = found[i].status == .ok ? "gave no usable results" : "blocked"
                if let got {
                    found[i] = got.page
                    found[i].note = label(why, on: got.failed, from: got.engine)
                    lists[i] = got.hits
                } else if found[i].status != .ok {
                    found[i].note += "; no results from \(chain(after: fallbacks[0].name).map(\.name).joined(separator: ", ")) either. \(unusable)"
                }
            }
        }
        let read = try await pages(ask.urls + picked(lists, top: ask.top, room: most - ask.urls.count, skip: ask.urls), ask: ask, keys: keys, in: browser)
        let seconds = Date().timeIntervalSince(started)
        Tools.summary?.line = "search \(found.count) · read \(read.count) · \(read.filter { $0.status == .ok }.count) ok · " + String(format: "%.1f s", seconds)
        return searchFormat(ask.search, found: found, lists: lists, read: read, seconds: seconds)
    }

    /// A results page's first `count` results: each redirect seen through,
    /// once; none on the engine's own site (its other searches, its pages)
    /// or too long to be an address (an ad's tracking link).
    static func hits(_ links: [Link], page: String, count: Int) -> [Link] {
        // The engine's site: its last two labels (its redirects may sit on another of its hosts).
        func site(_ url: String) -> String { (URLComponents(string: url)?.host?.lowercased() ?? "").split(separator: ".").suffix(2).joined(separator: ".") }
        let engine = site(page)
        var seen = Set<String>(), out: [Link] = []
        for link in links where out.count < count {
            let url = site(link.url) == engine ? target(link.url, page: link.url) ?? link.url : link.url
            guard let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host?.isEmpty == false, site(url) != engine, url.count <= linkChars,
                  seen.insert(url).inserted else { continue }
            out.append(Link(text: link.text, url: url, snippet: snippet(link.snippet, title: link.text)))
        }
        return out
    }

    /// A result block's words without its title and its address line.
    static func snippet(_ text: String, title: String) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != title && !$0.contains("://") && !$0.contains(" › ") && ($0.contains(" ") || !$0.contains(".")) }
        return Tools.oneLine(lines.joined(separator: " "), limit: 200)
    }

    /// What to read: rank by rank across the searches (every search's first
    /// result before any second), up to `top` each, each page once, within `room`.
    static func picked(_ lists: [[Link]], top: Int, room: Int, skip: [URL] = []) -> [URL] {
        var out: [URL] = [], seen = Set(skip.map(\.absoluteString))
        for rank in 0..<top {
            for list in lists where rank < list.count && out.count < room {
                guard let url = URL(string: list[rank].url), seen.insert(list[rank].url).inserted else { continue }
                out.append(url)
            }
        }
        return out
    }

    /// Each search's results (a read one points at its page block), then the
    /// read pages as `format` shows them, all in one fence.
    static func searchFormat(_ queries: [String], found: [Result], lists: [[Link]], read: [Result], seconds: Double) -> String {
        var block: [String: Int] = [:]
        for (i, r) in read.enumerated() where block[r.asked] == nil { block[r.asked] = i + 1 }
        var lines: [String] = []
        for (i, query) in queries.enumerated() {
            let page = i < found.count ? found[i] : Result(asked: "", note: "not a query")
            var head = "search \(i + 1): " + Tools.pageWords(query)
            if i >= lists.count || lists[i].isEmpty {
                head += page.status == .ok ? " — no results found" : " — \(page.status.rawValue): \(page.note)"
            } else if !page.note.isEmpty {
                head += " — " + page.note
            }
            lines.append(head)
            for (n, hit) in (i < lists.count ? lists[i] : []).enumerated() {
                var line = "\(n + 1). \(Tools.pageWords(hit.text)) \(hit.url)"
                if let k = block[hit.url] { line += " → [\(k)]" }
                lines.append(hit.snippet.isEmpty ? line : line + "\n   " + hit.snippet)
            }
        }
        let s = queries.count == 1 ? "" : "es"
        let head = "browser_read: \(queries.count) search\(s), \(read.count) page\(read.count == 1 ? "" : "s") read in \(String(format: "%.1f", seconds)) s"
            + (read.isEmpty ? "" : " (\(counts(read)))") + "; tabs closed. A result without → [n] was not read: pass its URL in urls."
        return head + "\n" + Tools.fence((lines + blocks(read)).joined(separator: "\n"))
    }

    /// One page: wait until it is ready (or the cap), then read it.
    @MainActor
    private static func one(_ tab: Tab, asked: URL, ask: Ask, keys: Intelligence.Keys, started: Date, results: Bool = false) async -> Result {
        var result = Result(asked: asked.absoluteString)
        let web = tab.web
        var last: Probe?
        var loadedAt: Date?
        var checkSeen: Date?
        while true {
            if Task.isCancelled {
                result.note = "cancelled"
                return result
            }
            if let failure = tab.failure {
                result.url = tab.address?.absoluteString ?? ""
                result.note = "did not load: \(failure)"
                return result
            }
            let gen = Tools.gen(web)
            let probe = await look(web)
            if probe != nil { last = probe }
            let loading = web.isLoading
            if let probe, loaded(probe, loading: loading) { loadedAt = loadedAt ?? Date() } else { loadedAt = nil }
            let elapsed = Date().timeIntervalSince(started)
            let seen = verdict(probe, loading: loading, loadedFor: loadedAt.map { Date().timeIntervalSince($0) } ?? 0, elapsed: elapsed)
            if seen == .wait {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            result.url = last?.href ?? ""
            result.title = last?.title ?? ""
            // A navigation under way at the cap: the page there is the one being left.
            if seen == .timeout, !partial(last) || Tools.pending(web) {
                result.status = .timeout
                result.note = "still loading after \(Int(Arrival.cap)) s (\(last?.state ?? "nothing committed")); nothing read"
                return result
            }
            // Twice as many as shown: linkLines drops wrappers and this page's own variants.
            let read = await capture(web, cap: results ? defaultChars : ask.want == nil ? ask.maxChars : wantChars,
                                     main: ask.want == nil && !results, links: results ? 0 : ask.links * 2, results: results)
            let page: Capture
            switch taken(read, doc: last?.doc, elapsed: Date().timeIntervalSince(started), moved: !Tools.still(web, gen)) {
            case .again:
                loadedAt = nil
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            case .failed(let status, let note):
                result.status = status
                result.note = note
                return result
            case .page(let one): page = one
            }
            result.url = page.href
            result.title = page.title
            if let check = humanCheck(title: page.title, text: page.text) {
                // A challenge often clears itself and moves on: a short while, then it is reported.
                let since = checkSeen ?? Date()
                checkSeen = since
                if seen == .ready, waitOut(checking: Date().timeIntervalSince(since), elapsed: Date().timeIntervalSince(started)) {
                    loadedAt = nil
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                result.status = .blocked
                result.note = "a human check (\(check)); not clicked. Hand it to the user (browser_handoff) or use another source"
                result.body = String(page.text.prefix(ask.maxChars))
                return result
            }
            result.status = seen == .ready ? .ok : .timeout
            var notes = seen == .timeout ? ["partial: still loading after \(Int(Arrival.cap)) s"] : []
            if let http = httpError(Tools.nav(web).code(at: page.href)) {
                result.status = .error
                notes.append(http)
            }
            result.note = notes.joined(separator: "; ")
            if results {
                result.links = page.links
                return result
            }
            guard let want = ask.want, !page.text.isEmpty else {
                result.body = (page.text.isEmpty ? "(empty page: it has no text)" : page.text) + linkLines(page.links, page: page.href, most: ask.links)
                return result
            }
            do {
                result.body = try await values(want, url: result.url, title: result.title, text: page.text + linkLines(page.links, page: page.href, most: ask.links), keys: keys)
            } catch {
                result.extractFailed = true
                result.note = [result.note, "extract failed (\(error.localizedDescription.prefix(120))); text instead"].filter { !$0.isEmpty }.joined(separator: "; ")
                result.body = String(page.text.prefix(ask.maxChars))
            }
            return result
        }
    }

    /// Where the page stands, in one round trip; nil while it can't answer
    /// (between documents). A DOM watcher and the document's own mark go in
    /// with the first look at each document, so `quietMs` counts from its
    /// last change and `doc` tells it from the next one.
    @MainActor
    private static func look(_ web: WKWebView) async -> Probe? {
        let body = """
        if (!window.__copperReadQuiet) {
          const q = window.__copperReadQuiet = { t: performance.now(), id: Math.random().toString(36).slice(2) + ':' + performance.timeOrigin };
          try { new MutationObserver(() => { q.t = performance.now(); }).observe(document, { subtree: true, childList: true, characterData: true }); } catch (e) {}
        }
        const type = document.contentType || 'text/html';
        return { href: location.href, state: document.readyState, title: document.title || '',
                 html: /html|xml/.test(type), quiet: performance.now() - window.__copperReadQuiet.t, doc: window.__copperReadQuiet.id };
        """
        guard let said = try? await Page.call(web, body, timeout: 1, late: "", counted: true) as? [String: Any] else { return nil }
        return Probe(href: said["href"] as? String ?? "", state: said["state"] as? String ?? "",
                     title: said["title"] as? String ?? "", html: said["html"] as? Bool ?? true,
                     quietMs: (said["quiet"] as? NSNumber)?.doubleValue ?? 0, doc: said["doc"] as? String ?? "")
    }

    /// The page's address, title and readable text in one evaluation, with
    /// its document's mark; the text whitespace folded, at most `cap`
    /// characters: its main part when it has a real one (`main`), else the
    /// whole body, its head and its tail. With `links`, the first that many
    /// visible links of the main part (else of the body outside its nav,
    /// header and footer), one per address. Nil when the page didn't answer.
    @MainActor
    static func capture(_ web: WKWebView, cap: Int, main: Bool, links: Int = 0, results: Bool = false) async -> Capture? {
        let body = """
        const fold = (s) => (s || '').replace(/[ \\t\\u00a0]+/g, ' ').replace(/ ?\\n[\\s]*/g, '\\n').trim();
        const all = fold(document.body ? document.body.innerText : (document.documentElement || {}).textContent);
        // The page's main part: <main> or role=main; an <article> only when it is the only one (a list of them is the page).
        const articles = document.querySelectorAll('article');
        const m = document.querySelector('main, [role=main]') || (articles.length === 1 ? articles[0] : null);
        const part = m ? fold(m.innerText) : '';
        let t = main && part.length >= 500 ? part : all;
        if (t.length > cap) {
          // For values, the end too: key facts often sit after a long main text.
          t = main ? t.slice(0, cap) + ' …' : t.slice(0, Math.floor(cap * 2 / 3)) + '\\n…\\n' + t.slice(-Math.floor(cap / 3));
        }
        const found = [], seen = new Set([location.href.split('#')[0]]);
        for (const a of links > 0 ? (m || document.body || document).querySelectorAll('a[href]') : []) {
          if (found.length >= links) break;
          if (!m && a.closest('nav, header, footer, [role=navigation], [role=banner], [role=contentinfo]')) continue;
          const url = a.href, words = fold(a.innerText || a.getAttribute('aria-label') || '').split('\\n')[0];
          if (!/^https?:/.test(url) || url.length > 600 || !words || seen.has(url.split('#')[0]) || !a.getClientRects().length) continue;
          seen.add(url.split('#')[0]);
          found.push([words.slice(0, 80), url]);
        }
        // A results page's results (`results`): links titled by a heading, each
        // with the largest block around it that holds no other; an ad's block says so first.
        if (results) {
          const heads = 'a[href] h1, a[href] h2, a[href] h3, h1 a[href], h2 a[href], h3 a[href]';
          for (const h of document.querySelectorAll('h1, h2, h3')) {
            const a = h.closest('a[href]') || h.querySelector('a[href]');
            if (!a || !/^https?:/.test(a.href) || seen.has(a.href)) continue;
            seen.add(a.href);
            let box = a;
            while (box.parentElement && box.parentElement !== document.body && box.parentElement.querySelectorAll(heads).length <= 1) box = box.parentElement;
            const block = fold(box.innerText).slice(0, 600);
            if (/^(sponsored|ads?)\\b/i.test(block)) continue;
            found.push([fold(h.innerText).split('\\n')[0].slice(0, 120), a.href, block]);
            if (found.length >= 20) break;
          }
        }
        const q = window.__copperReadQuiet;
        return { doc: q ? q.id : '', href: location.href, title: document.title || '', text: t, links: found };
        """
        guard let said = try? await Page.call(web, body, ["cap": cap, "main": main, "links": links, "results": results], timeout: 3, late: "") as? [String: Any],
              let text = said["text"] as? String else { return nil }
        let found = (said["links"] as? [[String]] ?? []).compactMap { $0.count >= 2 ? Link(text: $0[0], url: $0[1], snippet: $0.count > 2 ? $0[2] : "") : nil }
        return Capture(doc: said["doc"] as? String ?? "", href: said["href"] as? String ?? "", title: said["title"] as? String ?? "", text: text, links: found)
    }

    /// The asked values, as jev_extract asks for them, in one line of JSON.
    @MainActor
    private static func values(_ want: String, url: String, title: String, text: String, keys: Intelligence.Keys) async throws -> String {
        let user: [String: Any] = ["instruction": want, "page": ["url": url, "title": title, "text": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: user, options: [.sortedKeys]) else { throw Failure(text: "couldn't encode the page") }
        let reply = try await Ultrafast.askReader(system: Ultrafast.extractValue, user: String(decoding: data, as: UTF8.self), keys: keys,
                                                  timeout: 30, maxTokens: Ultrafast.readTokens, json: true, cheap: true)
        guard !reply.json.isEmpty, let out = try? JSONSerialization.data(withJSONObject: reply.json, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            throw Failure(text: "the model answered without JSON")
        }
        return String(decoding: out, as: UTF8.self)
    }
}
}
