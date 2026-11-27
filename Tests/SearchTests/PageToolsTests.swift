import Foundation
import Testing
@testable import Search

// A page tool's failure reaches the agent as its own words: MCP.handle shows
// `localizedDescription` for anything that isn't a Tools.Failure, which for a
// plain Error was "Search.Tools.Page.Failure error 1". The behaviour end to
// end: docs/fixtures/page-tools-e2e.py.

@Test func pageAndToolFailuresSayTheirText() {
    let page: Error = Tools.Page.Failure(text: "JavaScript: Error: pt-boom-17")
    #expect(page.localizedDescription == "JavaScript: Error: pt-boom-17")
    let tool: Error = Tools.Failure(text: "Timed out after 15 s")
    #expect(tool.localizedDescription == "Timed out after 15 s")
}

@Test func theHelperCarriesNoConsoleShim() {
    // The recorder wraps the page's own console, so it goes into the page's
    // world on its own (Page.js); the helper lives in Copper's and holds no logs.
    #expect(!Tools.Page.helper.contains("__copperLogs"))
    #expect(Tools.Page.consoleShim.contains("window.__copperLogs"))
}

@Test func pressKeyKnowsItsKeyNames() {
    for good in ["Enter", "tab", "ArrowDown", "F5", "a", "Z", "+", "Shift+Tab", "Meta+a", "Control+Shift+K"] {
        #expect(Input.known(good), "\(good)")
    }
    // Typed out as text before: an error now, so the agent learns the name is wrong.
    for bad in ["NotAKey", "Enterr", "Foo+a", "Shift+NotAKey", "ab"] {
        #expect(!Input.known(bad), "\(bad)")
    }
}

@MainActor @Test func toolsListStaysUnderItsBudget() throws {
    // What a loopback agent pays at the start of every session (MCP tools/list):
    // < 6.25k tokens at ~4 bytes a token, ≤ 8k once a canvas is in use and the
    // canvas tools are listed too (CanvasTools.listed). One-line descriptions;
    // canvas_apply's op shapes ride on the first canvas_read (CanvasTools.opsGuide).
    // 24k until browser_take_screenshot took elements, regions and scale
    // (~0.9k, its schema shared word for word with Copper for Linux and Windows).
    // 25.5k since browser_read (~0.5k), which saves a planner ~1.7 turns a page;
    // 26.1k since its search (~0.3k), one search round in one call.
    let extra = [CloudHistoryTool.schema] + VoiceTools.catalogue
    let bare = Tools.listed(Tools.offered(jev: true, canvas: false) + extra)
    let all = Tools.listed(Tools.offered(jev: true, canvas: true) + extra)
    let bareBytes = try JSONSerialization.data(withJSONObject: bare).count
    let bytes = try JSONSerialization.data(withJSONObject: all).count
    #expect(bareBytes < 26_100, "tools/list with no canvas is \(bareBytes) bytes")
    #expect(bytes <= 32_000, "tools/list is \(bytes) bytes")
    #expect(!all.contains { ($0["inputSchema"] as? [String: Any])?["required"].map { ($0 as? [Any])?.isEmpty == true } == true })
    for name in ["browser_mouse_click_xy", "browser_handoff", "browser_permissions", "canvas_apply"] {
        #expect(all.contains { $0["name"] as? String == name }, "\(name)")
    }
    let canvas = Set(bare.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("canvas_") })
    #expect(canvas == CanvasTools.doors)
    #expect(CanvasTools.opsGuide.contains("op:'connect'"))
}
