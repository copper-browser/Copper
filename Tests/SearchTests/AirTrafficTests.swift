import Foundation
import Testing
@testable import Search

// Air Traffic Control's matcher (Fork/AirTraffic.swift): which rule takes a
// link from which app.

private func url(_ text: String) -> URL { URL(string: text)! }

@Test @MainActor func aHostTakesItsSubdomainsAndWww() {
    #expect(AirTraffic.site("github.com", matches: url("https://github.com/x")))
    #expect(AirTraffic.site("github.com", matches: url("https://www.github.com/")))
    #expect(AirTraffic.site("github.com", matches: url("https://gist.github.com/a")))
    #expect(AirTraffic.site("https://GitHub.com", matches: url("https://github.com/x")))
    #expect(!AirTraffic.site("github.com", matches: url("https://notgithub.com/")))
    #expect(!AirTraffic.site("github.com", matches: url("https://github.com.evil.io/")))
}

@Test @MainActor func aPathTakesWhatIsUnderIt() {
    #expect(AirTraffic.site("github.com/copper-browser", matches: url("https://github.com/copper-browser/Copper/pulls")))
    #expect(AirTraffic.site("github.com/copper-browser/", matches: url("https://github.com/copper-browser")))
    #expect(!AirTraffic.site("github.com/copper", matches: url("https://github.com/copper-browser")))
}

@Test @MainActor func starsMatchAnyRun() {
    #expect(AirTraffic.site("*.google.com", matches: url("https://maps.google.com/x")))
    #expect(!AirTraffic.site("*.google.com", matches: url("https://google.com/")))
    #expect(AirTraffic.site("*google.com/maps*", matches: url("https://www.google.com/maps/place/x")))
    #expect(AirTraffic.site("*/pull/*", matches: url("https://github.com/a/b/pull/12")))
    #expect(!AirTraffic.site("*/pull/*", matches: url("https://github.com/a/b/issues/12")))
    #expect(AirTraffic.glob(Array("a*b*c"), Array("aXXbYYc")))
    #expect(!AirTraffic.glob(Array("a*b*c"), Array("aXXbYY")))
    #expect(AirTraffic.glob(Array("*"), Array("")))
}

@Test @MainActor func anyOrOneApp() {
    let any = AirTraffic.Rule(site: "github.com")
    let slack = AirTraffic.Rule(app: "com.tinyspeck.slackmacgap", site: "")
    #expect(AirTraffic.matches(any, url("https://github.com/x"), from: nil))
    #expect(AirTraffic.matches(slack, url("https://example.com/"), from: "com.tinyspeck.slackmacgap"))
    #expect(!AirTraffic.matches(slack, url("https://example.com/"), from: "com.apple.mail"))
    #expect(!AirTraffic.matches(slack, url("https://example.com/"), from: nil))
    #expect(AirTraffic.site("", matches: url("https://anything.dev/")))
}

@Test @MainActor func aBookReadsBackAsWritten() throws {
    var book = AirTraffic.Book()
    book.rules = [AirTraffic.Rule(app: "com.apple.Terminal", appName: "Terminal", site: "github.com",
                                  to: AirTraffic.Target(space: UUID(), open: .little))]
    book.otherwise = AirTraffic.Target(space: nil, open: .window)
    let back = try JSONDecoder().decode(AirTraffic.Book.self, from: JSONEncoder().encode(book))
    #expect(back == book)
}
