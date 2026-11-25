import Foundation
import Testing
@testable import Search

// The field's words (Fork/SearchEngines.swift): engines, the calculator,
// `.new` shortcuts, !bangs and site keywords — all worked out on this Mac.

// MARK: - engines

@Test func everyBuiltInEngineFillsItsTemplateWithEscapedWords() {
    for engine in SearchEngines.builtIn {
        let url = engine.url(for: "c++ & cats")!.absoluteString
        #expect(url.contains("c%2B%2B%20%26%20cats"), "\(engine.name): \(url)")
        #expect(url.hasPrefix("https://"))
    }
    #expect(SearchEngines.builtIn.map(\.name) == ["Google", "DuckDuckGo", "Bing", "Kagi", "Perplexity", "Ecosia", "Brave Search"])
}

@Test func aCustomEngineNeedsHttpAHostAndTheWordsOutsideIt() {
    #expect(SearchEngines.custom("https://search.example.com/?q=%s")?.name == "search.example.com")
    #expect(SearchEngines.custom("https://www.example.com/find/%s")?.name == "example.com")
    #expect(SearchEngines.custom("https://example.com/?q=") == nil)          // no %s
    #expect(SearchEngines.custom("https://%s.example.com/") == nil)          // the words would pick the site
    #expect(SearchEngines.custom("javascript:alert(%s)") == nil)
    #expect(SearchEngines.custom("file:///tmp/%s") == nil)
}

// MARK: - calculator

@Test func sumsAreWorkedOut() {
    let cases: [(String, String)] = [
        ("2*21", "42"), ("2 × 21", "42"), ("1920x1080", "2073600"), ("10/4", "2.5"), ("7 ÷ 2", "3.5"),
        ("2^10", "1024"), ("-2^2", "-4"), ("(1+2)*3", "9"), ("1 + 2 * 3", "7"), ("0.1+0.2", "0.3"),
        ("50 * 20%", "10"), ("200 + 10%", "200.1"), ("20% + 1", "1.2"), ("50 * 20% + 1", "11"), ("10 % 3", "1"), ("1,000 * 3", "3000"), ("= 6/3", "2"), ("6/3 =", "2"),
        ("2 − 3", "-1"),
    ]
    for (typed, value) in cases {
        #expect(Calculator.answer(typed)?.value == value, "\(typed)")
    }
}

@Test func thingsThatAreNotSumsAreLeftAlone() {
    for typed in ["42", "-5", "(5)", "50%", "-(5)", "2026-11-25", "1-800-555-0100", "1.2.3", "192.168.1.1", "localhost:3000", "github.com", "hello 2+2",
                  "1/0", "2*", "(1+2", "1,2+3", "", "x", "cats", "! 1", "1 2"] {
        #expect(Calculator.answer(typed) == nil, "\(typed)")
    }
}

@Test func aSumRowCopiesItsValue() {
    let row = SearchEngines.answer(for: "2*21")!
    #expect(row.key == "2*21 = 42")
    #expect(row.url.scheme == "copper" && row.url.host() == "copy" && row.url.lastPathComponent == "42")
    #expect(row.kind == .command && row.hint == "Copy")
}

// MARK: - .new

@Test func dotNewShortcutsAndNewPhrases() {
    #expect(QuickNew.all.count == 17)
    #expect(QuickNew.find("doc.new")?.url == "https://docs.new")
    #expect(QuickNew.find("Sheet.new")?.title == "New Google Sheet")
    #expect(QuickNew.find("new doc")?.url == "https://docs.new")
    #expect(QuickNew.find("create figma")?.url == "https://figma.new")
    #expect(QuickNew.find("new issue")?.url == "https://linear.new")    // a whole name before a prefix
    #expect(QuickNew.find("new sli")?.url == "https://slides.new")     // the start of one, while typing
    #expect(QuickNew.url("new sli") == nil)                            // but Return wants it whole
    #expect(QuickNew.url("new slides")?.absoluteString == "https://slides.new")
    #expect(QuickNew.url("cal.new")?.absoluteString == "https://cal.new")
    #expect(QuickNew.find("new york") == nil)
    #expect(QuickNew.find("news") == nil)
    #expect(QuickNew.find("foo.new") == nil)                           // a .new site we don't know is still an address
    #expect(Google.destination(for: "doc.new")?.absoluteString == "https://docs.new")
    #expect(Google.destination(for: "foo.new")?.absoluteString == "https://foo.new")
}

