import AppKit
import WebKit

// Every space's page ready before you get there.
//
// A launch brings back only the page on screen; every other space's tab comes
// back as a title and an address, and its page is fetched the moment you
// switch to it. So the first trip to each space after a launch landed on a
// blank stage and a load — the slide was quick, the space was not.
//
// Once the launch has settled (Fork/Launch.swift), the page the last space
// you were in would open on is loaded in the background: hung in a
// window off every screen that WebKit is told not to treat as hidden (a page
// loaded out of sight boots as a background tab, and some — x.com — then sit
// on their placeholder), and taken out again once it has loaded, so it rests
// like any tab you've left. A switch then puts a page already drawn on the
// stage. Those tabs are the spaces' remembered ones, which idle sleep leaves
// alone while the pages that may sleep fit their budget (Sleep.swift);
// memory pressure still puts them to sleep.
//
// Fork (idle-memory): only the last space, not every one. Warming all of them
// held a page per space all day (a Gmail nobody went to: 980 MB). The way back
// to the space you just left is the common trip; any other space's page
// starts the moment the pointer rests on its chip at the foot (`hover`), a
// few hundred milliseconds before the click.
//
// Not on battery saver, never in a headless run, and not at all with
// `defaults write <domain> spaces.warm -bool false`.
//
// Fork (pins-awake): the pins go first, loaded the same way, and none of
// those three stops them: a pin is never left without its page
// (Fork/PinsAwake.swift).
@MainActor
enum SpaceWarm {
    static var on: Bool { Store.settings.object(forKey: "spaces.warm") as? Bool ?? true }

