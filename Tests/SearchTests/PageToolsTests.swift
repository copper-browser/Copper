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
