import Testing
@testable import Search

// ⌘K ranks with ⌘T's matcher (Fork/Launcher.swift `Needle`): a word that
// starts a title beats the same letters somewhere inside an address. Typing
// "spa" with "Spaces — Copper Docs" open and Gmail pinned at
// workspace.google.com put both in the list with Gmail's host match level
// with the title (council r1, cmdk-query).

private func score(_ typed: String, key: String, title: String) -> Double? {
    Launcher.Needle(typed)?.score(key: key, title: title.lowercased())
}

@Test func aTitleWordStartBeatsLettersInsideAnAddress() throws {
    let title = try #require(score("spa", key: "127.0.0.1:4206/spaces.html", title: "Spaces — Copper Docs"))
    let host = try #require(score("spa", key: "workspace.google.com/intl/en/gmail", title: "Gmail: Secure, AI-Powered Email"))
    #expect(title > host)
    // A later word of the title counts as its start too.
    let later = try #require(score("cop", key: "127.0.0.1/spaces", title: "Spaces — Copper Docs"))
    let path = try #require(score("cop", key: "example.com/notes/copy-paste", title: "Notes"))
    #expect(later > path)
}

@Test func oneLetterMatchesOnlyAtTheStartOfSomething() {
    // "g" no longer lists every tab with a g anywhere in it.
    #expect(score("g", key: "example.com/blog", title: "Engineering notes") == nil)
    #expect(score("g", key: "github.com", title: "GitHub") != nil)
}