    static func start(for browser: Browser) {
        guard browser.primary else { return }
        Launch.shared.whenSettled { [weak browser] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let browser else { return }
                PinsAwake.shared.start(in: browser) { [weak browser] in
                    guard let browser, let last else { return }
                    warm(space: last, in: browser)
                }
            }
        }
    }

    /// The space the first window was in before the one it is in now, kept
    /// across launches (Spaces.swap writes it).
    static var last: UUID? { Store.settings.string(forKey: "spaces.last").flatMap(UUID.init(uuidString:)) }

    static func left(_ space: UUID) { Store.settings.set(space.uuidString, forKey: "spaces.last") }

    /// The pointer came to rest on a space's chip (SpacesUI): its page starts now.
    static func hover(_ space: UUID, in browser: Browser) { warm(space: space, in: browser) }

    /// The landing tab being warmed now: one at a time.
    private static var warming: Tab.ID?

    /// The page `browser` would land on in `space`, loaded out of sight —
    /// unless it already has one, or is the space on screen.
    static func warm(space: UUID, in browser: Browser) {
        guard warming == nil, !Headless.on, on, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let spaces = Spaces.shared
        guard space != spaces.current(in: browser), let landing = spaces.wouldLand(in: space, for: browser),
              let tab = spaces.projection(space).first(where: { $0.id == landing }),
              tab.pending != nil, tab.built == nil, !tab.shy else { return }
        spaces.remember(tab.id, in: space, for: browser)
        warming = tab.id
        Breadcrumbs.note("space-warm", [("host", tab.pending?.host() ?? "-")])
        warm(tab, size: browser.active?.built?.bounds.size, start: { _ = tab.wake() }) { warming = nil }
    }

    /// One tab's page loaded out of sight: its view in the Room, `start` sets
    /// the load going (a wake; for a pin, a reload too), and once the page has
    /// loaded — or eight seconds on — the view leaves, so it rests like any
    /// tab you've left, unless a switch already put it on a stage. `done` a
    /// moment after.
    static func warm(_ tab: Tab, size: CGSize?, start: () -> Void, done: @escaping () -> Void) {
        let view = tab.web
        Room.park(view, size: size)
        start()
        let started = Date()
        // Fork (pins-awake): a load that has not said it started yet is not
        // a load that has finished — the view had only its last page's
        // address to show, and left the Room before the new one began.
        var began = false
        func check() {
            began = began || tab.loading
            let waited = Date().timeIntervalSince(started)
            if !tab.loading && tab.built?.url != nil && (began || waited > 1.5) || waited > 8 {
                Room.leave(view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
    }
}

/// A window off every screen where a page can load as if it were in view
/// before anyone looks at it: the restored tab at launch (Spaces.restore),
/// the other spaces' tabs after it (SpaceWarm). A web view outside any window
/// boots as a background tab — no painting, timers slowed, and some sites
/// (x.com) then sit on their placeholder — and one in a window off every
/// display counts as hidden too, so WebKit is told not to judge visibility by
/// occlusion while the view is here (WKWebViewPrivate; ignored where it is
/// gone). Wherever the view goes next — the stage takes it like any other —
/// WebKit judges it again (`moved`, from PageView).
@MainActor
enum Room {
    /// The room's class: a panel (see `make`).
    final class Panel: NSPanel {}

    private static var window: NSWindow?
    private static var parked = Set<ObjectIdentifier>()

    static func park(_ view: NSView, size: CGSize? = nil) {
        guard let web = view as? WKWebView else { return }
        // Before it moves in: WebKit decides whether the page is visible as
        // the view joins the window.
        web.detectsOcclusion(false)
        parked.insert(ObjectIdentifier(web))
        let room = window ?? make()
        let size = size.flatMap { $0.width > 100 ? $0 : nil } ?? NSSize(width: 1280, height: 800)
        if room.frame.size != size { room.setContentSize(size) }
        view.frame = NSRect(origin: .zero, size: size)
        room.contentView?.addSubview(view)
    }

    /// Out of the room, if it is still here.
    static func leave(_ view: NSView) {
        if view.window != nil, view.window === window { view.removeFromSuperview() }
        moved(view)
    }

    /// Here, now (Fork (page-capture): a call's page waits here while you are
    /// in another tab — Fork/Capture/CaptureCalls.swift).
    static func holds(_ view: NSView) -> Bool {
        parked.contains(ObjectIdentifier(view)) && view.window != nil && view.window === window
    }

    /// The view left for somewhere else (or nowhere): occlusion counts again.
    /// The last one out takes the room down with it — an ordered-in window,
    /// even one off every screen, would count as a visible window to AppKit.
    static func moved(_ view: NSView) {
        // Fork (page-capture): after the room has had its say, a call's page
        // is kept seen wherever it went (Fork/Capture/CaptureCalls.swift).
        defer { if let web = view as? WKWebView { CaptureCalls.shared.moved(web) } }
        guard !parked.isEmpty, let web = view as? WKWebView, web.window == nil || web.window !== window,
              parked.remove(ObjectIdentifier(web)) != nil else { return }
        web.detectsOcclusion(true)
        if parked.isEmpty {
            window?.orderOut(nil)
            window = nil
        }
    }

    /// Off every screen, never key or main, behind everything, never in the
    /// window list (Bench's room, the same shape).
    ///
    /// A panel, not a window: the room goes up while the first browser is
    /// built, inside SwiftUI's will-finish-launching — before AppKit decides
    /// whether to open the first window. AppKit opens none when the app
    /// already has a window ordered in, and leaves panels out of that
    /// question (and out of the Dock click's "a window is showing"). As a
    /// plain NSWindow the room made every launch without saved window state
    /// — after ⌘Q, after an update — come up with no browser window
    /// (Fork/LaunchWatchdog.swift).
    private static func make() -> NSWindow {
        let room = built()
        room.orderBack(nil)
        window = room
        return room
    }

    /// The room, made and not yet ordered in (Tests: LaunchWindowTests).
    static func built() -> NSWindow {
        let room = Panel(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        // A panel hides when its app stops being active; a room never does,
        // or its page would turn hidden the moment you look elsewhere.
        room.hidesOnDeactivate = false
        room.isReleasedWhenClosed = false
        room.isExcludedFromWindowsMenu = true
        room.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        room.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        room.hasShadow = false
        room.ignoresMouseEvents = true
        return room
    }
}

extension WKWebView {
    private static let occlusionSetter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")

    /// Off, a page warmed in a window off every screen loads as if it were
    /// in view (WebKit's own switch, WKWebViewPrivate; ignored where it is
    /// gone). Set before the view joins that window: WebKit works out whether
    /// the page is visible as it moves in.
    func detectsOcclusion(_ on: Bool) {
        guard responds(to: WKWebView.occlusionSetter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: WKWebView.occlusionSetter), to: Setter.self)(self, WKWebView.occlusionSetter, on)
    }
}
