import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

// browser_read's pure parts: what it accepts, when a page counts as ready
// (or timed out), what counts as a human check, and how the answer reads.

private typealias Read = Tools.Read

@MainActor @Test func readTakesOneToTwelveWebAddresses() throws {
    let ask = try Read.parse(["urls": ["https://example.com/docs/widget/", "example.org/item/42"], "want": "  license  "])
    #expect(ask.urls.map(\.absoluteString) == ["https://example.com/docs/widget/", "https://example.org/item/42"])
    #expect(ask.want == "license")
    #expect(ask.maxChars == Read.defaultChars)
    // One address as a bare string is taken too.
    #expect(try Read.parse(["urls": "https://example.com"]).urls.count == 1)
    // max_chars is clamped, and an empty want means text.
    #expect(try Read.parse(["urls": ["https://a.com"], "max_chars": 5]).maxChars == Read.charRange.lowerBound)
    #expect(try Read.parse(["urls": ["https://a.com"], "max_chars": 1e8]).maxChars == Read.charRange.upperBound)
    #expect(try Read.parse(["urls": ["https://a.com"], "want": " "]).want == nil)

    for bad: [String: Any] in [
        [:], ["urls": []], ["urls": Array(repeating: "https://a.com", count: 13)],
        ["urls": ["hello world"]], ["urls": ["about:blank"]], ["urls": ["copper://canvas"]], ["urls": [42]],
        ["urls": ["https://a.com"], "max_chars": "lots"],
        ["search": []], ["search": ["  "]], ["search": ["a", "b", "c", "d", "e"]], ["search": [42]], ["search": ["a"], "top": "many"],
    ] {
        #expect(throws: Tools.Failure.self, "\(bad)") { try Read.parse(bad) }
    }
}

