import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

// Jev's page script (Tools.Ultrafast.script) on a real page: what `deep`
// reads and where it acts, and what `calm` lets the settle ignore.

private typealias U = Tools.Ultrafast

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
}

@MainActor private var kept: [AnyObject] = []

@MainActor
private func page(_ html: String) async -> WKWebView {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    // In a window, so the page draws and gets frames. A panel: kept open, an NSWindow would make
    // LaunchWindowTests' "app has an open window" question true for the whole run.
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    window.orderBack(nil)
    let loaded = Loaded()
    web.navigationDelegate = loaded
    await withCheckedContinuation { c in loaded.done = c; web.loadHTMLString(html, baseURL: URL(string: "https://jev.test/")) }
    kept += [window, loaded]
    return web
}

private let framed = """
<html><body style="margin:0">
<button id="top">Top button</button>
<div id="host"></div>
<iframe id="f" style="position:absolute; left:100px; top:200px; width:300px; height:150px; border:5px solid black; padding:0"
  srcdoc="<body style='margin:0'><input id='q' placeholder='Frame field' style='position:absolute;left:10px;top:20px;width:120px;height:20px;box-sizing:border-box'></body>"></iframe>
<script>
  const root = document.getElementById('host').attachShadow({mode: 'open'});
  root.innerHTML = '<button id="inner">Shadow button</button>';
  root.getElementById('inner').addEventListener('click', () => { window.shadowClicked = true; });
</script>
</body></html>
"""

private func labels(_ obs: [String: Any]?) -> [String] {
    ((obs?["actions"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
}

@MainActor @Test func deepReadsShadowRootsAndFramesAndActsThere() async throws {
    let web = await page(framed)
    let flat = try await U.js(web, "window.__jevFast.observe(undefined, {deep: false})") as? [String: Any]
    #expect(labels(flat).contains("Top button"))
    #expect(!labels(flat).contains("Shadow button") && !labels(flat).contains("Frame field"))

    let deep = try await U.js(web, "window.__jevFast.observe(undefined, {deep: true})") as? [String: Any]
    let actions = (deep?["actions"] as? [[String: Any]]) ?? []
    #expect(labels(deep).contains("Top button") && labels(deep).contains("Shadow button"))
    // The frame's field, at its place on the top page: frame 100+5 border, field 10 → x 115…235.
    let field = try #require(actions.first { $0["label"] as? String == "Frame field" && $0["kind"] as? String == "fill" })
    let rect = try #require(field["rect"] as? [String: Any])
    #expect((rect["x"] as? NSNumber)?.doubleValue == 115 && (rect["y"] as? NSNumber)?.doubleValue == 225)

    // act's point: the field's centre on the top page, hit-tested in its own frame.
    let point = try #require(try await U.js(web, "window.__jevFast.resolve(\(U.encode(field)))") as? [String: Any])
    #expect((point["x"] as? NSNumber)?.doubleValue == 175 && (point["y"] as? NSNumber)?.doubleValue == 235)
    // typing goes into the frame's field
    let node = try #require((field["node"] as? NSNumber)?.intValue)
    let held = try await U.js(web, "window.__jevFast.insert(\(node), 'hello')") as? String
    #expect(held == "hello")
    #expect(try await U.js(web, "document.getElementById('f').contentDocument.getElementById('q').value") as? String == "hello")

    // a shadow root's button resolves (hit-tested in its own tree) and takes a click
    let button = try #require(actions.first { $0["label"] as? String == "Shadow button" })
    #expect(try await U.js(web, "window.__jevFast.resolve(\(U.encode(button)))") is [String: Any])
    let bnode = try #require((button["node"] as? NSNumber)?.intValue)
    _ = try await U.js(web, "window.__jevFast.domClick(\(bnode))")
    #expect(try await Tools.Page.raw(web, "window.shadowClicked === true", world: .page) as? Bool == true)

    // a frame covered on the top page is no place to click
    _ = try await Tools.Page.raw(web, "const c=document.createElement('div'); c.style.cssText='position:fixed;inset:0;background:white'; document.body.append(c); true", world: .page)
    #expect(try await U.js(web, "window.__jevFast.resolve(\(U.encode(field)))") == nil)
}

// `calm`'s filter on real mutation records: a class written with the value it
// had is no change, a second style write within 200 ms is not one either, a
// real class change and the first style write are; without calm all count.
@MainActor @Test func calmCountsOnlyRealChanges() async throws {
    let web = await page("<html><body><div id='a' class='x'>a</div><div id='b'>b</div></body></html>")
    _ = try await U.js(web, "true")
    let counted = try await U.js(web, """
    (() => { const a = document.getElementById('a'), b = document.getElementById('b');
      const o = new MutationObserver(() => {}); o.observe(document.body, {subtree: true, attributes: true, attributeOldValue: true});
      a.setAttribute('class', 'x'); b.style.width = '10px'; b.style.width = '11px';
      const records = o.takeRecords(); a.setAttribute('class', 'y'); records.push(...o.takeRecords()); o.disconnect();
      const calm = window.__jevFast.change(true), plain = window.__jevFast.change(false);
      return [records.filter(calm).length, records.filter(plain).length]; })()
    """) as? [NSNumber]
    #expect(counted?.map(\.intValue) == [2, 4])
}

// A search form's controls are marked `query` (searchControl lets them go
// again once); a review form's are not.
@MainActor @Test func queryFormsAreMarked() async throws {
    let web = await page("""
    <form action="/s"><input name="q" placeholder="Search the shop"><button>Go</button></form>
    <form id="r"><input name="review" placeholder="Your review"><button>Post review</button></form>
    <div role="search"><input placeholder="Find docs"><button type="button">Find</button></div>
    """)
    let obs = try await U.js(web, "window.__jevFast.observe(undefined, {deep: false})") as? [String: Any]
    let actions = (obs?["actions"] as? [[String: Any]]) ?? []
    func marked(_ label: String) -> Bool { actions.first { $0["label"] as? String == label }?["query"] as? Bool == true }
    #expect(marked("Go") && marked("Search the shop") && marked("Find") && marked("Find docs"))
    #expect(!marked("Post review") && !marked("Your review"))
    let inForm = { (label: String) in actions.first { $0["label"] as? String == label }?["inForm"] as? Bool == true }
    #expect(inForm("Post review") && !inForm("Go") && !inForm("Find"))
}

// Ads are not offered: a sponsored brand-store banner is not the product.
@MainActor @Test func sponsoredLinksAreLeftOut() async throws {
    let web = await page("""
    <a href="https://shop.test/stores/page/X?store_ref=SB_1">Brand store banner</a>
    <a href="https://shop.test/sspa/click?x=1">Sponsored pick</a>
    <div aria-label="Sponsored"><a href="https://shop.test/dp/2">Boxed ad</a></div>
    <a href="https://shop.test/dp/1">The product</a>
    """)
    let obs = try await U.js(web, "window.__jevFast.observe(undefined, {deep: false})") as? [String: Any]
    let shown = labels(obs)
    #expect(shown.contains("The product"))
    #expect(!shown.contains("Brand store banner") && !shown.contains("Sponsored pick") && !shown.contains("Boxed ad"))
}
