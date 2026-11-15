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
// Fork (switch, hill-climb r4): no longer every other space after it. That
// held +52 MB and +13 wakeups/s at idle and measured no faster switch (A2).
// A page is warmed on intent instead: the pointer resting on a chip
// (`hover`), a swipe setting off towards a space (SpaceSlide), ⌃ going down
// (`control`: ⌃1–9 and ⌃⌥←/→ switch spaces) for the spaces either side. And
// a page warmed for a space you then don't go to — the last space's too —
// is put back to sleep a minute on (`cool`), so a guess that came to
// nothing costs nothing for long.
//
// Fork (covers, hill-climb r5): ⌃ warms at once — a quick ⌃2 came down
// before the 200 ms hold was up, so it warmed nothing — and a guess that is
// plainly wrong is taken back: any key with ⌃ that is not a space key (⌃A,
// ⌃E, ⌃⇥) stops the queue and puts the page being warmed back to sleep. With
// the caret in a text field — the address field, a box on the page — ⌃ is
// for the field (⌃A, ⌃E, ⌃K) and warms nothing; and no guess is made while
// the pages that may sleep already hold half their byte budget (`roomy`).
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
        Covers.start() // Fork (covers): pictures kept at quit
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

    /// Fork (switch): ⌃ went down (or up) in `browser`'s window. ⌃1–9 and
    /// ⌃⌥←/→ are the space keys, so ⌃ going down with no tab walk (⌃⇥)
    /// under way warms the spaces either side, one after the other.
    /// Fork (covers): at once, not after 200 ms; never with the caret in a
    /// text field, nor without room (`ControlIntent`).
    static func control(_ down: Bool, in browser: Browser, window: NSWindow? = nil) {
        let act = intent.flags(control: down, typing: down && typing(in: browser, window: window),
                               walking: Recent.shared.walking, roomy: down && roomy)
        if act == .warm { sides(of: browser, guess: true) }
    }

    /// Fork (covers): a key went down in `browser`'s window. With ⌃ held,
    /// anything but a space key takes the guess back.
    static func key(_ event: NSEvent, in browser: Browser) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard intent.key(space: ControlIntent.spaceKey(event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                                       option: flags.contains(.option))) == .cancel else { return }
        cancel()
    }

    /// Fork (covers): what ⌃ means now.
    private static var intent = ControlIntent()

    /// Fork (covers): the caret is in a text field — Copper's own (the
    /// field editor of the address field, ⌘K, a rename) or one on the page.
    static func typing(in browser: Browser, window: NSWindow?) -> Bool {
        if browser.active?.typing == true { return true }
        return (window ?? NSApp.keyWindow)?.firstResponder is NSText
    }

    /// Fork (space-perf → covers): the pages that may sleep (every loaded
    /// page but the pins) hold less than half their byte budget between them.
    static var roomy: Bool {
        var pids = Set<pid_t>()
        let bytes = Spaces.shared.everyTab.filter { $0.pin == nil && $0.built != nil && !$0.asleep }.reduce(UInt64(0)) { sum, tab in
            guard let weight = Heat.shared.weight(of: tab), pids.insert(weight.pid).inserted else { return sum }
            return sum + weight.bytes
        }
        return bytes < Browser.footprintBudget / 2
    }

    /// The spaces either side of the one `browser` is in.
    static func sides(of browser: Browser, guess: Bool = false) {
        let all = Spaces.shared.all
        guard all.count > 1, let here = all.firstIndex(where: { $0.id == Spaces.shared.current(in: browser) }) else { return }
        round += 1
        guessing = guess ? round : nil
        next([all[(here + 1) % all.count].id, all[(here + all.count - 1) % all.count].id], in: browser, round: round)
    }

    /// Fork (covers): each queue of spaces is a round; a newer one, or a
    /// guess taken back, ends the one before.
    private static var round = 0
    /// Fork (covers): the round ⌃ started, while it may still be taken back.
    private static var guessing: Int?

    /// Fork (covers): the ⌃ guess was wrong. Its queue stops, and the page
    /// it is warming now goes back to sleep — unless you went to it.
    private static func cancel() {
        guard let mine = guessing else { return }
        guessing = nil
        if round == mine { round += 1 }
        guard let id = warming, let tab = AgentTabs.all.first(where: { $0.id == id }), !tab.asleep, tab.built != nil,
              !Windows.all.contains(where: { $0.activeID == id }) else { return }
        Breadcrumbs.note("space-warm", [("cancelled", tab.address?.host() ?? "-")])
        tab.sleep(picture: nil)
    }

    /// The landing tab being warmed now: one at a time.
    private static var warming: Tab.ID?

    /// The spaces' landing tabs in `queue`, one after another — while the
    /// round is the current one (Fork: covers).
    private static func next(_ queue: [UUID], in browser: Browser, round mine: Int) {
        guard mine == round, let space = queue.first else { return }
        let rest = Array(queue.dropFirst())
        if !warm(space: space, in: browser, then: { [weak browser] in if let browser { next(rest, in: browser, round: mine) } }) {
            next(rest, in: browser, round: mine)
        }
    }

    /// Fork (switch): when each warmed page's latest warm-up started.
    private static var warmed: [Tab.ID: Date] = [:]

    /// Fork (switch): how long a warmed page waits for its space before it
    /// goes back to sleep (`defaults write <domain> spaces.warm.cool <s>`).
    static var cool: TimeInterval {
        let set = Store.settings.double(forKey: "spaces.warm.cool")
        return set > 0 ? set : 60
    }

    /// The page `browser` would land on in `space`, loaded out of sight —
    /// unless it already has one, or is the space on screen. False when
    /// there was nothing to warm (`then` is not called).
    @discardableResult
    static func warm(space: UUID, in browser: Browser, then: (() -> Void)? = nil) -> Bool {
        guard warming == nil, !Headless.on, on, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        let spaces = Spaces.shared
        guard space != spaces.current(in: browser), let landing = spaces.wouldLand(in: space, for: browser),
              let tab = spaces.projection(space).first(where: { $0.id == landing }),
              tab.pending != nil, tab.built == nil, !tab.shy else { return false }
        spaces.remember(tab.id, in: space, for: browser)
        let id = tab.id
        warming = id
        let looked = tab.touched, at = Date()
        warmed[tab.id] = at
        Breadcrumbs.note("space-warm", [("host", tab.pending?.host() ?? "-")])
        warm(tab, size: browser.active?.built?.bounds.size, start: { _ = tab.wake() }) { [weak browser, weak tab] in
            if warming == id { warming = nil }
            if let browser, let tab { cooling(tab, unless: looked, since: at, in: browser) }
            then?()
        }
        return true
    }

    /// Fork (switch): a warmed page nobody went to within `cool` goes back
    /// to sleep (Browser.sleep: never one on screen, holding something typed,
    /// or kept awake for any other reason). Looking at it touches it, which
    /// lets it stay.
    private static func cooling(_ tab: Tab, unless looked: Date, since at: Date, in browser: Browser) {
        DispatchQueue.main.asyncAfter(deadline: .now() + cool) { [weak browser, weak tab] in
            // Only the clock of the page's latest warm-up: one put to sleep and warmed again starts over.
            guard let tab, warmed[tab.id] == at else { return }
            warmed[tab.id] = nil
            guard let browser, tab.touched == looked, !tab.asleep, tab.built != nil else { return }
            Breadcrumbs.note("space-warm", [("cooled", tab.address?.host() ?? "-")])
            browser.sleep(tab)
        }
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
            // Fork (covers): or put back to sleep meanwhile (a ⌃ guess taken back).
            if !tab.loading && tab.built?.url != nil && (began || waited > 1.5) || waited > 8 || tab.asleep {
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

/// Fork (covers): what ⌃ does to the warming guess. Pure, so the tests can
/// say it. ⌃ going down warms at once — unless the caret is in a text field
/// (⌃A, ⌃E, ⌃K are the field's), a tab walk (⌃⇥) is under way, or the pages
/// that may sleep have no room. While ⌃ is held, a key that is not a space
/// key takes the guess back.
struct ControlIntent: Equatable {
    enum Act: Equatable { case none, warm, cancel }

    private(set) var held = false
    /// A guess made by this ⌃ and not yet taken back.
    private(set) var guessed = false

    mutating func flags(control: Bool, typing: Bool, walking: Bool, roomy: Bool) -> Act {
        guard control != held else { return .none }
        held = control
        guard control, !typing, !walking, roomy else {
            guessed = false
            return .none
        }
        guessed = true
        return .warm
    }

    mutating func key(space: Bool) -> Act {
        guard held, guessed, !space else { return .none }
        guessed = false
        return .cancel
    }

    /// ⌃1–9 and ⌃⌥←/→ (keyCodes 123, 124).
    static func spaceKey(_ characters: String, keyCode: UInt16, option: Bool) -> Bool {
        if let digit = Int(characters), (1...9).contains(digit), characters.count == 1 { return true }
        return option && (keyCode == 123 || keyCode == 124)
    }
}
