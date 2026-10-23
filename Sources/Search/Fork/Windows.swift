import AppKit
import SwiftUI

// More than one window. ⌘N opens another browser window, and every window
// sees the same Spaces rows, pinned tabs, folders and groups. Each window
// remembers its own current space and active tab, like Arc; selecting a tab
// that is on another window's stage hands it to this window, and that window
// lands on its most recent tab no window is showing — or, with none left,
// says the page is open in another window and offers it back (TakenStage).
// The Tab (and its WKWebView) is shared, never copied, so two StageViews
// never hold one page; ⌘W, a space switch and the archive sweep all steer
// clear of a tab another window is showing, and the one split view belongs
// to one window at a time (Split.holder).
//
// session.json remains the source of truth for spaces and tabs. windows.json
// holds only each window's space and the address of the tab it was on.
// Closing a window with the red button forgets that state and keeps the
// shared tabs (only an untouched blank tab the window made goes with it);
// quitting keeps every window for the next launch. A row in the old format,
// with its own `tabs`, is folded into the window's space on first load and
// written to session.json before windows.json forgets it.
//
// Agents follow the window in front: the MCP server and the command bar act
// on the frontmost browser window, and fall back to the first one when it
// closes.

@MainActor
enum Windows {
    /// The browser the app launches with. The app's scene holds it; every
    /// other window borrows its shared parts (Browser.init(window:)).
    static let main = Browser()

    /// The windows opened with ⌘N, by the id their scene carries.
    private static var others: [UUID: Browser] = [:]
    private static var order: [UUID] = []

    /// Every browser that has, or had at launch, a window — the first one first.
    static var all: [Browser] { [main] + order.compactMap { others[$0] } }

    /// Set by the first window's view: opens a scene for an id.
    static var opener: ((UUID) -> Void)?
    /// Set beside it: brings the first window's own scene back.
    static var primary: (() -> Void)?
    /// The app is on its way out: windows closing now are being kept.
    static var quitting = false

    /// ⌘N. With no window ever made there is no `openWindow` to ask yet
    /// (it comes from the first window's view), so the first window comes
    /// instead of nothing (Fork/LaunchWatchdog.swift).
    static func newWindow() {
        guard let opener else {
            openFirst("new-window")
            return
        }
        opener(UUID())
    }

    /// A browser window has been attached at some point in this run — the
    /// launch got one, whatever has been closed since.
    private(set) static var everAttached = false

