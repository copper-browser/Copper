import Foundation
import Testing
@testable import Search

// ⌘K's and ⌘T's rows (Fork/CommandPalette.swift): keyed by what they are, so
// a row that only moved keeps its view, and a title that names its site
// twice says it once (council r3: "GitHub · … · GitHub · GitHub").

private func row(_ key: String, _ url: String, _ kind: Suggestion.Kind = .open, tab: UUID? = nil) -> Suggestion {
    Suggestion(key: key, title: "", url: URL(string: url)!, kind: kind, tab: tab)
}

@Test func rowsAreKeyedByWhatTheyAreNotWhereTheyAre() {
    let a = row("A", "https://a.example/"), b = row("B", "https://b.example/"), c = row("Run", "copper://command/split", .command)
    let first = CommandPalette.keyed([a, b, c]).map(\.id)
    let moved = CommandPalette.keyed([b, c, a]).map(\.id)
    #expect(Set(first) == Set(moved))
    #expect(moved[0] == first[1] && moved[2] == first[0])
}

@Test func rowKeysAreUniqueEvenForRepeats() {
    let one = UUID(), two = UUID()
    let rows = [row("A", "https://a.example/", tab: one), row("A", "https://a.example/", tab: two),
                row("A", "https://a.example/", .visited), row("A", "https://a.example/", .visited)]
    let ids = CommandPalette.keyed(rows).map(\.id)
    #expect(Set(ids).count == rows.count)
    #expect(CommandPalette.keyed(rows).map(\.index) == [0, 1, 2, 3])
}

@Test func aTitleSaysItsSiteOnce() {
    #expect(CommandPalette.tidy("GitHub · Change is constant. GitHub keeps you ahead. · GitHub · GitHub")
            == "GitHub · Change is constant. GitHub keeps you ahead.")
    #expect(CommandPalette.tidy("Pull requests · copper-browser/Copper · github") == "Pull requests · copper-browser/Copper · github")
    #expect(CommandPalette.tidy("Inbox · Gmail · gmail") == "Inbox · Gmail")
    #expect(CommandPalette.tidy("Hacker News") == "Hacker News")
}
