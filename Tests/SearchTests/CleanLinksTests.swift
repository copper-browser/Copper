import Foundation
import Testing
@testable import Search

// Copied links lose their trackers and keep everything a page needs
// (Fork/CleanLinks.swift): ⇧⌘C, Copy Link, Copy as Markdown, the
// highlight link and Share all go through it.

@Suite("Clean links")
struct CleanLinksTests {
    func clean(_ text: String) -> String { CleanLinks.strip(URL(string: text)!).absoluteString }

    @Test("Trackers go", arguments: [
        ("https://example.com/post?utm_source=newsletter&utm_medium=email&utm_campaign=fall", "https://example.com/post"),
        ("https://example.com/?fbclid=IwAR0abc", "https://example.com/"),
        ("https://shop.example/item?id=42&gclid=Cj0KCQ&color=red", "https://shop.example/item?id=42&color=red"),
        ("https://news.example/a?mc_eid=123&mc_cid=456&page=2", "https://news.example/a?page=2"),
        ("https://x.example/?_hsenc=p2A&_hsmi=1&msclkid=9&dclid=3", "https://x.example/"),
        ("https://example.com/?UTM_Source=caps", "https://example.com/"),
        ("https://example.com/a?q=a%20b&utm_source=x#section-2", "https://example.com/a?q=a%20b#section-2"),
        ("https://example.com/?q=abc&&fbclid=1", "https://example.com/?q=abc"),
        ("https://user:pw@example.com:8443/p?utm_term=x&k", "https://user:pw@example.com:8443/p?k"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=AbCdEf", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ?si=AbCdEf&t=42", "https://youtu.be/dQw4w9WgXcQ?t=42"),
        ("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=a1b2c3", "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"),
        ("https://twitter.com/jack/status/20?ref_src=twsrc%5Etfw", "https://twitter.com/jack/status/20"),
        ("https://x.com/jack/status/20?s=20&t=abc", "https://x.com/jack/status/20"),
        ("https://www.instagram.com/p/abc/?igshid=MzRl", "https://www.instagram.com/p/abc/"),
        ("https://www.amazon.com/dp/B0C1?ref_=ast_sto_dp&pd_rd_w=x&th=1", "https://www.amazon.com/dp/B0C1?th=1"),
    ])
    func strips(_ pair: (String, String)) { #expect(clean(pair.0) == pair.1) }

    @Test("What a page needs stays exactly as it was", arguments: [
        "https://example.com/search?q=utm_source",
        "https://example.com/?b=2&a=1",
        "https://example.com/path",
        "https://example.com/?q=abc&",
        "https://example.com/a#frag?utm_medium=y",
        "https://www.google.com/search?q=si&s=1&t=2&ref=a&source=b",  // other sites' meanings
        "https://docs.example/page?si=keep",
        "copper://command/translate?utm_source=x",
        "file:///tmp/a.html?fbclid=1",
    ])
    func keeps(_ text: String) { #expect(clean(text) == text) }

    @Test("Markdown: a one-line label and an address every reader ends in the right place")
    func markdown() {
        #expect(CleanLinks.markdown(title: "Plain", url: URL(string: "https://e.example/?a=1&b=2&fbclid=3")!) == "[Plain](https://e.example/?a=1&b=2)")
        #expect(CleanLinks.markdown(title: "", url: URL(string: "https://e.example/?utm_source=x")!) == "[https://e.example/](https://e.example/)")
        #expect(CleanLinks.markdown(title: "Shop [sale] \\o/", url: URL(string: "https://shop.example/p")!) == "[Shop \\[sale\\] \\\\o/](https://shop.example/p)")
        #expect(CleanLinks.markdown(title: "Up\n\n  Film ", url: URL(string: "https://en.wikipedia.org/wiki/Up_(2009_film)")!)
            == "[Up Film](https://en.wikipedia.org/wiki/Up_%282009_film%29)")
    }

    @Test("Highlight: the quote in a text fragment after the page's own")
    func highlight() {
        let url = URL(string: "https://e.example/a?utm_source=x#intro")!
        #expect(CleanLinks.highlight(url, quote: "  Hello,  world - again & more ")?.absoluteString
            == "https://e.example/a#intro:~:text=Hello%2C%20world%20%2D%20again%20%26%20more")
        // Across paragraphs: the first and the last five words.
        #expect(CleanLinks.highlight(URL(string: "https://e.example/")!, quote: "one two three four five six\nseven eight nine ten eleven twelve")?.absoluteString
            == "https://e.example/#:~:text=one%20two%20three%20four%20five,eight%20nine%20ten%20eleven%20twelve")
        // An older directive is replaced, not stacked.
        #expect(CleanLinks.highlight(URL(string: "https://e.example/#:~:text=old")!, quote: "new")?.absoluteString == "https://e.example/#:~:text=new")
        #expect(CleanLinks.highlight(url, quote: " \n ") == nil)
    }
}
