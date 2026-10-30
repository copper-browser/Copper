import AppKit
import WebKit

// Agents work in tabs you are not looking at, and never take your attention.
//
// Two parts.
//
// AgentTabs is which tab a call lands on. A tool used to act on the tab on
// your screen, so an agent that wanted a page of its own had to bring it to
// the front — switching your tab under you. Now each agent session (Drive.Who
// key, stable across a thread's CLI calls and MCP requests) can hold a tab of
// its own: the one it opened with browser_tabs new / jev_run newTab, or chose
// with browser_tabs select. Its calls land there wherever you are; an agent
// with no tab of its own still works on the one you are looking at, as
// before. Any call can name a tab outright with `tab` (an id from
// browser_tabs list, or an index).
//
// Backstage is how a tab nobody is looking at can still be seen. A page in a
// tab off screen has no window: WebKit stops painting it, rAF stops,
// `document.hidden` turns true, screenshots come back blank and real clicks
// have nowhere to go. So while an agent is using such a tab, its web view is
// hung in one borderless window outside every display — ordered in, so WebKit
// lays it out and paints it, with occlusion detection off so the page counts
// as visible (the same trick as Headless's parking, for one window). The
// window says it is key without ever becoming key: WebKit then treats the page
// as focused (caret, focus events, `document.hasFocus()`) while your real key
// window, your keyboard and your app focus are untouched. Choosing the tab
// yourself takes its view to your stage the ordinary way; leaving it puts it
// back here while the agent is still at it. A held page ignores occlusion
// wherever it is, so one in your window behind another app is visible to the
// agent too. A few minutes after the agent's
// last call the page lets go and is an ordinary background tab again — free
// to sleep.

@MainActor
enum AgentTabs {
    /// The tab the call being served works on, set from its `tab` argument.
    @TaskLocal static var pinned: UUID?

    /// The call being booked opens a tab behind the user's: nothing about it
    /// is announced over, or opens a pane beside, the page on screen.
    @TaskLocal static var behind = false

    /// browser_tabs new and jev_run newTab, unless asked to show the tab.
    nonisolated static func opensBehind(_ name: String, _ args: [String: Any]) -> Bool {
        if (args["focus"] as? Bool) == true { return false }
        switch name {
        case "browser_tabs": return (args["action"] as? String) == "new"
        case "jev_run": return (args["newTab"] as? Bool) == true
        default: return false
        }
    }

    /// Each agent session's own tab, by `Drive.Who.key`.
    private(set) static var bound: [String: UUID] = [:]

    /// The pane beside the page asks about what you are looking at; it never
    /// keeps a tab of its own.
    private static func binds(_ key: String?) -> Bool { key != nil && key != "pane" }

    nonisolated static var callerKey: String? { DriveCaller.who?.key }

    /// Every tab in every window and space, once each.
    static var all: [Tab] {
        var seen = Set<Tab.ID>()
        return (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs).filter { seen.insert($0.id).inserted }
    }

    static func find(_ id: UUID?) -> Tab? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The short id browser_tabs list prints.
    static func short(_ tab: Tab) -> String { String(tab.id.uuidString.prefix(8)).lowercased() }

    /// A `tab` argument: an id (short or whole) or an index in this window's
    /// row. A JSON number is an index; a string is read by `reading`.
    static func resolve(_ ref: Any?, in browser: Browser) throws -> Tab? {
        guard let ref else { return nil }
        // A JSON number. (`is Bool` would also take 0 and 1: NSNumber bridges.)
        if let n = ref as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return try at(n.intValue, in: browser)
        }
        guard let raw = (ref as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        let tabs = all
        switch reading(raw, row: browser.tabs.count, ids: tabs.map { $0.id.uuidString.lowercased() }) {
        case .index(let i): return try at(i, in: browser)
        case .id(let k): return tabs[k]
        case .nothing: throw Tools.Failure(text: "no tab \(raw) — \(Tools.tabList(browser))")
        case .several: throw Tools.Failure(text: "\(raw) names more than one tab; give more of its id")
        }
    }

