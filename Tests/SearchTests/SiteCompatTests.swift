import Foundation
import Testing
@testable import Search

// Fork (sites): what Copper tells websites it is. Same WebKit as the Safari on
// this Mac, so it says Safari's version too; a stale one reads as an older
// browser to sites that sniff it (perf/hillclimb/sites on hc/harness).

@Test func userAgentNamesTheSafariOnThisMac() {
    #expect(Web.agentName(safari: "27.0.1") == "Version/27.0.1 Safari/605.1.15")
    #expect(Web.agentName(safari: "26.6") == "Version/26.6 Safari/605.1.15")
    // No Safari, or a version that isn't one: the last known-good name.
    #expect(Web.agentName(safari: nil) == "Version/26.5 Safari/605.1.15")
    #expect(Web.agentName(safari: "27.0 (beta)") == "Version/26.5 Safari/605.1.15")
    #expect(Web.agentName(safari: "") == "Version/26.5 Safari/605.1.15")
}

@Test func userAgentMatchesTheInstalledSafari() {
    let safari = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    guard let safari else { return }
    #expect(Web.userAgentName == "Version/\(safari) Safari/605.1.15")
}
