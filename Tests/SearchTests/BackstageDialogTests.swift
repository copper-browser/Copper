import AppKit
import Testing
import WebKit
@testable import Search

// A page hung backstage asks nobody (Dialogs.unattended, Fork/MCP/Backstage.swift):
// a sheet on that off-screen window made AppKit pull it, the agent's page with
// it, onto the display, and again on every Space switch.

@MainActor @Test func aBackstagePageIsDeclinedWithoutASheet() {
    _ = NSApplication.shared
    let window = Backstage.built()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = web
    #expect(Dialogs.unattended(web))

    var answer: NSApplication.ModalResponse?
    Dialogs.show(NSAlert(), over: web) { answer = $0 }
    #expect(answer == .abort, "declined at once, as headless Copper declines")
    #expect(window.attachedSheet == nil, "no sheet on the backstage window")
}

@MainActor @Test func aPageElsewhereIsNotBackstage() {
    #expect(!Dialogs.unattended(WKWebView(frame: .zero)))
    let plain = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    plain.isReleasedWhenClosed = false
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    plain.contentView = web
    #expect(!Dialogs.unattended(web))
}