    /// The first window's scene, when it has to come from nowhere: its own
    /// `openWindow` once a window has given us one, else SwiftUI's delegate
    /// asked for what a launch gets — what a link from another app does
    /// (Links `summon`). The scene is a single `Window`, so asking while it is
    /// already up brings that one forward and never makes a second. Nothing
    /// in a headless run, whose window is parked by Fork/Headless.swift.
    static func openFirst(_ why: String) {
        guard !Headless.on else { return }
        let via = primary == nil ? "untitled" : "scene"
        if !everAttached { Breadcrumbs.note("window-recovery", [("via", why), ("opened", via)]) }
        if let primary {
            primary()
        } else {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
    }

    /// The Dock icon clicked with no window on screen (Links'
    /// `applicationShouldHandleReopen`). A browser window that is still
    /// around comes back — the one in the Dock first, then the first
    /// window's, which SwiftUI keeps after its red button — and with none
    /// left, a new one opens: the first window's scene again, or ⌘N.
    ///
    /// It used to order front the first window in `NSApp.windows` with a
    /// content view, which with pages warming in the background is the
    /// room parked off every screen (SpaceWarm), so the click did nothing
    /// anyone could see; and with the first window gone for good there was
    /// nothing to order front at all.
    /// A browser window someone could be looking at: ordered in, not in
    /// the Dock, and on a screen. The rooms Copper parks far off every
    /// display to warm pages in (SpaceWarm, Backstage) are windows too, and
    /// macOS counts them when it tells the app whether a window is visible —
    /// so with every browser window closed the Dock click used to arrive as
    /// "a window is showing" and nothing happened.
    static var anyShowing: Bool {
        let kept = all.compactMap { window(of: $0) } + [Links.window].compactMap { $0 }
        return kept.contains { window in
            window.isVisible && !window.isMiniaturized && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        }
    }

    /// A browser window in the Dock (Fork/LaunchWatchdog.swift).
    static var anyDocked: Bool {
        (all.compactMap { window(of: $0) } + [Links.window].compactMap { $0 }).contains(where: \.isMiniaturized)
    }

    /// The Dock menu's New Window: a new window beside the ones showing, or
    /// — with none showing — the closed one back first, the way a Dock click does.
    static func newWindowFromDock() {
        if anyShowing { newWindow() } else { reopenFromDock() }
        NSApp.activate()
    }

    static func reopenFromDock() {
        let kept = all.compactMap { window(of: $0) } + [Links.window].compactMap { $0 }
        if let docked = kept.first(where: \.isMiniaturized) {
            docked.deminiaturize(nil)
            docked.makeKeyAndOrderFront(nil)
            return
        }
        for window in kept {
            window.makeKeyAndOrderFront(nil)
            if window.isVisible { return }
        }
        // Closed for good, or never made at all (a launch that got no first
        // window): the first window's scene again (Fork/LaunchWatchdog.swift).
        openFirst("dock")
    }

    /// The browser for a window scene's id, made the first time it is asked for.
    static func browser(for id: UUID) -> Browser {
        if let known = others[id] { return known }
        let browser = Browser(window: id)
        others[id] = browser
        order.append(id)
        return browser
    }

    // MARK: - which window is which

    private final class Weak { weak var window: NSWindow?; weak var browser: Browser?
        init(_ w: NSWindow, _ b: Browser) { window = w; browser = b } }
    private static var windows: [Weak] = []
    /// Each window's two observers, let go when it closes.
    private static var tokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    /// A browser's window, once it is on screen. Also where agents turn when
    /// the window becomes the one in front.
    static func attach(_ window: NSWindow, to browser: Browser) {
        guard !windows.contains(where: { $0.window === window && $0.browser === browser }) else { return }
        everAttached = true
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(Weak(window, browser))
        let center = NotificationCenter.default
        let key = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak browser] _ in
            MainActor.assumeIsolated {
                guard let browser else { return }
                front = browser
                Spaces.shared.frontChanged(browser)
                MCP.shared.follow(browser)
            }
        }
        let slot = ObjectIdentifier(window)
        let close = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak browser] _ in
            MainActor.assumeIsolated {
                // Closed by the person: the launch watchdog leaves it closed.
                LaunchWatchdog.windowClosed()
                // The first window's NSWindow is the one SwiftUI brings back
                // after its red button (a Dock click, a link), and `attach`
                // skips a pair it already knows: let its observers go here
                // and it would never again tell agents — or a link from
                // another app — that it is the window in front.
                guard let browser, let id = browser.windowID else { return }
                for token in tokens.removeValue(forKey: slot) ?? [] { NotificationCenter.default.removeObserver(token) }
                windows.removeAll { $0.browser === browser }
                closed(id)
            }
        }
        tokens[slot] = [key, close]
        // A window opened with ⌘N is key before it is attached: the
        // notification above has already gone by.
        if window.isKeyWindow {
            front = browser
            Spaces.shared.frontChanged(browser)
            MCP.shared.follow(browser)
        }
    }

    /// The browser window in front, or the first one.
    private(set) static weak var front: Browser?
    static var current: Browser { front ?? main }

    /// The browser a window belongs to; nil for a panel, a popup, a sheet.
    static func owner(of window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return windows.first { $0.window === window }?.browser
    }

    /// A browser's own window.
    static func window(of browser: Browser) -> NSWindow? {
        windows.first { $0.browser === browser && $0.window != nil }?.window
    }

    /// True for a window some browser owns.
    static func isBrowserWindow(_ window: NSWindow?) -> Bool { owner(of: window) != nil }

    /// The window showing a tab now. If it is not active anywhere, prefer
    /// the frontmost window viewing its space, then the main window.
    static func owner(of tab: Tab) -> Browser? {
        if let active = all.first(where: { $0.activeID == tab.id }) { return active }
        if let space = Spaces.shared.spaceID(of: tab),
           let front = all.first(where: { Spaces.shared.current(in: $0) == space && $0 === current }) { return front }
        if let space = Spaces.shared.spaceID(of: tab),
           let viewer = all.first(where: { Spaces.shared.current(in: $0) == space }) { return viewer }
        return main
    }

    /// A ⌘N window closed. Quitting keeps it for next time; the red button
    /// lets its pages go.
    private static func closed(_ id: UUID) {
        guard !quitting, let browser = others.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if front === browser {
            front = nil
            Spaces.shared.frontChanged(main)
        }
        if MCP.shared.follows(browser) { MCP.shared.follow(main) }
        // An agent at work in this window stops with it, rather than
        // building pages in a browser nobody can see.
        Agent.shared.stop(ifIn: browser)
        browser.retire()
        saved.removeAll { $0.id == id }
        write(now: true)
    }

    // MARK: - keeping

    /// One window's view state: its space, and the address of the tab it
    /// was on. An address rather than a tab id — a Tab's id is made afresh
    /// every launch and session.json carries none, so an id could never be
    /// found again on the next one.
    struct Saved: Codable {
        var id: UUID
        var space: UUID?
        var url: String?
        /// Only populated while decoding the old windows.json format, whose
        /// rows carried their own `tabs` and an `active` index.
        var legacyTabs: [Session.Entry]?
        var legacyActive: Int?

        init(id: UUID, space: UUID?, url: String?) {
            self.id = id
            self.space = space
            self.url = url
            legacyTabs = nil
            legacyActive = nil
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            space = try c.decodeIfPresent(UUID.self, forKey: .space)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            legacyActive = try? c.decodeIfPresent(Int.self, forKey: .active)
            legacyTabs = try c.decodeIfPresent([Session.Entry].self, forKey: .tabs)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(space, forKey: .space)
            try c.encodeIfPresent(url, forKey: .url)
        }

        private enum CodingKeys: String, CodingKey { case id, space, url, active, tabs }
    }

    private static var file: URL { Store.file("windows.json") }
    private static let writer = DispatchQueue(label: "copper.windows.write", qos: .utility)
    private static var saved: [Saved] = {
        guard let data = try? Data(contentsOf: Windows.file) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: data)) ?? []
    }()

    /// The view state a reopened window starts with. Legacy tabs are retained
    /// until Browser folds them into the canonical space row.
    static func savedState(for id: UUID) -> Saved? { saved.first { $0.id == id } }

    /// Legacy rows are consumed by Browser when their scene is first opened.
    static func legacy(_ id: UUID) -> ([Session.Entry], Int?)? {
        guard let row = saved.first(where: { $0.id == id }), let tabs = row.legacyTabs else { return nil }
        return (tabs, row.legacyActive)
    }

    static func markMigrated(_ id: UUID, space: UUID) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].space = space
        saved[i].legacyTabs = nil
        saved[i].legacyActive = nil
        write(now: true)
    }

    /// A ⌘N window's row changed.
    static func keep(_ browser: Browser, now: Bool = false) {
        guard record(browser) else { return }
        write(now: now)
    }

    /// The row as it is, in memory. False for a window that is not open.
    @discardableResult
    private static func record(_ browser: Browser) -> Bool {
        guard let id = browser.windowID, others[id] != nil else { return false }
        let row = Saved(id: id, space: Spaces.shared.current(in: browser), url: browser.active.flatMap { ($0.pending ?? $0.address)?.absoluteString })
        if let i = saved.firstIndex(where: { $0.id == id }) { saved[i] = row } else { saved.append(row) }
        return true
    }

    /// Every ⌘N window, to disk on the way out.
    static func flush() {
        // Canvases first: each page that is up writes its whole document as
        // the snapshot (a second at most), so the next open is one read.
        CanvasTabs.flushAll()
        quitting = true
        for browser in all where !browser.primary { record(browser) }
        write(now: true)
    }

    private static func write(now: Bool) {
        let rows = saved
        let file = Windows.file
        let put: @Sendable () -> Void = {
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? data.write(to: file, options: .atomic)
        }
        // One queue, in order: an older snapshot can never land after a newer one.
        if now { writer.sync(execute: put) } else { writer.async(execute: put) }
    }

    /// Launch: the windows that were open when Copper quit, back on screen.
    /// A scene macOS already restored is simply brought forward again.
    static func reopen() {
        guard let opener else { return }
        for row in saved { opener(row.id) }
    }
}

