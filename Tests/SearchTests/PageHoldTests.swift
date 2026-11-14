import AppKit
import Testing
import WebKit
@testable import Search

// A page coming onto the stage keeps the one going out under it until it has
// drawn (Stage.swift, StageView `hold`; Fork: page-hold) — only a page that
// has drawn before and was out of a window a second or more, or comes in with
// a space switch (`StageView.holds`; Fork: space-perf).

@Suite("The page going out stays until the one coming in has drawn")
@MainActor
struct PageHoldTests {
    private func stage() -> (NSWindow, StageView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = StageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = stage
        return (window, stage)
    }

    private func page() -> PageView { PageView(frame: .zero, configuration: WKWebViewConfiguration()) }

    @Test("A page that has never drawn never keeps another page under it (no two pages faded over each other)")
    func freshPageTakesTheStageAtOnce() async throws {
        let (window, stage) = stage()
        defer { window.close() }
        let old = page()
        stage.show(old)
        let new = page()
        new.holdForFirstFrame()
        guard new.unpainted else { return } // a WebKit without the first-frame event shows a page at once
        stage.show(new)
        #expect(stage.subviews == [new], "the old page goes in the same frame; the ground (or the tab's own picture) shows")
        #expect(new.alphaValue == 0)
        new.showFirstFrame()
        try await Task.sleep(for: .milliseconds(300))
        #expect(new.alphaValue == 1)
    }

    @Test("A page back on the stage within a second swaps in one frame; one out longer is held")
    func holdOnlyAfterASecondOut() async throws {
        let (window, stage) = stage()
        defer { window.close() }
        let one = page(), two = page()
        stage.show(one)
        stage.show(two)
        try await Task.sleep(for: .milliseconds(350)) // any hold of `two` over `one` ends (≤0.3 s)
        stage.show(one) // `one` left the window ~0.35 s ago
        #expect(stage.subviews == [one], "back inside a second: no hold, `two` goes at once")
        #expect(one.alphaValue == 1)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(StageView.holds(two), "out for over a second: WebKit may give it back white, so the stage holds")
    }

    @Test("A hold cut short by the stage leaving its window never leaves the page unseen")
    func cutShort() async throws {
        let (window, stage) = stage()
        defer { window.close() }
        stage.show(page())
        let new = page()
        stage.show(new)
        // Not asserted unseen here: a web view with no web process yet has WebKit
        // answer `_doAfterNextPresentationUpdate:` at once, so the hold may already be over.
        window.contentView = nil
        stage.layout()
        window.contentView = stage
        stage.layout()
        try await Task.sleep(for: .milliseconds(500))
        #expect(new.superview === stage)
        #expect(new.alphaValue == 1)
        #expect(stage.subviews == [new])
    }
}
