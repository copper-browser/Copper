import AppKit

// Copper running, in front, and no browser window: never a state to be stuck in.
//
// How a launch used to end up there (October 2026, v1.0.20261020.66 on
// macOS 27; taken apart with lldb on a probe and reproduced with one):
//
// 1. A release build is linked against the macOS 15 SDK, so SwiftUI shows the
//    first `Window` scene at launch only when AppKit asks it to — the launch's
//    open-application event, handled in `-[NSApplication _handleAEOpenEvent:]`,
//    calls `_doOpenUntitled`, which reaches SwiftUI's
//    `applicationOpenUntitledFile`. (Against an older SDK SwiftUI also shows it
//    from its own `applicationDidFinishLaunching`. `./build.sh` stamps the
//    binary as built against macOS 14, so development and probe builds took
//    that path and never showed the bug.)
// 2. AppKit skips `_doOpenUntitled` when nothing was restored and the app
//    already has a window open (`_appHasOpenNSWindow`: any NSWindow ordered
//    in, wherever it is — but not an NSPanel); and also when there is window
//    state to restore and the launch did not activate the app (a background
//    launch), leaving the window to restoration, which then sometimes brought
//    none back.
// 3. Copper's first browser is built inside SwiftUI's
//    `applicationWillFinishLaunching` (the app's `@StateObject`), and building
//    it restores the session and starts the restored page in the `Room`
//    (Fork/SpaceWarm.swift), a window ordered in off every screen — before the
//    open event is handled. A clean quit (⌘Q, or the updater's relaunch)
//    leaves no saved window state to restore, so: no window, every time.
// 4. Nothing brought one back: the Dock click, the Dock menu and ⌘N all went
//    through the first window's own `openWindow`, which only exists once that
//    window has appeared; and with an agent's page hung in the Backstage room,
//    AppKit told the Dock click a window was showing.
//
// The rooms are panels now (AppKit leaves panels out of that question), every
// way back opens the first window when none was ever made (Fork/Windows.swift
// `openFirst`), and this watches the launch itself: a moment after AppKit says
// the launch is done, and again a little later, a run that is not headless and
// has not had a browser window on a screen yet asks SwiftUI for one — the same
// call a link from another app makes (Links `summon`) — and says so in the
// trail (`launch-watchdog …`). Nothing is activated: a launch in the
// background stays in the background.
@MainActor
enum LaunchWatchdog {
    /// What a look at the launch decided.
    enum Verdict: Equatable {
        /// Headless: the browser keeps its parked window, and nobody looks.
        case headless
        /// Quitting: a window now would only be closed again.
        case terminating
        /// The app is hidden; it looks again when it is shown.
        case hidden
        /// A browser window has been on screen this run (seen by an earlier
        /// look). Closing it with the red button is the person's choice, and
        /// stays theirs.
        case shown
        /// Asked for one a moment ago; it is on its way.
        case waiting
        /// No browser window, ever: open the first one.
        case open
    }

    /// The decision, apart from AppKit so it can be tested.
    nonisolated static func verdict(headless: Bool, terminating: Bool, hidden: Bool,
                                    everShown: Bool, askedRecently: Bool) -> Verdict {
        if headless { return .headless }
        if terminating { return .terminating }
        if everShown { return .shown }
        if hidden { return .hidden }
        if askedRecently { return .waiting }
        return .open
    }

    /// Seconds after AppKit's did-finish-launching: the first look, and the
    /// one that catches a slow first window (or a first try that did nothing).
    /// A test world may set `COPPER_LAUNCH_WATCHDOG_DELAY` to move the first.
    static var delays: [TimeInterval] {
        if Store.testing, let raw = ProcessInfo.processInfo.environment["COPPER_LAUNCH_WATCHDOG_DELAY"],
           let first = TimeInterval(raw), first >= 0 {
            return [first, first + 3.5]
        }
        return [1.5, 5]
    }

    private static var armed = false
    private static var disabled = false
    private static var launched = false
    private static var asked: Date?
    /// What the last look decided, for the bench.
    private(set) static var last: (verdict: Verdict, why: String, at: Date)?
    private static var tokens: [NSObjectProtocol] = []