extension Browser {
    /// Where ⌘W lands after the tab at `index` left the row: the neighbour
    /// on the right, or the last one — unless another window is showing that
    /// tab, in which case the nearest tab no window is showing. With every
    /// tab on a stage somewhere, the neighbour anyway: selecting it hands it
    /// over (Spaces.claim) and the other window says where it went.
    func landing(after index: Int) -> Tab {
        let at = min(index, tabs.count - 1)
        // Nearest the gap, right first — passing over Saved rows a close has
        // just put down (Fork/Sections.swift), unless nothing else is left.
        let order = ((at..<tabs.count).map { $0 } + stride(from: at - 1, through: 0, by: -1).map { $0 }).map { tabs[$0] }
        let open = order.filter { !Sections.shared.isDown($0) }
        let pool = open.isEmpty ? order : open
        return pool.first { !Spaces.shared.shown($0, outside: self) } ?? pool[0]
    }

    /// The most recently looked-at of `pool`, preferring one no other window
    /// is showing.
    func landing(among pool: [Tab]) -> Tab? {
        let free = pool.filter { !Spaces.shared.shown($0, outside: self) }
        return (free.isEmpty ? pool : free).max { $0.touched < $1.touched }
    }
}

/// The stage of a window whose only tab another window took (Browser.taken):
/// the page is not gone, it is simply over there. One line, and the two
/// things worth doing about it — as Arc's "open in another window" does.
struct TakenStage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        VStack(spacing: 14) {
            Text("\(tab.title.isEmpty ? "This page" : tab.title) is open in another window.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Show Here") { browser.select(tab) }
                    .keyboardShortcut(.defaultAction)
                Button("New Tab") { browser.newTab() }
            }
            .controlSize(.regular)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}