// MARK: - !bangs

@Test func theBundledBangsAreTheMostUsedOnes() {
    #expect(Bangs.bundled.count == 200)
    for trigger in ["g", "yt", "w", "gh", "a", "r", "maps", "imdb", "npm", "mdn"] {
        #expect(Bangs.table[trigger] != nil, "!\(trigger)")
    }
    // Every template keeps the words out of its host, and opens a page.
    for bang in Bangs.ordered {
        #expect(!bang.host.isEmpty && !bang.host.contains("%s"), "!\(bang.trigger)")
        #expect(SearchEngines.fill(bang.template, with: "a b") != nil, "!\(bang.trigger)")
    }
}

@Test func aBangFirstOrLastSearchesItsSite() {
    let first = Bangs.resolve("!w paris")!
    #expect(first.url.absoluteString == "https://en.wikipedia.org/wiki/Special:Search?search=paris")
    #expect(first.label == "Search Wikipedia for “paris”")
    #expect(Bangs.resolve("paris !W")?.url == first.url)
    #expect(Bangs.resolve("!yt")?.url.absoluteString == "https://www.youtube.com")
    #expect(Bangs.resolve("!gh copper browser")?.url.absoluteString.hasPrefix("https://github.com/search") == true)
    // Not bangs: words that happen to hold a "!".
    #expect(Bangs.resolve("hello!") == nil)
    #expect(Bangs.resolve("wow ! nice") == nil)
    #expect(Bangs.resolve("!") == nil)
    #expect(Bangs.resolve("!!! now") == nil)
    #expect(Bangs.resolve("cats") == nil)
}

@Test func anUnknownBangIsLeftToDuckDuckGo() {
    let ddg = Bangs.resolve("!zzqqx cats")!
    #expect(ddg.url.absoluteString == "https://duckduckgo.com/?q=%21zzqqx%20cats")
    #expect(ddg.name == "DuckDuckGo")
}

@Test func siteKeywordsForTab() {
    #expect(Bangs.keyword("yt") == "yt")
    #expect(Bangs.keyword("YouTube") == "youtube")
    #expect(Bangs.keyword("youtube.com") == "yt")
    #expect(Bangs.keyword("https://www.github.com/") == "gh")
    #expect(Bangs.keyword("wikipedia.org") == "w")
    #expect(Bangs.keyword("reddit") == "r" || Bangs.keyword("reddit") == "reddit")
    #expect(Bangs.keyword("w") == nil)          // one letter: Tab still completes
    #expect(Bangs.keyword("com") == nil)
    #expect(Bangs.keyword("cats and dogs") == nil)
    #expect(Bangs.keyword("!yt") == nil)
    #expect(Bangs.keyword("zzqqx.example") == nil)
}

@Test func localAnswersAreNeverSentForCompletion() {
    for typed in ["2*21", "doc.new", "new doc", "!w paris", "!yt ", "yt", "github.com"] {
        #expect(SearchEngines.local(typed), "\(typed)")
    }
    for typed in ["cats", "copper browser", "new york"] {
        #expect(!SearchEngines.local(typed), "\(typed)")
    }
}

// Search suggestions (Settings › General › Search): on by default; off, ⌘T
// asks no engine anything while you type. Both states in one test, the
// switch put back as it was.
@Test func theSuggestionsSwitchStopsEveryAsk() {
    let store = Store.settings
    let kept = store.object(forKey: SearchEngines.suggestKey)
    defer { store.set(kept, forKey: SearchEngines.suggestKey) }

    store.removeObject(forKey: SearchEngines.suggestKey)
    #expect(SearchEngines.suggests, "on unless turned off")
    let url = SearchEngines.suggestURL(for: "copper browser")?.absoluteString ?? ""
    #expect(url.contains("copper%20browser") && url.hasPrefix(SearchEngines.current.suggest?.components(separatedBy: "%s")[0] ?? "-"), "\(url)")
    for typed in ["2*21", "!w paris", "/history", "https://x.com/a"] {
        #expect(SearchEngines.suggestURL(for: typed) == nil, "\(typed)")
    }

    store.set(false, forKey: SearchEngines.suggestKey)
    #expect(!SearchEngines.suggests)
    for typed in ["c", "ca", "cats", "copper browser", "new york", "what is my ip"] {
        #expect(SearchEngines.suggestURL(for: typed) == nil, "\(typed)")
    }
}
