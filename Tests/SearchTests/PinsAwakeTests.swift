import AppKit
import Foundation
import Testing
@testable import Search

// Pinned tabs never unload (Fork/PinsAwake.swift): the rule, the crash-loop
// guard on the background reloads, and the two low-level entry points that
// refuse a pin.

@Suite("Pins never unload")
struct PinRuleTests {
    @Test("A pin keeps its page for every reason but closing it for good")
    func pinnedRefuses() {
        #expect(!PinRule.mayUnload(pinned: true, .sleep))
        #expect(!PinRule.mayUnload(pinned: true, .putDown))
        #expect(PinRule.mayUnload(pinned: true, .close))
    }

    @Test("An unpinned tab may let its page go, as before")
    func unpinnedMay() {
        #expect(PinRule.mayUnload(pinned: false, .sleep))
        #expect(PinRule.mayUnload(pinned: false, .putDown))
        #expect(PinRule.mayUnload(pinned: false, .close))
    }

    @Test("A pin without a page is loaded; a blank pin, a loaded pin or a loose tab is not")
    func needsPage() {
        #expect(PinRule.needsPage(pinned: true, blank: false, asleep: true, built: false))
        #expect(PinRule.needsPage(pinned: true, blank: false, asleep: false, built: false))
        #expect(!PinRule.needsPage(pinned: true, blank: false, asleep: false, built: true))
        #expect(!PinRule.needsPage(pinned: true, blank: true, asleep: false, built: false))
        #expect(!PinRule.needsPage(pinned: false, blank: false, asleep: true, built: false))
    }
}

@Suite("A pin's background reloads: three in ten minutes")
struct PinReloadsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test("Three reloads are allowed, the fourth inside ten minutes is not")
    func threeThenStale() {
        var guardrail = PinReloads()
        let tab = UUID()
        let seconds: [Double] = [0, 60, 120, 180, 599]
        let answers = seconds.map { guardrail.allow(tab, at: at($0)) }
        #expect(answers == [true, true, true, false, false])
        // A refusal is not counted: the window still runs from the first.
        #expect(guardrail.count(tab, at: at(599)) == 3)
    }

    @Test("Once the oldest reload is ten minutes old, there is room for one more")
    func windowSlides() {
        var guardrail = PinReloads()
        let tab = UUID()
        let seconds: [Double] = [0, 60, 120, 540, 600, 630, 660]
        let answers = seconds.map { guardrail.allow(tab, at: at($0)) }
        #expect(answers == [true, true, true, false, true, false, true])
    }

    @Test("Each tab has its own count, and forgetting one clears it")
    func perTab() {
        var guardrail = PinReloads()
        let gmail = UUID(), calendar = UUID()
        let first = (0..<4).map { _ in guardrail.allow(gmail, at: start) }
        #expect(first == [true, true, true, false])
        let other = guardrail.allow(calendar, at: start)
        #expect(other)
        #expect(guardrail.count(calendar, at: start) == 1)
        guardrail.forget(gmail)
        let again = guardrail.allow(gmail, at: start)
        #expect(again)
    }
}

@Suite("Tab refuses to unload a pin")
@MainActor
struct PinnedTabTests {
    private func loadedTab() throws -> Tab {
        // A tab asks the app's appearance for its icon; a test process has no app until asked.
        _ = NSApplication.shared
        let tab = Tab()
        tab.setAddressOptimistically(try #require(URL(string: "https://mail.google.com/mail/u/0/")))
        _ = tab.web
        return tab
    }

    @Test("Sleep and put-down leave a pin's page where it is")
    func pinStaysLoaded() throws {
        let tab = try loadedTab()
        tab.pin = "G"
        tab.sleep(picture: nil)
        #expect(tab.built != nil)
        #expect(!tab.asleep)
        tab.rest()
        #expect(tab.built != nil)
        #expect(!tab.asleep)
        tab.close()
    }

    @Test("Unpinned, the same tab sleeps and is put down as any tab is")
    func unpinnedLetsGo() throws {
        let sleeper = try loadedTab()
        sleeper.pin = "G"
        sleeper.pin = nil
        sleeper.sleep(picture: nil)
        #expect(sleeper.built == nil)
        #expect(sleeper.asleep)
        sleeper.close()

        let rested = try loadedTab()
        rested.rest()
        #expect(rested.built == nil)
        #expect(rested.asleep)
        rested.close()
    }

    @Test("Closing a pin for good still lets its page go")
    func closeStillCloses() throws {
        let tab = try loadedTab()
        tab.pin = "G"
        tab.close()
        #expect(tab.built == nil)
    }
}
