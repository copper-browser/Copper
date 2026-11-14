import AppKit
import Testing
import WebKit
@testable import Search

// A page coming onto the stage keeps the one going out under it until it has
// drawn (Stage.swift, StageView `hold`; Fork: page-hold).

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

    @Test("A page that has never drawn comes in over the old one, which goes once it has")
    func holdsUntilFirstFrame() async throws {
        let (window, stage) = stage()
        defer { window.close() }
        let old = page()
        stage.show(old)
        let new = page()
        new.holdForFirstFrame()
        guard new.unpainted else { return } // a WebKit without the first-frame event shows a page at once
        stage.show(new)
        #expect(stage.subviews.contains(old), "the old page stays while the new one has nothing to show")
        #expect(stage.subviews.last === new && new.alphaValue == 0)
        new.showFirstFrame()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!stage.subviews.contains(old), "the old page goes once the new one has drawn")
        #expect(new.alphaValue == 1)
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