@Test func aPageIsReadyOnlyWhenItsOwnDocumentHasLoadedAndGoneQuiet() {
    let good = Read.Probe(href: "https://example.com/x/", state: "complete", title: "x · Example", html: true, quietMs: 500)
    #expect(Read.verdict(good, loading: false, loadedFor: 0.5, elapsed: 1) == .ready)
    // The fresh tab's blank page, a load still running, no title yet: not yet.
    var blank = good; blank.href = "about:blank"
    var interactive = good; interactive.state = "interactive"
    var untitled = good; untitled.title = "  "
    for p in [blank, interactive, untitled] { #expect(Read.verdict(p, loading: false, loadedFor: 0, elapsed: 1) == .wait) }
    #expect(Read.verdict(good, loading: true, loadedFor: 0, elapsed: 1) == .wait) // a client redirect under way
    #expect(Read.verdict(nil, loading: true, loadedFor: 0, elapsed: 1) == .wait)
    // JSON and plain text have no title to wait for.
    var json = untitled; json.html = false
    #expect(Read.verdict(json, loading: false, loadedFor: 0.5, elapsed: 1) == .ready)
    // An HTML page that never names itself is read once it has kept still Arrival.untitled, not at the cap.
    var still = untitled; still.quietMs = Arrival.untitled * 1000
    #expect(Read.verdict(still, loading: false, loadedFor: 0, elapsed: 1.5) == .ready)
    still.state = "interactive"
    #expect(Read.verdict(still, loading: false, loadedFor: 0, elapsed: 1.5) == .wait)
    // Loaded but still changing: waits for quiet, but not past `restless`.
    var busy = good; busy.quietMs = 50
    #expect(Read.verdict(busy, loading: false, loadedFor: 1, elapsed: 2) == .wait)
    #expect(Read.verdict(busy, loading: false, loadedFor: Read.restless, elapsed: 4) == .ready)
}

@Test func aPageThatNeverLoadsTimesOutAtTheCap() {
    let slow = Read.Probe(href: "https://slow.example/", state: "interactive", title: "Slow", html: true, quietMs: 0)
    #expect(Read.verdict(slow, loading: true, loadedFor: 0, elapsed: Arrival.cap - 0.1) == .wait)
    #expect(Read.verdict(slow, loading: true, loadedFor: 0, elapsed: Arrival.cap) == .timeout)
    #expect(Read.verdict(nil, loading: true, loadedFor: 0, elapsed: Arrival.cap + 1) == .timeout)
    // At the cap its own document, past "loading", is read in part; the blank page never is.
    #expect(Read.partial(slow))
    var loading = slow; loading.state = "loading"
    var blank = slow; blank.href = "about:blank"
    #expect(!Read.partial(loading) && !Read.partial(blank) && !Read.partial(nil))
}

@Test func readSpotsHumanChecksButNotArticlesAboutThem() {
    #expect(Read.humanCheck(title: "Just a moment...", text: "Verifying you are human. This may take a few seconds.") != nil)
    #expect(Read.humanCheck(title: "Client Challenge", text: "") != nil)
    #expect(Read.humanCheck(title: "shop.example", text: "Please verify you are human. Press & hold") != nil)
    let article = String(repeating: "Garden tools compared. ", count: 80) + "Some sites show a CAPTCHA at login."
    #expect(Read.humanCheck(title: "Garden tools reviewed", text: article) == nil)
    #expect(Read.humanCheck(title: "widget · Example", text: "widget 1.0.0 License: MIT") == nil)
}

@Test func readAnswersOneFencedBlockPerPageInOrder() {
    let results = [
        Read.Result(asked: "https://example.com/widget/", url: "https://example.com/widget/", title: "widget · Example",
                    status: .ok, body: #"{"license":"MIT","version":"1.0.0"}"#),
        Read.Result(asked: "http://a.com", url: "https://www.a.com/", title: "A", status: .ok, body: "Hello"),
        Read.Result(asked: "https://slow.example/", status: .timeout, note: "still loading after 12 s (loading); nothing read"),
        Read.Result(asked: "https://shop.example/", url: "https://shop.example/", title: "Just a moment...", status: .blocked, note: "a human check (just a moment); not clicked"),
    ]
    let out = Read.format(results, seconds: 4.23)
    #expect(out.hasPrefix("browser_read: 4 pages in 4.2 s (2 ok, 1 timeout, 1 blocked); tabs closed.\n[page content "))
    #expect(out.contains("[1] ok · https://example.com/widget/ · \"widget · Example\"\n{\"license\":\"MIT\",\"version\":\"1.0.0\"}"))
    #expect(out.contains("[2] ok · http://a.com → https://www.a.com/ · \"A\"\nHello"))
    #expect(out.contains("[3] timeout · https://slow.example/ — still loading after 12 s"))
    #expect(out.contains("[4] blocked · https://shop.example/ · \"Just a moment...\" — a human check"))
    #expect(out.hasSuffix("]"))
    #expect(out.components(separatedBy: "[1]").count == 2)
}

@MainActor @Test func readIsListedWithItsOwnTabsAndNoTabArgument() throws {
    let listed = Tools.offered(jev: true, canvas: false)
    let tool = try #require(listed.first { $0["name"] as? String == Read.name })
    let props = try #require((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
    #expect(props["tab"] == nil && props["urls"] != nil && props["want"] != nil)
    #expect(Tools.offered(jev: false, canvas: false).contains { $0["name"] as? String == Read.name })
    #expect(AgentTabs.opensBehind(Read.name, [:]))
}

@Test func readTakesTextOnlyFromTheDocumentItFoundReady() {
    let page = Read.Capture(doc: "d1", href: "https://example.com/a", title: "A", text: "Hello")
    #expect(Read.taken(page, doc: "d1", elapsed: 1) == .page(page))
    // A redirect between the ready look and the read: the next document is waited out, not read under the old address.
    var next = page; next.doc = "d2"; next.href = "https://example.com/b"
    #expect(Read.taken(next, doc: "d1", elapsed: 1) == .again)
    #expect(Read.taken(page, doc: nil, elapsed: 1) == .again)
    #expect(Read.taken(page, doc: "", elapsed: 1) == .again)
    // A read the page didn't answer is never empty text marked ok.
    #expect(Read.taken(nil, doc: "d1", elapsed: 1) == .again)
    guard case .failed(.timeout, _) = Read.taken(nil, doc: "d1", elapsed: Arrival.cap) else { Issue.record("no answer at the cap"); return }
    guard case .failed(.timeout, _) = Read.taken(next, doc: "d1", elapsed: Arrival.cap + 1) else { Issue.record("changed at the cap"); return }
    // A genuinely empty document is a page.
    var empty = page; empty.text = ""
    #expect(Read.taken(empty, doc: "d1", elapsed: 1) == .page(empty))
    // A redirect that started (or committed) between the probe and the read keeps the doc id until commit:
    // waited out, and at the cap a timeout — never the leaving page's text.
    #expect(Read.taken(page, doc: "d1", elapsed: 1, moved: true) == .again)
    guard case .failed(.timeout, _) = Read.taken(page, doc: "d1", elapsed: Arrival.cap, moved: true) else { Issue.record("moving at the cap"); return }
}

@Test func readReportsAHumanCheckWithinItsGraceNotAtTheCap() {
    #expect(Tools.Ultrafast.humanCheckGrace <= 4)
    #expect(Read.waitOut(checking: 0, elapsed: 1))
    #expect(Read.waitOut(checking: Tools.Ultrafast.humanCheckGrace - 0.1, elapsed: 2))
    #expect(!Read.waitOut(checking: Tools.Ultrafast.humanCheckGrace, elapsed: 2))
    #expect(!Read.waitOut(checking: 0.5, elapsed: Arrival.cap))
}

@Test func readCallsAnHTTPErrorPageAnError() {
    #expect(Read.httpError(nil) == nil)
    #expect(Read.httpError(200) == nil && Read.httpError(304) == nil)
    #expect(Read.httpError(404)?.hasPrefix("HTTP 404") == true)
    #expect(Read.httpError(500)?.hasPrefix("HTTP 500") == true)
    let nav = Tools.Nav()
    nav.status = 404
    nav.statusURL = URL(string: "https://example.com/missing")
    #expect(nav.code(at: "https://example.com/missing#top") == 404)
    #expect(nav.code(at: "https://example.com/other") == nil)
}

@Test func readTabsNeverDownloadOrOpenAnotherApp() {
    for scheme in ["http", "https", "about", "data", "blob"] { #expect(Read.refusal(scheme: scheme, download: false) == nil, "\(scheme)") }
    for scheme in ["mailto", "tel", "zoommtg", "file", "copper", "itms-apps"] { #expect(Read.refusal(scheme: scheme, download: false) != nil, "\(scheme)") }
    #expect(Read.refusal(scheme: "https", download: true) != nil)
    // A web address Copper itself acts on (a canvas join, an extension's sign-in answer) is not followed.
    #expect(Read.refusal(scheme: "https", download: false, native: true) != nil)
}

@MainActor @Test func aClosedReadTabIsNotOnTheReopenList() {
    let tab = Tab()
    #expect(Browser.reopens(tab))
    tab.readOnly = true
    #expect(!Browser.reopens(tab))
}

@Test func readCountsFailedExtractionsInItsHeader() {
    var failed = Read.Result(asked: "https://a.example/", url: "https://a.example/", title: "A", status: .ok, body: "text", note: "extract failed (x); text instead")
    failed.extractFailed = true
    let out = Read.format([failed, Read.Result(asked: "https://b.example/", url: "https://b.example/", title: "B", status: .ok, body: "{}")], seconds: 1)
    #expect(out.hasPrefix("browser_read: 2 pages in 1.0 s (2 ok; 1 extract failed, text instead); tabs closed."))
    #expect(!Read.format([failed].map { var r = $0; r.extractFailed = false; return r }, seconds: 1).contains("extract failed,"))
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
}

@MainActor private var kept: [AnyObject] = []

@MainActor private func page(_ html: String) async -> WKWebView {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    window.orderBack(nil)
    let loaded = Loaded()
    web.navigationDelegate = loaded
    await withCheckedContinuation { c in loaded.done = c; web.loadHTMLString(html, baseURL: URL(string: "https://read.test/")) }
    kept += [window, loaded]
    return web
}

@MainActor @Test func textModeReadsMainNotTheFirstOfManyArticles() async throws {
    let words = String(repeating: "word ", count: 150)
    func text(_ body: String) async throws -> String {
        let web = await page("<html><head><title>T</title></head><body>\(body)</body></html>")
        return try #require(await Read.capture(web, cap: 20_000, main: true)).text
    }
    // A list of articles before <main>: the main part, not the first card.
    var got = try await text("<article>card one \(words)</article><article>card two \(words)</article><main>the main part \(words)</main>")
    #expect(got.hasPrefix("the main part") && !got.contains("card one"))
    got = try await text("<nav>menu</nav><div role=main>role main \(words)</div><article>side \(words)</article>")
    #expect(got.hasPrefix("role main") && !got.contains("side"))
    // One article and no main: that article.
    got = try await text("<nav>menu</nav><article>the one article \(words)</article><footer>foot</footer>")
    #expect(got.hasPrefix("the one article") && !got.contains("menu"))
    // Many articles, no main: the whole page, every card.
    got = try await text("<nav>menu</nav><article>card one \(words)</article><article>card two \(words)</article>")
    #expect(got.contains("menu") && got.contains("card one") && got.contains("card two"))
}

@Test func theExtractModelSeesAShortPage() {
    #expect(Read.wantChars <= 10_000)
}

@Test func readQueuesForAFullPoolThenReportsTimeouts() throws {
    let urls = [URL(string: "https://example.com/a")!, URL(string: "https://example.com/b")!]
    // Parallel calls (several planner sessions) queue well past a page's own cap.
    #expect(Read.poolWait >= 60 && Read.poolWait > Arrival.cap)
    #expect(Read.poolFull(waited: Arrival.cap, urls: urls) == nil)
    #expect(Read.poolFull(waited: Read.poolWait - 0.1, urls: urls) == nil)
    let said = Read.format(try #require(Read.poolFull(waited: Read.poolWait, urls: urls)), seconds: Read.poolWait)
    #expect(said.hasPrefix("browser_read: 2 pages in 60.0 s (2 timeout)") && said.contains("free read tab"))
}

@Test func readCallsTakeTheirTurnForReadTabs() {
    let a = UUID(), b = UUID()
    #expect(Read.admitted(a, line: [a, b], inUse: 0, count: Read.most))
    #expect(!Read.admitted(a, line: [a, b], inUse: 1, count: Read.most))
    // A small call behind a waiting big one waits too: the big one is not starved.
    #expect(!Read.admitted(b, line: [a, b], inUse: 0, count: 1))
    #expect(Read.admitted(b, line: [b], inUse: Read.most - 1, count: 1))
}

// hg3/fastread: a page's links come with its text, the cheap reader thinks little.

@MainActor @Test func readGivesAPagesMainLinksWithItsText() async throws {
    let words = String(repeating: "word ", count: 150)
    let web = await page("""
    <html><head><title>T</title></head><body>
    <nav><a href="https://read.test/menu">Menu</a></nav>
    <main>Results \(words)
      <a href="https://site.example/one">First result</a>
      <a href="https://site.example/one#top">First again</a>
      <a href="https://site.example/two" style="display:none">Hidden</a>
      <a href="javascript:void(0)">Script</a>
      <a href="/url?q=https%3A%2F%2Fother.example%2Fdeep%3Fa%3D1&sa=U">Wrapped</a>
      <a href="https://site.example/three"><div>Third</div><div>sub line</div></a>
    </main><footer><a href="https://read.test/terms">Terms</a></footer></body></html>
    """)
    let seen = try #require(await Read.capture(web, cap: 300, main: true, links: Read.links))
    #expect(seen.text.hasPrefix("Results word") && seen.text.hasSuffix(" …"))
    #expect(seen.links.map(\.text) == ["First result", "Wrapped", "Third"])
    #expect(try #require(await Read.capture(web, cap: 300, main: true)).links.isEmpty)
    // The want path reads the whole body but still gets the main part's links.
    let whole = try #require(await Read.capture(web, cap: 20_000, main: false, links: Read.links))
    #expect(whole.text.contains("Menu") && whole.links.count == 3)
    // No main part: the body's links, outside its nav and footer.
    let plain = await page("<html><head><title>P</title></head><body><header><a href='https://read.test/home'>Home</a></header><p>Hi <a href='https://site.example/x'>X page</a></p><footer><a href='https://read.test/t'>T</a></footer></body></html>")
    #expect(try #require(await Read.capture(plain, cap: 300, main: true, links: 20)).links.map(\.url) == ["https://site.example/x"])

    let block = Read.linkLines(seen.links, page: seen.href)
    #expect(block == "\n\nLinks:\n- [First result](https://site.example/one)\n- [Wrapped](https://read.test/url?q=https%3A%2F%2Fother.example%2Fdeep%3Fa%3D1&sa=U) → https://other.example/deep?a=1\n- [Third](https://site.example/three)")
    #expect(Read.linkLines([], page: seen.href).isEmpty)
}

@Test func aRedirectThroughThePagesOwnSiteIsHintedNeverReplaced() {
    let page = "https://search.example/search?q=widgets"
    #expect(Read.target("https://search.example/url?q=https%3A%2F%2Fshop.example%2Fw&sa=U", page: page) == "https://shop.example/w")
    #expect(Read.target("https://search.example/l/?uddg=http%3A%2F%2Fa.example%2F", page: page) == "http://a.example/")
    // The address base64url-encoded, behind a two-letter tag or not.
    #expect(Read.target("https://search.example/ck/a?p=9f3e&u=a1aHR0cHM6Ly9zaG9wLmV4YW1wbGUvdy9pdGVtP2lkPTc", page: page) == "https://shop.example/w/item?id=7")
    #expect(Read.target("https://search.example/r?to=aHR0cHM6Ly9zaG9wLmV4YW1wbGUvdy9pdGVtP2lkPTc", page: page) == "https://shop.example/w/item?id=7")
    // Not a redirect: another search, a link back to the same site, another site's share link, a plain link,
    // a page of the site's own that names two other sites (no one place it goes).
    #expect(Read.target("https://search.example/search?q=more+widgets", page: page) == nil)
    #expect(Read.target("https://search.example/login?next=https%3A%2F%2Fsearch.example%2Fme", page: page) == nil)
    #expect(Read.target("https://social.example/share?u=https%3A%2F%2Fshop.example%2F", page: page) == nil)
    #expect(Read.target("https://shop.example/w?ref=x", page: page) == nil)
    #expect(Read.target("https://search.example/compare?left=https://a.example&right=https://b.example", page: page) == nil)
    // The block lists every link at its real address; a destination is only a hint after it
    // (a login or consent page on the way is never skipped).
    let gated = [Read.Link(text: "Compare", url: "https://search.example/compare?left=https://a.example&right=https://b.example"),
                 Read.Link(text: "Sign in", url: "https://search.example/login?continue=https://shop.example/cart")]
    #expect(Read.linkLines(gated, page: page) == "\n\nLinks:\n- [Compare](https://search.example/compare?left=https://a.example&right=https://b.example)\n- [Sign in](https://search.example/login?continue=https://shop.example/cart) → https://shop.example/cart")
    // One address twice: listed once, the first one as it is.
    let twice = [Read.Link(text: "A", url: "https://shop.example/w"), Read.Link(text: "A again", url: "https://shop.example/w#top")]
    #expect(Read.linkLines(twice, page: page) == "\n\nLinks:\n- [A](https://shop.example/w)")
    // Two addresses on the way to one place (a share, a sign-in): both listed, each with its hint.
    let toCart = [Read.Link(text: "Share", url: "https://search.example/share?u=https://shop.example/cart"),
                  Read.Link(text: "Sign in", url: "https://search.example/login?continue=https://shop.example/cart")]
    #expect(Read.linkLines(toCart, page: page) == "\n\nLinks:\n- [Share](https://search.example/share?u=https://shop.example/cart) → https://shop.example/cart\n- [Sign in](https://search.example/login?continue=https://shop.example/cart) → https://shop.example/cart")
    // Not listed: this page with more parameters (filters, pages), an opaque wrapper too long to be an address to read.
    let noise = [Read.Link(text: "Next", url: "https://search.example/search?q=widgets&page=2"),
                 Read.Link(text: "Sorted", url: "https://search.example/search?sort=new&q=widgets"),
                 Read.Link(text: "Opaque", url: "https://search.example/goto?url=" + String(repeating: "Zx9", count: 70)),
                 Read.Link(text: "Kept", url: "https://search.example/help")]
    #expect(Read.linkLines(noise, page: page) == "\n\nLinks:\n- [Kept](https://search.example/help)")
    // At most Read.links lines.
    let many = (0..<50).map { Read.Link(text: "L\($0)", url: "https://a.example/\($0)") }
    #expect(Read.linkLines(many, page: page).components(separatedBy: "\n- ").count == Read.links + 1)
}

@Test func aSiteThatRoutesByQueryKeepsItsOtherPages() {
    let page = "https://video.example/watch?v=abc"
    let links = [Read.Link(text: "Other video", url: "https://video.example/watch?v=xyz"),
                 Read.Link(text: "Same, later", url: "https://video.example/watch?v=abc&t=60"),
                 Read.Link(text: "Item 7", url: "https://video.example/watch?id=7")]
    #expect(Read.linkLines(links, page: page) == "\n\nLinks:\n- [Other video](https://video.example/watch?v=xyz)\n- [Item 7](https://video.example/watch?id=7)")
    // A page without parameters: any of its own with parameters is a variant.
    #expect(Read.variant(URLComponents(string: "https://a.example/list?page=2"), of: URLComponents(string: "https://a.example/list")))
    #expect(!Read.variant(URLComponents(string: "https://a.example/other?page=2"), of: URLComponents(string: "https://a.example/list")))
}

@Test func onlyTheCheapReaderIsAskedToThinkLess() {
    #expect(Tools.Ultrafast.effort(Tools.Ultrafast.readModel, cheap: true) == "low")
    #expect(Tools.Ultrafast.effort("haiku", cheap: true) == nil)
    #expect(Tools.Ultrafast.effort(Tools.Ultrafast.readModel, cheap: false) == nil)
    #expect(Router.body(model: "luna", maxTokens: 1, messages: [], effort: "low")["reasoning_effort"] as? String == "low")
    #expect(Router.body(model: "luna", maxTokens: 1, messages: [])["reasoning_effort"] == nil)
}

@MainActor @Test func toolsListIsNoBiggerThanTheParents() throws {
    // hg/route (80813ef) listed 25,492 bytes with no canvas (as PageToolsTests counts them).
    let extra = [CloudHistoryTool.schema] + VoiceTools.catalogue
    let bytes = try JSONSerialization.data(withJSONObject: Tools.listed(Tools.offered(jev: true, canvas: false) + extra)).count
    // hg3/search: + 600 for browser_read's search.
    #expect(bytes <= 25_492 + 600, "tools/list with no canvas is \(bytes) bytes")
    print("TOOLSIZE total \(bytes)")
}

// hg3/search: one round of searches in one call, their results seen through, the first `top` read.

@MainActor @Test func readSearchesOneToFourQueriesAndReadsTheirTopResults() throws {
    let ask = try Read.parse(["search": [" widget license ", "widget changelog"]])
    #expect(ask.search == ["widget license", "widget changelog"] && ask.urls.isEmpty)
    #expect(ask.top == Read.defaultTop && ask.maxChars == Read.searchChars && ask.links == Read.searchLinks)
    #expect(try Read.parse(["search": "one query", "top": 99]).top == Read.topRange.upperBound)
    #expect(try Read.parse(["search": ["q"], "top": 0, "urls": ["https://a.com"]]).urls.count == 1)
    let plain = try Read.parse(["urls": ["https://a.com"]])
    #expect(plain.search.isEmpty && plain.links == Read.links && plain.maxChars == Read.defaultChars)
    // The engine gets the words escaped as an address bar would, `+` included.
    #expect(Read.engine("c++ \"a&b\"")?.absoluteString == "https://html.duckduckgo.com/html/?q=c%2B%2B%20%22a%26b%22")
}

@Test func searchSeesThroughTheEnginesRedirectsAndSkipsItsOwnPages() {
    let page = "https://html.engine.example/html/?q=widget"
    let links = [
        Read.Link(text: "Widget docs", url: "https://engine.example/l/?uddg=https%3A%2F%2Fdocs.example%2Fwidget&rut=abc", snippet: "Widget docs\ndocs.example/widget\nThe widget manual."),
        Read.Link(text: "Widget docs again", url: "https://docs.example/widget"),
        Read.Link(text: "More results", url: "https://html.engine.example/html/?q=widget&s=10"),
        Read.Link(text: "An ad", url: "https://engine.example/y.js?u3=https%3A%2F%2Fads.example%2Fclick%3F" + String(repeating: "x", count: 250)),
        Read.Link(text: "Direct", url: "https://other.example/w", snippet: "Direct\nhttps://other.example › w\nSecond result words."),
        Read.Link(text: "Third", url: "https://third.example/"),
    ]
    let got = Read.hits(links, page: page, count: 2)
    #expect(got.map(\.url) == ["https://docs.example/widget", "https://other.example/w"])
    #expect(got.map(\.snippet) == ["The widget manual.", "Second result words."])
    #expect(Read.hits(links, page: page, count: 6).count == 3)
}

@Test func searchReadsRankByRankEachPageOnceWithinRoom() {
    func hit(_ s: String) -> Read.Link { Read.Link(text: s, url: "https://\(s).example/") }
    let lists = [[hit("a"), hit("b"), hit("c")], [hit("a"), hit("d")], []]
    #expect(Read.picked(lists, top: 2, room: 12).map { $0.host()! } == ["a.example", "b.example", "d.example"])
    #expect(Read.picked(lists, top: 3, room: 2).map { $0.host()! } == ["a.example", "b.example"])
    #expect(Read.picked(lists, top: 0, room: 12).isEmpty)
    #expect(Read.picked(lists, top: 1, room: 12, skip: [URL(string: "https://a.example/")!]).isEmpty)
}

@Test func searchAnswerListsResultsPointingAtTheirReadPages() {
    let lists = [[Read.Link(text: "A page", url: "https://a.example/x", snippet: "about a"), Read.Link(text: "B page", url: "https://b.example/y")], []]
    let found = [Read.Result(asked: "https://html.engine.example/html/?q=a", status: .ok),
                 Read.Result(asked: "https://html.engine.example/html/?q=b", status: .blocked, note: "a human check")]
    let read = [Read.Result(asked: "https://a.example/x", url: "https://a.example/x", title: "A page", status: .ok, body: "A text")]
    let out = Read.searchFormat(["a", "b"], found: found, lists: lists, read: read, seconds: 3)
    #expect(out.hasPrefix("browser_read: 2 searches, 1 page read in 3.0 s (1 ok); tabs closed."))
    #expect(out.contains("search 1: \"a\"\n1. \"A page\" https://a.example/x → [1]\n   about a\n2. \"B page\" https://b.example/y\n"))
    #expect(out.contains("search 2: \"b\" — blocked: a human check"))
    #expect(out.contains("[1] ok · https://a.example/x · \"A page\"\nA text"))
}

@MainActor @Test func searchFindsHeadingLinksWithTheirBlocksAndSkipsAds() async throws {
    let web = await page("""
    <html><head><title>widget - Search</title></head><body><div id=top><a href="/html/?q=widget&ia=images">Images</a></div>
    <div class=r><div class=ad>Sponsored<a href="https://ads.example/c"><h3>Buy a widget</h3></a><p>ad words</p></div></div>
    <div class=r><h2><a href="/l/?uddg=https%3A%2F%2Fdocs.example%2Fw">Widget docs</a></h2><a href="/l/?uddg=https%3A%2F%2Fdocs.example%2Fw">docs.example/w</a><div>The widget manual.</div></div>
    <div class=r><a href="https://other.example/w"><h3>Other widget</h3></a><span>Second result words.</span></div>
    <h2>People also ask</h2></body></html>
    """)
    let got = try #require(await Read.capture(web, cap: 3000, main: false, results: true))
    #expect(got.links.map(\.text) == ["Widget docs", "Other widget"])
    #expect(got.links.first?.snippet.contains("The widget manual.") == true)
    #expect(Read.hits(got.links, page: got.href, count: 6).map(\.url) == ["https://docs.example/w", "https://other.example/w"])
    #expect(try #require(await Read.capture(web, cap: 3000, main: false)).links.isEmpty)
}

// hg3/stack4: a search engine's results page that is a human check or holds
// no results is run again, same words, on the next engine.

@Test func searchURLsGiveTheirEngineAndWords() {
    func q(_ s: String) -> String? { Read.searchQuery(URL(string: s)!).map { "\($0.engine): \($0.query)" } }
    #expect(q("https://www.google.com/search?q=widget+license+terms&hl=en") == "google: widget license terms")
    #expect(q("https://www.google.co.uk/search?client=x&q=c%2B%2B+%22a%26b%22") == "google: c++ \"a&b\"")
    #expect(q("https://www.google.com/search?q=Caf%C3%A9+hours") == "google: Café hours")
    #expect(q("https://www.bing.com/search?q=site%3Aexample.org+widget") == "bing: site:example.org widget")
    #expect(q("https://html.duckduckgo.com/html/?q=widget") == "duckduckgo: widget")
    #expect(q("https://duckduckgo.com/?q=widget&ia=web") == "duckduckgo: widget")
    for other in ["https://www.google.com/maps?q=widget", "https://www.google.com/search?q=+", "https://www.google.com/search?tbm=isch",
                  "https://example.com/search?q=widget", "https://docs.google.com/document/d/1", "https://www.bing.com/maps?q=widget"] {
        #expect(q(other) == nil, "\(other)")
    }
}

@Test func searchPagesWithoutResultsAreSeen() {
    let google = "https://www.google.com/search?q=widget"
    let check = Read.Result(asked: google, url: "https://www.google.com/sorry/index?continue=x", title: "x", status: .blocked, body: "Our systems have detected unusual traffic")
    #expect(Read.trouble(check, text: true, chars: 3000) == "blocked")
    #expect(Read.trouble(Read.Result(asked: google, url: "https://www.google.com/sorry/index", status: .ok, body: String(repeating: "w ", count: 400)), text: true, chars: 3000) == "blocked")
    #expect(Read.trouble(Read.Result(asked: google, status: .error, note: "HTTP 429"), text: true, chars: 3000) == "failed")
    // Only the engine's own words, the links block not counted: no results in it.
    let thin = Read.Result(asked: google, url: google, status: .ok, body: "Skip to content\nImages Videos Maps\n\nLinks:\n" + String(repeating: "- [a](https://a.example/)\n", count: 40))
    #expect(Read.trouble(thin, text: true, chars: 3000) == "gave no usable results")
    #expect(Read.trouble(thin, text: false, chars: 3000) == nil) // want values: not the page's text
    let full = Read.Result(asked: google, url: google, status: .ok, body: String(repeating: "A result title and its snippet. ", count: 40))
    #expect(Read.trouble(full, text: true, chars: 3000) == nil)
    #expect(Read.trouble(Read.Result(asked: google, status: .timeout), text: true, chars: 3000) == nil)
}

@MainActor @Test func aBlockedSearchIsRunAgainOnTheNextEngines() async throws {
    #expect(Read.chain(after: "google").map(\.name) == ["duckduckgo", "bing"])
    #expect(Read.chain(after: "duckduckgo").map(\.name) == ["bing"])
    #expect(Read.chain(after: "bing").map(\.name) == ["duckduckgo"])
    func hit(_ s: String) -> Read.Link { Read.Link(text: "\(s) title", url: "https://\(s).example/page", snippet: "\(s) title\n\(s) snippet words") }
    // Fixtures: duckduckgo answers "alpha" and blocks "beta"; bing answers "beta"; nobody answers "gamma".
    var loaded: [String] = []
    let load: Read.Load = { urls in
        loaded += urls.map(\.absoluteString)
        return urls.map { url -> Read.Result in
            let words = url.absoluteString
            var r = Read.Result(asked: words, url: words, title: "results", status: .ok)
            if words.contains("duckduckgo") && words.contains("alpha") { r.links = [hit("a1"), hit("a2")] }
            else if words.contains("duckduckgo") { r.status = .blocked }
            else if words.contains("bing") && words.contains("beta") { r.links = [hit("b1")] }
            return r
        }
    }
    let google = { (q: String) in "https://www.google.com/search?q=\(q)+widget" }
    var results = [
        Read.Result(asked: google("alpha"), url: "https://www.google.com/sorry/index", status: .blocked, body: "unusual traffic", note: "a human check (unusual traffic); not clicked"),
        Read.Result(asked: "https://plain.example/", url: "https://plain.example/", title: "Plain", status: .ok, body: "short"),
        Read.Result(asked: google("beta"), url: "https://www.google.com/sorry/index", status: .blocked),
        Read.Result(asked: google("gamma"), url: google("gamma"), status: .ok, body: "Images Videos"),
        Read.Result(asked: google("delta"), url: google("delta"), status: .ok, body: String(repeating: "Real results here. ", count: 60)),
    ]
    let plain = results[1], fine = results[4]
    try await Read.rescue(&results, ask: try Read.parse(["urls": ["https://a.com"]]), load: load)
    // duckduckgo first for all three stuck ones, then bing for the two it gave nothing.
    #expect(loaded == ["https://html.duckduckgo.com/html/?q=alpha%20widget", "https://html.duckduckgo.com/html/?q=beta%20widget", "https://html.duckduckgo.com/html/?q=gamma%20widget",
                       "https://www.bing.com/search?q=beta%20widget", "https://www.bing.com/search?q=gamma%20widget"])
    #expect(results[0].status == .ok && results[0].url == "https://html.duckduckgo.com/html/?q=alpha%20widget")
    #expect(results[0].note == "search blocked on google; results from duckduckgo. \(Read.unusable)")
    #expect(results[0].body == "1. \"a1 title\" https://a1.example/page\n   a1 snippet words\n2. \"a2 title\" https://a2.example/page\n   a2 snippet words")
    #expect(results[1] == plain && results[4] == fine)
    #expect(results[2].note == "search blocked on google and duckduckgo; results from bing. \(Read.unusable)" && results[2].body.contains("https://b1.example/page"))
    #expect(results[3].status == .ok && results[3].body == "Images Videos")
    #expect(results[3].note == "search gave no usable results on google; no results from duckduckgo, bing either. \(Read.unusable)")
    let said = Read.format(results, seconds: 4)
    #expect(said.contains("[1] ok · \(google("alpha")) → https://html.duckduckgo.com/html/?q=alpha%20widget · \"results\" — search blocked on google; results from duckduckgo."))

    // The search parameter's engine is duckduckgo: a blocked query goes to bing only.
    loaded = []
    let again = try await Read.retry(["beta widget", "alpha widget"], from: ["duckduckgo", "duckduckgo"], load: load)
    #expect(loaded == ["https://www.bing.com/search?q=beta%20widget", "https://www.bing.com/search?q=alpha%20widget"])
    #expect(again[0]?.engine == "bing" && again[0]?.failed == ["duckduckgo"] && again[1] == nil)
}