/// A window opened with ⌘N: its own browser, the same view as the first.
struct OtherWindow: View {
    let id: UUID
    @StateObject private var browser: Browser

    init(id: UUID) {
        self.id = id
        _browser = StateObject(wrappedValue: Windows.browser(for: id))
    }

    var body: some View {
        ContentView(browser: browser)
            .frame(minWidth: 640, minHeight: 420)
    }
}

/// The first window's hand on `openWindow`, for ⌘N from anywhere.
struct WindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            guard Windows.opener == nil else { return }
            Windows.opener = { id in openWindow(id: "window", value: id) }
            Windows.primary = { openWindow(id: "browser") }
            // The ones open at the last quit, a moment after the first window
            // is up so it keeps its place in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Windows.reopen()
                NSApp.windows.first { Windows.owner(of: $0) === Windows.main }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - the bench

extension Windows {
    /// `windows` lists every browser window; `windows new`; `windows open N URL`
    /// (a tab in window N); `windows key N`; `windows space N INDEX`; `windows
    /// select N TAB`; `windows closetab N TAB` (⌘W); `windows close N` (the red button);
    /// `windows dock` is the Dock icon clicked with no window on screen;
    /// `windows dockmenu` is the Dock menu's New Window; `windows showing`
    /// says whether a browser window is on screen (and how many windows
    /// macOS calls visible, rooms included);
    /// `windows watchdog` is what the launch watchdog last decided
    /// (Fork/LaunchWatchdog.swift);
    /// `windows saved` is windows.json as held; `windows quit` is ⌘Q.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let op = request["op"] as? String ?? ""
        let arg = request["arg"] as? String ?? ""
        let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let list = all
        func pick() -> Browser? { bits.first.flatMap(Int.init).flatMap { list.indices.contains($0) ? list[$0] : nil } }
        switch op {
        case "new": newWindow()
        case "dock": reopenFromDock()
        case "dockmenu": newWindowFromDock()
        case "showing": return ["showing": anyShowing, "nsVisible": NSApp.windows.filter(\.isVisible).count, "everAttached": everAttached]
        case "watchdog": return LaunchWatchdog.report
        case "open":
            guard let browser = pick(), bits.count > 1, let url = URL(string: bits[1]) else { return ["error": "open N URL"] }
            _ = browser.open(url, foreground: true)
        case "key":
            guard let browser = pick() else { return ["error": "key N"] }
            window(of: browser)?.makeKeyAndOrderFront(nil)
        case "space":
            guard bits.count > 1, let browser = pick(), let index = Int(bits[1]), Spaces.shared.all.indices.contains(index) else {
                return ["error": "space N INDEX"]
            }
            Spaces.shared.select(Spaces.shared.all[index].id, in: browser)
        case "select":
            guard bits.count > 1, let browser = pick(), let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(bits[1].lowercased()) }) else {
                return ["error": "select N TAB"]
            }
            browser.select(tab)
        case "closetab":
            // ⌘W on a tab of window N, by the id prefix `windows` lists.
            guard bits.count > 1, let browser = pick(), let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(bits[1].lowercased()) }) else {
                return ["error": "closetab N TAB"]
            }
            browser.close(tab)
        case "close":
            guard let browser = pick() else { return ["error": "close N"] }
            window(of: browser)?.performClose(nil)
        case "quit":
            // A real ⌘Q, so a test can see what comes back at the next launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return ["quitting": true]
        case "saved":
            return ["saved": saved.map { ["id": $0.id.uuidString, "space": $0.space?.uuidString ?? "", "url": $0.url ?? "",
                                          "legacy": $0.legacyTabs?.count ?? 0] as [String: Any] }]
        default: break
        }
        return ["windows": list.enumerated().map { i, browser -> [String: Any] in
            let window = window(of: browser)
            return ["index": i, "primary": browser.primary, "id": browser.windowID?.uuidString ?? "",
                    "number": window?.windowNumber ?? 0, "key": window?.isKeyWindow ?? false,
                    "visible": window?.isVisible ?? false, "front": browser === current,
                    "mcp": MCP.shared.follows(browser),
                    "space": Spaces.shared.current(in: browser).uuidString,
                    "spaceName": Spaces.shared.space(in: browser).name,
                    "tabs": browser.tabs.map { $0.address?.absoluteString ?? "" },
                    "tabIDs": browser.tabs.map { String($0.id.uuidString.prefix(8)).lowercased() },
                    "active": browser.tabs.firstIndex { $0.id == browser.activeID } ?? -1,
                    "taken": browser.taken.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    "split": Split.shared.on(in: browser),
                    // The first `pinned` of `tabs` are the global pins, the
                    // same in every window.
                    "pinned": browser.pinnedCount]
        }, "pins": Spaces.shared.pins.map { String($0.id.uuidString.prefix(8)).lowercased() }, "opener": opener != nil]
    }
}
