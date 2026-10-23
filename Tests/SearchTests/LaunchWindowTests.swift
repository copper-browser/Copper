import AppKit
import Testing
@testable import Search

// No launch without a browser window (Fork/LaunchWatchdog.swift).
//
// AppKit opens a SwiftUI app's first window at launch only when the app has
// no window open yet, and the rooms Copper parks pages in go up before that
// decision. They are panels so AppKit leaves them out; these pin both halves
// of that, and the watchdog's own rule.

@Test func watchdogOpensTheFirstWindowWhenNoneWasEverShown() {
    #expect(LaunchWatchdog.verdict(headless: false, terminating: false, hidden: false, everShown: false, askedRecently: false) == .open)
}

@Test func watchdogNeverActsHeadless() {
    // The parked window is Fork/Headless.swift's, and nobody is looking.
    #expect(LaunchWatchdog.verdict(headless: true, terminating: false, hidden: false, everShown: false, askedRecently: false) == .headless)
    #expect(LaunchWatchdog.verdict(headless: true, terminating: false, hidden: true, everShown: false, askedRecently: true) == .headless)
}

@Test func watchdogLeavesAWindowThePersonClosedClosed() {
    // A window came up and the red button took it away: their choice.
    #expect(LaunchWatchdog.verdict(headless: false, terminating: false, hidden: false, everShown: true, askedRecently: false) == .shown)
    #expect(LaunchWatchdog.verdict(headless: false, terminating: false, hidden: true, everShown: true, askedRecently: false) == .shown)
}

@Test func watchdogWaitsWhileQuittingHiddenOrAlreadyAsking() {
    #expect(LaunchWatchdog.verdict(headless: false, terminating: true, hidden: false, everShown: false, askedRecently: false) == .terminating)
    // Hidden at launch: it looks again when the app is shown.
    #expect(LaunchWatchdog.verdict(headless: false, terminating: false, hidden: true, everShown: false, askedRecently: false) == .hidden)
    // Asked a moment ago: never a second ask on top of the first.
    #expect(LaunchWatchdog.verdict(headless: false, terminating: false, hidden: false, everShown: false, askedRecently: true) == .waiting)
}

@Test func roomsAreNSPanels() {
    // AppKit's "does the app have a window open" leaves NSPanels out.
    #expect(Room.Panel.self is NSPanel.Type)
    #expect(Backstage.Window.self is NSPanel.Type)
}

/// AppKit's own answer (`-[NSApplication _appHasOpenNSWindow]`, what the launch's
/// open event and the Dock click both ask) with one of the rooms ordered in.
/// Nil when this macOS has no such method — the test then has nothing to say.
@MainActor private func appHasOpenWindow(with window: NSWindow) -> Bool? {
    let app = NSApplication.shared
    let selector = NSSelectorFromString("_appHasOpenNSWindow")
    guard app.responds(to: selector) else { return nil }
    typealias Ask = @convention(c) (AnyObject, Selector) -> Bool
    let ask = unsafeBitCast(app.method(for: selector), to: Ask.self)
    let before = ask(app, selector)
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    guard window.isVisible else { return nil }
    return before || ask(app, selector)
}

@MainActor @Test func appKitDoesNotCountTheRoomsAsOpenWindows() throws {
    _ = NSApplication.shared
    // The question means something: an ordinary window off every screen counts.
    let plain = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    plain.isReleasedWhenClosed = false
    guard let counted = appHasOpenWindow(with: plain) else { return }
    #expect(counted, "an ordinary off-screen window is an open window to AppKit")

    let room = Room.built()
    #expect(room.hidesOnDeactivate == false, "a room must not hide when Copper stops being active")
    #expect(appHasOpenWindow(with: room) == false, "the Room (SpaceWarm) must not count as an open window")

    let backstage = Backstage.built()
    #expect(backstage.hidesOnDeactivate == false, "Backstage must not hide when Copper stops being active")
    #expect(appHasOpenWindow(with: backstage) == false, "the Backstage room must not count as an open window")
}
