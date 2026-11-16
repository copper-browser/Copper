import AppKit
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

// What a page reads as window.outerWidth/outerHeight (Fork/WindowFrame.swift).
// WebKit says 0×0 when the UI delegate doesn't answer, and bot checks
// (FingerprintJS BotD, behind PyPI's Client Challenge) call a focused 0×0
// window a headless browser.

@Test func windowFrameIsThePagesWindowThenItsBrowsersThenTheScreen() {
    let page = CGRect(x: 10, y: 20, width: 1200, height: 800)
    let browser = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    #expect(WindowFrame.frame(page: page, browser: browser, screen: screen) == page)
    // Off stage (a background tab, or hung backstage for an agent): its browser's window.
    #expect(WindowFrame.frame(page: nil, browser: browser, screen: screen) == browser)
    #expect(WindowFrame.frame(page: .zero, browser: browser, screen: screen) == browser)
    #expect(WindowFrame.frame(page: nil, browser: nil, screen: screen) == screen)
    // Never the empty frame.
    let none = WindowFrame.frame(page: nil, browser: nil, screen: nil)
    #expect(none.width > 0 && none.height > 0)
}

@MainActor @Test func browserAnswersWebKitsWindowFrameQuestion() {
    // Unanswered, WebKit tells the page 0×0; the selector must be exactly WebKit's.
    #expect(Browser.instancesRespond(to: NSSelectorFromString("_webView:getWindowFrameWithCompletionHandler:")))
}
