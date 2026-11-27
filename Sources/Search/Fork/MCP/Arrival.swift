import Foundation
import WebKit

// Fork (ready-pages): a navigation answers when the new page is there.
//
// browser_navigate used to come back at the new document's DOMContentLoaded,
// often before it had a title, so agents added waits of their own — and a
// read sent a moment too early landed on the page being left. Now a
// navigation (navigate, back, forward, a click or key that leaves the page)
// answers once the new document has committed, finished loading, has a title
// and has been still for a beat; at 12 s it answers "still loading". A read
// on a tab whose navigation has not committed yet waits for it first.

enum Arrival {
    /// What the page looks like at one poll.
    struct Look: Equatable {
        /// A new document committed (or the navigation failed) since it began.
        var landed: Bool
        /// It landed as a failure (no connection, refused, dropped): nothing more is coming.
        var failed = false
        /// WebKit still loading the main frame.
        var loading: Bool
        /// `document.readyState`, "" when the page could not answer.
        var state: String
        var title: String
        /// Seconds since the address, title, state or loading last changed.
        var still: TimeInterval
        /// Seconds since the navigation began.
        var elapsed: TimeInterval
    }

    enum Verdict: Equatable { case wait, ready, late }

    static let cap: TimeInterval = 12
    /// A titled page that has stopped changing for this long is there.
    static let calm: TimeInterval = 0.25
    /// A page that never names itself (JSON, plain text, an image) is there
    /// once it has finished and kept still for this long.
    static let untitled: TimeInterval = 1
    /// Nothing loading and nothing landed this long after the ask: no
    /// navigation is coming (a download, another app's link, a refused one).
    static let none: TimeInterval = 1

    /// The words for a load that failed: what failed, and that nothing of it can be read.
    static func unloaded(_ failure: String, asked: String?) -> String {
        "The page did not load" + (asked.map { " (\($0))" } ?? "") + ": \(failure) Nothing from it can be read; this tab still holds whatever was there before. Navigate again or use another address."
    }

    /// The words for a navigation that has not committed yet: the tab still
    /// holds the page before it, under the new address, so nothing is read.
    static func uncommitted(_ asked: String?) -> String {
        "The page" + (asked.map { " (\($0))" } ?? "") + " has not arrived: the site has not answered yet, and this tab still holds the page before it. Nothing was read; call again in a moment or use another address."
    }

    static func verdict(_ look: Look, cap: TimeInterval = cap) -> Verdict {
        if look.elapsed >= cap { return .late }
        guard look.landed else { return !look.loading && look.elapsed >= none ? .ready : .wait }
        if look.failed { return .ready }
        guard look.state == "complete", !look.loading else { return .wait }
        return look.still >= (look.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? untitled : calm) ? .ready : .wait
    }
}

extension Tools {
    /// Per page view: when the main frame last asked for a new document, and
    /// when one last committed or failed (Browser's navigation delegate).
    final class Nav {
        var asks = 0
        var asked = Date.distantPast
        /// `asked` before the latest ask, for when that ask is cancelled (Tools.unasked).
        var askedBefore = Date.distantPast
        var landed = Date.distantPast
        /// Bumped when a main-frame navigation starts and when one lands: a
        /// read or an input captures it first and is stale if it moved since.
        private(set) var gen = 0
        /// The last main-frame HTTP answer: its status and address (Browser's response policy).
        var status: Int?
        var statusURL: URL?

        /// A new ask for a document: its time, which a cancel later names (unask).
        func ask(at now: Date = Date()) -> Date {
            asks += 1
            gen += 1
            askedBefore = asked
            asked = now
            return now
        }

        /// The ask made `at` was cancelled (a policy said no): as if never asked. Once only,
        /// and only while it is the latest — a late answer never takes back a newer ask.
        func unask(_ at: Date) {
            guard asked == at, asked > askedBefore else { return }
            asks = max(0, asks - 1)
            asked = askedBefore
            askedBefore = asked
        }

        /// A document (or a failure) landed.
        func land(at now: Date = Date()) {
            gen += 1
            landed = now
        }

        /// Nothing started or landed since `gen` was taken, and nothing is under way.
        func still(_ gen: Int, loading: Bool) -> Bool { self.gen == gen && !uncommitted(loading: loading) }

        /// Asked for a document that has neither committed nor failed yet.
        func uncommitted(loading: Bool) -> Bool { loading && asked > landed }
        /// Some document (or a failure) has landed in this view.
        var committed: Bool { landed != .distantPast }

        /// The status the page at `href` came with; nil when the last answer was for another address.
        func code(at href: String) -> Int? {
            func bare(_ s: String) -> Substring { s.prefix { $0 != "#" } }
            guard let statusURL, bare(statusURL.absoluteString) == bare(href) else { return nil }
            return status
        }
    }
    @MainActor private static let navs = NSMapTable<WKWebView, Nav>.weakToStrongObjects()

