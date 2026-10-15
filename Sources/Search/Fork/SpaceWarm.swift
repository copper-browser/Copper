import AppKit
import WebKit

// Every space's page ready before you get there.
//
// A launch brings back only the page on screen; every other space's tab comes
// back as a title and an address, and its page is fetched the moment you
// switch to it. So the first trip to each space after a launch landed on a
// blank stage and a load — the slide was quick, the space was not.
//
// Once the launch has settled (Fork/Launch.swift), the page each other space
// would open on is loaded in the background, one space at a time: hung in a
// window off every screen that WebKit is told not to treat as hidden (a page
// loaded out of sight boots as a background tab, and some — x.com — then sit
// on their placeholder), and taken out again once it has loaded, so it rests
// like any tab you've left. A switch then puts a page already drawn on the
// stage. Those tabs are the spaces' remembered ones, which idle sleep leaves
// alone (Sleep.swift); memory pressure still puts them to sleep.
//
// Not on battery saver, never in a headless run, and not at all with
// `defaults write <domain> spaces.warm -bool false`.
@MainActor
enum SpaceWarm {
    static var on: Bool { Store.settings.object(forKey: "spaces.warm") as? Bool ?? true }

    static func start(for browser: Browser) {
        guard browser.primary, !Headless.on, on else { return }
        Launch.shared.whenSettled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak browser] in
                guard let browser, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
                let spaces = Spaces.shared
                let here = spaces.current(in: browser)
                let waiting = spaces.all.map(\.id).filter { $0 != here }.compactMap { id -> (UUID, Tab)? in
                    guard let landing = spaces.wouldLand(in: id, for: browser),
                          let tab = spaces.projection(id).first(where: { $0.id == landing }),
                          tab.pending != nil, !tab.shy else { return nil }
                    return (id, tab)
                }
                next(waiting, in: browser)
            }
        }
    }

    private static func next(_ waiting: [(UUID, Tab)], in browser: Browser) {
        guard let (space, tab) = waiting.first else { return }
        let rest = Array(waiting.dropFirst())
        // Gone, woken or put on a stage since the list was made: skip it.
        guard tab.pending != nil, tab.built == nil, Spaces.shared.current(in: browser) != space else {
            return next(rest, in: browser)
        }
        Spaces.shared.remember(tab.id, in: space, for: browser)
        let view = tab.web
        Room.park(view, size: browser.active?.built?.bounds.size)
        _ = tab.wake()
        let started = Date()
        func check() {
            if !tab.loading && tab.built?.url != nil || Date().timeIntervalSince(started) > 8 {
                // It rests like any tab you've left — unless a switch already
                // put it on a stage.
                Room.leave(view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next(rest, in: browser) }
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

    /// The view left for somewhere else (or nowhere): occlusion counts again.
    /// The last one out takes the room down with it — an ordered-in window,
    /// even one off every screen, would count as a visible window to AppKit.
    static func moved(_ view: NSView) {
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
    private static func make() -> NSWindow {
        let room = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        room.isReleasedWhenClosed = false
        room.isExcludedFromWindowsMenu = true
        room.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        room.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        room.hasShadow = false
        room.ignoresMouseEvents = true
        room.orderBack(nil)
        window = room
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
