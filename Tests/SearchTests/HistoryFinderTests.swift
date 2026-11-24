import Foundation
import Testing
@testable import Search

// ⌘Y (Fork/HistoryFinder.swift): history is found off the main thread and
// drawn a page at a time. The panel used to lay out all 20,000 places of an
// imported history in one eager stack and hung until the app was killed.

private func place(_ key: String, _ title: String, _ last: TimeInterval, count: Int = 1) -> History.Place {
    History.Place(key: key, title: title, lowered: title.lowercased(), url: "https://" + key, count: count, last: Date(timeIntervalSince1970: last))
}

@Test func listedIsNewestFirstWithoutDomainCredits() {
    let list = HistoryFinder.listed([
        place("github.com", "", 300),                      // a credit: no title, no path
        place("github.com/copper-browser/Copper", "Copper", 100),
        place("news.ycombinator.com", "Hacker News", 200), // a bare domain with a title stays
    ])
    #expect(list.map(\.key) == ["news.ycombinator.com", "github.com/copper-browser/Copper"])
}

@Test func emptyNeedleIsEverything() {
    let places = HistoryFinder.listed((0..<50).map { place("site\($0).com/p", "Page \($0)", Double($0)) })
    #expect(HistoryFinder.matching(places, needle: "  ").count == 50)
}

@Test func wordsMatchInAnyOrderAcrossAddressAndTitle() {
    let places = [
        place("github.com/copper-browser/Copper/pull/204", "Fix history panel", 3),
        place("linear.app/exowatt/issue/42", "Copper settings", 2),
        place("example.com/blog", "Engineering notes", 1),
    ]
    #expect(HistoryFinder.matching(places, needle: "panel github").map(\.key) == ["github.com/copper-browser/Copper/pull/204"])
    #expect(HistoryFinder.matching(places, needle: "Copper").count == 2)
}

@Test func lettersInOrderWhenNoWordMatches() {
    let places = [
        place("github.com/copper-browser/Copper/pull/204", "Fix history panel", 2),
        place("example.com/blog", "Engineering notes", 1),
    ]
    #expect(HistoryFinder.matching(places, needle: "ghpull").map(\.key) == ["github.com/copper-browser/Copper/pull/204"])
    // Two letters is too few to go looking for them in order.
    #expect(HistoryFinder.matching(places, needle: "qz").isEmpty)
}

@Test func daysAreRunsOfNewestFirstLines() {
    let now = Date()
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    let url = URL(string: "https://example.com")!
    let traces = [now, now, yesterday].enumerated().map { index, when in
        History.Trace(key: "k\(index)", title: "t", url: url, last: when, count: 1)
    }
    let days = HistoryFinder.byDay(traces)
    #expect(days.map(\.title) == ["Today", "Yesterday"])
    #expect(days.map(\.rows.count) == [2, 1])
}

@Test func twentyThousandPlacesAreFoundQuickly() {
    let places = (0..<20_000).map { place("host\($0 % 700).com/path/\($0)", "Some page title number \($0)", Double($0)) }
    let start = Date()
    let list = HistoryFinder.listed(places)
    let hits = HistoryFinder.matching(list, needle: "number 19")
    let fuzzy = HistoryFinder.matching(list, needle: "hst7pth")
    let took = Date().timeIntervalSince(start)
    #expect(list.first?.key == "host399.com/path/19999")
    #expect(!hits.isEmpty)
    #expect(!fuzzy.isEmpty)
    // Debug build, off the main thread in the app; generous so CI never flakes.
    #expect(took < 2)
}