    /// What a `tab` string names: a place in the row (`index`), the one tab
    /// whose id it begins (`id`, its place in `ids`), no tab, or several.
    enum Reading: Equatable { case index(Int), id(Int), nothing, several }

    /// Short ids are the first eight hex digits of a UUID, so about one in
    /// fifty is all digits (`12345678`, `00000012`). Read as an index, that
    /// names no tab, or quietly the wrong one. No row has ten million tabs and
    /// nobody writes an index with a leading zero, so those are always ids; a
    /// shorter number is a place in the row, unless the row has no such place
    /// and it begins exactly one tab's id. Anything else is an id or the start
    /// of one. `row` is how many tabs the row has; `ids` every tab's id,
    /// lowercased.
    nonisolated static func reading(_ raw: String, row: Int, ids: [String]) -> Reading {
        let hits = ids.indices.filter { ids[$0].hasPrefix(raw) }
        let named: Reading = hits.isEmpty ? .nothing : hits.count == 1 ? .id(hits[0]) : .several
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              raw.count < 8, !(raw.hasPrefix("0") && raw != "0"), let i = Int(raw) else { return named }
        if i >= row, case .id = named { return named }
        return .index(i)
    }

    private static func at(_ i: Int, in browser: Browser) throws -> Tab {
        guard browser.tabs.indices.contains(i) else { throw Tools.Failure(text: "no tab \(i) — \(Tools.tabList(browser))") }
        return browser.tabs[i]
    }

    /// The tab a call works on: the one it named, else the caller's own,
    /// else the one on screen. Nil only when there is none of those.
    static func target(in browser: Browser, caller: String? = callerKey) -> Tab? {
        if let tab = find(pinned) { return tab }
        if let tab = own(caller) { return tab }
        return browser.active
    }

    /// The caller's own tab, while it still exists.
    static func own(_ caller: String? = callerKey) -> Tab? {
        guard let caller, let id = bound[caller] else { return nil }
        if let tab = find(id) { return tab }
        bound[caller] = nil
        return nil
    }

    /// Without throwing, for the bookkeeping around a call (the tab badges).
    static func peek(_ args: [String: Any], in browser: Browser, caller: String?) -> Tab? {
        if let named = try? resolve(args["tab"], in: browser) { return named }
        if let tab = own(caller) { return tab }
        return browser.active
    }

    /// From now on this caller's calls land on `tab`.
    static func bind(_ tab: Tab, for caller: String? = callerKey) {
        guard binds(caller), let caller else { return }
        bound[caller] = tab.id
    }

    /// Back to working on whatever is on screen.
    static func unbind(_ caller: String? = callerKey) {
        guard let caller else { return }
        bound[caller] = nil
    }

    /// Showing in some window right now: a window's stage or the side pane.
    static func onScreen(_ tab: Tab?) -> Bool {
        guard let tab else { return true }
        if Windows.all.contains(where: { $0.activeID == tab.id }) || Split.shared.has(tab.id) { return true }
        if let window = tab.built?.window, !(window is Backstage.Window) { return true }
        return false
    }

    /// Ready to be worked on: awake, built, and hung backstage if nobody is
    /// looking at it.
    @discardableResult
    static func prepare(_ tab: Tab) -> Bool {
        if tab.asleep { _ = tab.wake() } else if tab.hollow { tab.revive() }
        return Backstage.shared.stage(tab)
    }

    /// Before a call reads or drives its tab: stage it, and when that just
    /// made the page visible, let WebKit tell the page before the call goes in.
    static func ready(in browser: Browser) async {
        guard let tab = target(in: browser), prepare(tab) else { return }
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// The window a tab belongs to — the row that holds it, else whoever
    /// shows its space.
    static func owner(of tab: Tab) -> Browser { CanvasTabs.owner(of: tab) }

    /// Put a tab in front of the user, on purpose.
    static func show(_ tab: Tab) {
        let browser = owner(of: tab)
        browser.select(tab)
    }
}

@MainActor
final class Backstage {
    static let shared = Backstage()

