import Testing
@testable import Search

// A pin's unread light (Fork/PinLight.swift): a title that starts with an
// unread count above zero.

@Suite("Pin light")
struct PinLightTests {
    @Test("Leading count above zero lights", arguments: ["(1) Paper", "(3) Inbox", "(12) Slack | general", "(1,204) Home / X", "Inbox (3) - me@x.com - Gmail", "(2)"])
    func lights(_ title: String) { #expect(PinLight.unread(title)) }

    @Test("Anything else stays dark", arguments: ["(0) x", "Paper", "Year (2026)", "", "(a) b", "() Paper", "(1)Paper", " (1) Paper", "Inbox - me@x.com - Gmail"])
    func dark(_ title: String) { #expect(!PinLight.unread(title)) }
}
