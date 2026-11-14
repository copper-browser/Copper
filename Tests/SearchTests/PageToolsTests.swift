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

@Test func theHelperKeepsTheConsoleShimItsOwnLoadTimeCopyUses() {
    // The helper starts from the same shim agent tabs get at document start,
    // so a page that already has it keeps the logs from its load.
    #expect(Tools.Page.helper.hasPrefix(Tools.Page.consoleShim))
    #expect(Tools.Page.helper.contains("var logs = window.__copperLogs;"))
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
    // ≤ 8k tokens at ~4 bytes a token. One-line descriptions; canvas_apply's
    // op shapes ride on the first canvas_read instead (CanvasTools.opsGuide).
    let all = Tools.listed(Tools.catalogue(jev: true) + [CloudHistoryTool.schema] + VoiceTools.catalogue)
    let bytes = try JSONSerialization.data(withJSONObject: all).count
    #expect(bytes <= 32_000, "tools/list is \(bytes) bytes")
    #expect(!all.contains { ($0["inputSchema"] as? [String: Any])?["required"].map { ($0 as? [Any])?.isEmpty == true } == true })
    for name in ["browser_mouse_click_xy", "browser_handoff", "browser_permissions", "canvas_apply"] {
        #expect(all.contains { $0["name"] as? String == name }, "\(name)")
    }
    #expect(CanvasTools.opsGuide.contains("op:'connect'"))
}