    /// Says it is key, and can never become key: WebKit reads `isKeyWindow`
    /// to decide whether the page's window is active, AppKit's own key
    /// window stays yours.
    ///
    /// A panel, like the Room (Fork/SpaceWarm.swift `Room.make`): AppKit
    /// leaves panels out when it asks whether the app has a window open. As
    /// an NSWindow, an agent's page hung here made a Dock click arrive as
    /// "a window is showing" — so AppKit opened nothing — and, up before the
    /// launch had decided on its first window, stopped that window from
    /// opening at all (Fork/LaunchWatchdog.swift).
    final class Window: NSPanel {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// How long a page stays backstage after the agent's last call.
    static let linger: TimeInterval = 5 * 60

    private var window: Window?
    /// Tab → the last time an agent asked for it.
    private var held: [UUID: Date] = [:]
    /// The views this put in its window, so only those are taken back out.
    private var hung: [UUID: ObjectIdentifier] = [:]
    /// The pages told to ignore occlusion for the hold.
    private var tabsIgnoring = Set<UUID>()
    private var timer: Timer?
    /// No App Nap for the app while a page is being worked on out of sight.
    private var activity: NSObjectProtocol?

    func holds(_ id: Tab.ID) -> Bool { held[id] != nil }
    var count: Int { held.count }
    var hungCount: Int { hung.count }

    /// Called before an agent works on a tab. A tab on screen is left where
    /// it is; one with no window is hung here.
    /// True when the page's visibility just changed — WebKit tells the page
    /// on its next turn, so a caller about to read it should give it one.
    @discardableResult
    func stage(_ tab: Tab) -> Bool {
        let fresh = held[tab.id] == nil || tab.built?.window == nil
        held[tab.id] = Date()
        settle(tab, focus: true)
        if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "An agent is working in a background tab")
        }
        return fresh
    }

    /// Let a tab go at once (it closed, or the agent is done with it).
    func release(_ id: Tab.ID) {
        held[id] = nil
        if let tab = AgentTabs.find(id) { unhang(tab) } else { hung[id] = nil; tabsIgnoring.remove(id) }
        idleIfEmpty()
    }

    /// Where this tab's view should be, now.
    /// `focus`: an agent is about to act on it, so within this window it is
    /// the view the keyboard goes to. The sweep never moves focus between
    /// pages — that would fire blur and focus at them twice a second.
    private func settle(_ tab: Tab, focus: Bool = false) {
        guard !tab.floating, !tab.isBlank || tab.built != nil else { return }
        let web = tab.web
        // Wherever it is, a page an agent is working in counts as visible:
        // your window may be behind a terminal, and an occluded page is a
        // background tab to WebKit. Back to normal when the hold ends.
        Backstage.ignoreOcclusion(web, true)
        tabsIgnoring.insert(tab.id)
        if let window = web.window {
            if window === self.window {
                // Already here; keep it the size of the stage it would be on,
                // and the one the keyboard goes to inside this window.
                if let bounds = window.contentView?.bounds, web.frame != bounds { web.frame = bounds }
                if focus, window.firstResponder !== web { window.makeFirstResponder(web) }
            } else if hung[tab.id] != nil {
                // You took it to your stage.
                hung[tab.id] = nil
            }
            return
        }
        // A tab some window has just been told to show is its stage's to take,
        // never this window's: hung here between the selection and the stage's
        // next pass, the page would wait backstage while the stage stood empty.
        if Windows.all.contains(where: { $0.activeID == tab.id }) || Split.shared.has(tab.id) { return }
        hang(web, for: tab, focus: focus)
    }

    private func hang(_ web: PageView, for tab: Tab, focus: Bool) {
        let window = ensureWindow()
        guard let content = window.contentView else { return }
        // Before it joins the window: WebKit works out the page's visibility
        // as the view arrives.
        Backstage.ignoreOcclusion(web, true)
        web.removeFromSuperview()
        web.frame = content.bounds
        web.isHidden = false
        web.alphaValue = 1
        content.addSubview(web)
        web.needsLayout = true
        web.needsDisplay = true
        if focus || window.firstResponder === window { window.makeFirstResponder(web) }
        hung[tab.id] = ObjectIdentifier(web)
    }