    /// A real app launch (Fork/MCP/Bridge.swift `runIfAsked`), before
    /// AppKit has finished launching.
    static func arm() {
        guard !armed else { return }
        armed = true
        guard !Headless.on else { return }
        TestSeam.blockLaunchWindowIfAsked()
        // A test world can turn the watchdog off to see the other ways back
        // work on their own (docs/fixtures/launch-window-e2e.sh).
        if Store.testing, ProcessInfo.processInfo.environment["COPPER_LAUNCH_WATCHDOG"] == "off" {
            disabled = true
            return
        }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                launched = true
                for delay in delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        check("after-\(format(delay))s")
                    }
                }
            }
        })
        // Hidden at launch (`open -j`), or the first window never came and
        // the person brought Copper forward some other way than the Dock.
        for name in [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Not before the launch's own first look: the first window
                    // may simply not be up yet.
                    guard launched, last != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        check(name == NSApplication.didUnhideNotification ? "unhidden" : "activated")
                    }
                }
            })
        }
    }

    /// A browser window has been seen on a screen (or in the Dock) by one
    /// of these looks. Seen, not merely made: a window SwiftUI built and
    /// never ordered in is no window to the person in front of the Mac.
    private static var seen = false

    /// A browser window closed (Fork/Windows.swift `attach`): it was there,
    /// and closing it — however soon after the launch — was someone's choice.
    static func windowClosed() { seen = true }

    /// One look. Opens the first window when nothing has ever shown one.
    static func check(_ why: String) {
        if Windows.anyShowing || Windows.anyDocked { seen = true }
        let verdict = verdict(headless: Headless.on, terminating: Windows.quitting, hidden: NSApp.isHidden,
                              everShown: seen,
                              askedRecently: asked.map { Date().timeIntervalSince($0) < 1.2 } ?? false)
        last = (verdict, why, Date())
        guard verdict == .open else { return }
        asked = Date()
        let rooms = NSApp.windows.filter { $0.isVisible && Windows.owner(of: $0) == nil }.count
        Breadcrumbs.note("launch-watchdog", [("check", why), ("browser-windows", "0"), ("other-windows", String(rooms)),
                                             ("action", "opened-first-window")])
        Windows.openFirst("launch-watchdog")
    }

    private static func format(_ delay: TimeInterval) -> String {
        delay == delay.rounded() ? String(Int(delay)) : String(format: "%.1f", delay)
    }

    /// `./bench windows watchdog`.
    static var report: [String: Any] {
        var out: [String: Any] = ["armed": armed && !disabled && !Headless.on, "launched": launched, "seen": seen,
                                  "everAttached": Windows.everAttached,
                                  "delays": delays]
        if let last {
            out["last"] = ["verdict": "\(last.verdict)", "check": last.why,
                           "secondsAgo": Int(Date().timeIntervalSince(last.at))]
        }
        return out
    }
}

extension LaunchWatchdog {
    /// For end-to-end tests of the way back (docs/fixtures/launch-window-e2e.sh),
    /// in a test world only: `COPPER_TEST_BLOCK_LAUNCH_WINDOW=1` orders an
    /// ordinary window in off every screen before AppKit decides on the first
    /// window — exactly what the Room used to do — and leaves it up, the way
    /// an agent's Backstage room stays up, so a Dock click arrives saying a
    /// window is showing; `=brief` takes it down a second after the launch,
    /// so one arrives saying none is. It never runs in the browser somebody uses.
    @MainActor
    enum TestSeam {
        private static var decoy: NSWindow?
        private static var token: NSObjectProtocol?

        static func blockLaunchWindowIfAsked() {
            let asked = ProcessInfo.processInfo.environment["COPPER_TEST_BLOCK_LAUNCH_WINDOW"]
            guard Store.testing, asked == "1" || asked == "brief" else { return }
            if asked == "brief" {
                token = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                                               object: nil, queue: .main) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated { decoy?.orderOut(nil) }
                    }
                }
            }
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.ignoresMouseEvents = true
            window.title = "Copper test decoy"
            window.orderBack(nil)
            decoy = window
            Updates.note("test seam: a decoy window is up before launch, so AppKit opens no first window")
        }
    }
}