    @MainActor static func nav(_ web: WKWebView) -> Nav {
        if let nav = navs.object(forKey: web) { return nav }
        let nav = Nav()
        navs.setObject(nav, forKey: web)
        return nav
    }

    /// Browser didCommit / a failed load: the navigation has an outcome.
    @MainActor static func landed(_ web: WKWebView) { nav(web).land() }

    /// The tab's navigation generation now (Nav.gen).
    @MainActor static func gen(_ web: WKWebView) -> Int { nav(web).gen }

    /// No navigation started or landed since `gen`, and none is under way.
    @MainActor static func still(_ web: WKWebView, _ gen: Int) -> Bool { nav(web).still(gen, loading: web.isLoading) }

    /// Browser's response policy: the main frame's HTTP answer, for browser_read's status.
    @MainActor static func responded(_ web: WKWebView, _ response: URLResponse) {
        let nav = nav(web)
        nav.status = (response as? HTTPURLResponse)?.statusCode
        nav.statusURL = response.url
    }

    /// The main frame asked for a document that has not committed yet.
    @MainActor static func pending(_ web: WKWebView) -> Bool {
        nav(web).uncommitted(loading: web.isLoading)
    }

    /// Wait until the navigation begun at `began` (`.distantPast`: whichever
    /// the page asked for last) has brought its page (Arrival.verdict).
    /// False when the cap came first.
    @MainActor
    static func arrive(_ tab: Tab, since began: Date, cap: TimeInterval = Arrival.cap) async -> Bool {
        let start = Date()
        defer { phases?.add("arrive", since: start) }
        let web = tab.web
        var seen = ""
        var changed = Date()
        while true {
            // Short timeout: a document being torn down answers nothing.
            let state = (try? await Page.call(web, "return document.readyState", timeout: 0.5, late: "", counted: false)) as? String ?? ""
            let now = "\(web.url?.absoluteString ?? "")|\(tab.title)|\(state)|\(web.isLoading)"
            if now != seen { seen = now; changed = Date() }
            // Landed after the navigation began and after its latest ask (a
            // redirect the page made once it had committed counts as more of it).
            let nav = nav(web)
            let look = Arrival.Look(landed: nav.landed > max(began, nav.asked), failed: tab.failure != nil, loading: web.isLoading, state: state,
                                    title: tab.title, still: Date().timeIntervalSince(changed), elapsed: Date().timeIntervalSince(start))
            switch Arrival.verdict(look, cap: cap) {
            case .ready: return true
            case .late: return false
            case .wait: try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// A navigation's answer: the page, and a plain word when it is not all there.
    @MainActor
    static func arrivedLine(_ tab: Tab, _ arrived: Bool) -> String {
        var line = pageLine(tab)
        if let failure = tab.failure { line += "\n- The page did not load: \(failure)" }
        if let web = tab.built, pending(web) { line += "\n- Not arrived after \(Int(Arrival.cap)) s: the site has not answered, so this tab still holds the page before; reads are refused until it arrives." }
        else if !arrived { line += "\n- Still loading after \(Int(Arrival.cap)) s: what you read may be incomplete." }
        return line
    }

    /// browser_navigate/back/forward: a load that failed is an error, not a
    /// page — WebKit keeps the page before it, and answering with that one
    /// (as if the load had worked) led the next read onto the wrong page.
    @MainActor
    static func arrivedAnswer(_ tab: Tab, _ arrived: Bool, asked: URL? = nil) throws -> [Content] {
        if let failure = tab.failure { throw Failure(text: Arrival.unloaded(failure, asked: asked?.absoluteString)) }
        return [.text(arrivedLine(tab, arrived))]
    }

    /// Jev's reads and acts stand on a committed page: a navigation not
    /// committed yet is waited for (to `cap`); one that still hasn't, or a
    /// load that failed, is refused (readable) — never the document being left.
    @MainActor
    static func committed(_ tab: Tab, cap: TimeInterval = Arrival.cap) async throws {
        if let web = tab.built, pending(web) {
            let until = Date().addingTimeInterval(cap)
            while pending(web), Date() < until { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        try readable(tab)
    }

    /// A read on a tab whose last load failed, or whose navigation has not
    /// committed yet (arrive ran out first): refused, so it never returns the
    /// page that was there before under the new address.
    @MainActor
    static func readable(_ tab: Tab) throws {
        if let failure = tab.failure { throw Failure(text: Arrival.unloaded(failure, asked: nil)) }
        if let web = tab.built, pending(web) { throw Failure(text: Arrival.uncommitted(web.url?.absoluteString)) }
    }
}