    private func unhang(_ tab: Tab) {
        defer { hung[tab.id] = nil; tabsIgnoring.remove(tab.id) }
        guard let web = tab.built else { return }
        if tabsIgnoring.contains(tab.id) { Backstage.ignoreOcclusion(web, false) }
        if hung[tab.id] != nil, web.window === window { web.removeFromSuperview() }
    }

    private func sweep() {
        let now = Date()
        for (id, last) in held {
            guard let tab = AgentTabs.find(id) else {
                held[id] = nil
                hung[id] = nil
                tabsIgnoring.remove(id)
                continue
            }
            if now.timeIntervalSince(last) > Backstage.linger {
                held[id] = nil
                unhang(tab)
                continue
            }
            // You looked at it and moved on: its view left your stage and
            // has no window again.
            settle(tab)
        }
        // A view hung here whose tab is gone.
        if let content = window?.contentView {
            let wanted = Set(hung.values)
            for view in content.subviews where !wanted.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        }
        resize()
        idleIfEmpty()
    }

    private func idleIfEmpty() {
        guard held.isEmpty else { return }
        timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        window?.orderOut(nil)
    }

    // MARK: - the window

    /// The size the page would have on your stage: the stage in front, else
    /// a laptop's worth.
    private static var stageSize: NSSize {
        for browser in [Windows.current] + Windows.all {
            if let web = browser.active?.built, let window = web.window, !(window is Window),
               web.bounds.width > 200, web.bounds.height > 200 { return web.bounds.size }
        }
        return NSSize(width: 1280, height: 800)
    }

    private func ensureWindow() -> Window {
        let size = Backstage.stageSize
        if let window {
            if !window.isVisible { place(window, size: size); window.orderBack(nil) }
            return window
        }
        let window = Backstage.built(size: size)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        place(window, size: size)
        // Ordered in without being brought forward: an inactive app stays
        // inactive, your windows keep their order.
        window.orderBack(nil)
        self.window = window
        return window
    }

    /// The room, made and not yet ordered in (Tests: LaunchWindowTests).
    static func built(size: NSSize = NSSize(width: 1280, height: 800)) -> Window {
        let window = Window(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // A panel hides when its app stops being active; this one never
        // does, or an agent's page would turn hidden behind your other apps.
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenNone]
        window.title = "Copper backstage"
        return window
    }

    private func place(_ window: NSWindow, size: NSSize) {
        window.setContentSize(size)
        window.setFrameOrigin(Parking.origin(for: window.frame.size))
    }

    /// Follow the stage's size, and stay off every display.
    private func resize() {
        guard let window, window.isVisible else { return }
        let size = Backstage.stageSize
        if window.contentView?.bounds.size != size || Parking.intersectsAScreen(window.frame) { place(window, size: size) }
        if let content = window.contentView {
            for view in content.subviews where view.frame != content.bounds { view.frame = content.bounds }
        }
    }

    // MARK: - occlusion

    private static let occlusionSetter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")

    /// WebKit's private switch (WKWebViewPrivate), called directly. Headless
    /// keeps every view ignoring occlusion; it is never turned back on there.
    static func ignoreOcclusion(_ web: WKWebView, _ ignore: Bool) {
        if !ignore, Headless.on { return }
        guard web.responds(to: occlusionSetter), web.headlessIgnoresOcclusion != ignore else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(web.method(for: occlusionSetter), to: Setter.self)(web, occlusionSetter, !ignore)
        // WebKit only rereads visibility when something changes; in a window
        // already covered by another app nothing does. Its own cue is the
        // window's occlusion notification, which every observer just rereads.
        if let window = web.window, !(window is Window) {
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    /// For the bench and `copper tabs`.
    var report: [String: Any] {
        ["held": held.count, "hung": hung.count, "window": window.map { NSStringFromRect($0.frame) } ?? "none",
         "visible": window?.isVisible ?? false]
    }
}
