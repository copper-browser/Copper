import AppKit
import SwiftUI
import WebKit

// The mouse buttons past the two: the wheel pressed as a button, and the
// thumb buttons a mouse with side buttons calls back and forward.
//
// Two systems number them differently, and mixing the two is how the middle
// click went missing:
//
// - AppKit's `NSEvent.buttonNumber` counts: 0 left, 1 right, 2 middle,
//   3 back, 4 forward. Those arrive as `.otherMouseDown` / `.otherMouseUp`.
// - WebKit's `WKNavigationAction.buttonNumber` is a mask
//   (WebEventFactory::toNSButtonNumber): 1 left, 2 right, 4 middle, 8 back,
//   16 forward. Upstream tested it against AppKit's 2 — a right button, which
//   never activates a link — so a middle click fell through and navigated
//   the page in place.
//
// The thumb buttons nobody handled: WebKit forwards them to the page as DOM
// buttons 3 and 4 and does nothing else, so they did nothing. A local monitor
// takes them before the page does: over the sidebar they switch spaces, and
// over a page they navigate the pane under the pointer.
@MainActor
enum MouseButtons {
    // MARK: - WebKit's numbering (a link click's button)

    /// `WKNavigationAction.buttonNumber` for the wheel button.
    static let middleInAction = 4

    static func isMiddle(_ action: WKNavigationAction) -> Bool {
        action.buttonNumber == middleInAction
    }

    /// The last link click WebKit reported, for `bench probe`: the number it
    /// gave the button and the modifiers held, so the mapping above can be
    /// checked against the WebKit actually on the Mac, not the one in a doc.
    private(set) static var lastLinkClick: [String: Any] = [:]

    static func noteLinkClick(_ action: WKNavigationAction) {
        let flags = action.modifierFlags.intersection(.deviceIndependentFlagsMask)
        lastLinkClick = [
            "button": action.buttonNumber,
            "command": flags.contains(.command),
            "shift": flags.contains(.shift),
            "url": action.request.url?.absoluteString ?? "",
        ]
    }

    // MARK: - AppKit's numbering (the event itself)

    static let middle = 2
    static let back = 3
    static let forward = 4

    /// Posted when the wheel button is clicked over the column, with the
    /// point clicked (`object`, an NSValue, in SwiftUI's global space: the
    /// window's content from its top left); the row under it closes its
    /// tab, the way Arc's and Chrome's do.
    static let middleClickedSidebar = Notification.Name("copper.middleClickedSidebar")

    /// The point a sidebar notification carried, for a view's `onReceive`.
    static func point(of note: Notification) -> CGPoint? { (note.object as? NSValue)?.pointValue }

    /// What the monitor did last, for the bench.
    private(set) static var lastAction: [String: Any] = [:]

    private static var monitor: Any?

    static func watch(_ browser: Browser) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { event in
            // A Bool crosses back out of the actor where an NSEvent may not.
            let ours = MainActor.assumeIsolated { handle(event, in: browser) }
            return ours ? nil : event
        }
    }

    /// True when the app took the event and the window must not see it.
    private static func handle(_ event: NSEvent, in browser: Browser) -> Bool {
        // Only the browser window; a settings panel or a sheet keeps its own.
        // Each browser window moves its own pages. (Fork: windows)
        guard let window = event.window, let owner = Windows.owner(of: window) else { return false }
        return route(button: event.buttonNumber, down: event.type == .otherMouseDown,
                     at: event.locationInWindow, in: window, browser: owner)
    }

    /// One half of a click of one of the other buttons, at a point in the
    /// window. True when the app took it and the page must not see it.
    static func route(button: Int, down: Bool, at location: CGPoint, in window: NSWindow, browser: Browser) -> Bool {
        switch button {
        case back, forward:
            // Arc uses the thumb buttons like a sideways swipe when they are
            // over the column. Both halves are swallowed, even with one space,
            // so the page never sees a click meant for the browser chrome.
            if SpaceSwipe.overSidebar(location, in: browser) {
                guard down else { return true }
                guard Spaces.shared.all.count > 1 else { return true }
                let by = button == back ? -1 : 1
                SpaceSwipe.go(by, in: browser)
                lastAction = ["button": button, "did": by < 0 ? "space-prev" : "space-next",
                              "space": Spaces.shared.space(in: browser).name]
                return true
            }
            // Chrome navigates on the press. Both halves are swallowed so the
            // page never sees half a click of a button it has no use for.
            guard down else { return true }
            let tab = page(under: location, in: window, browser: browser) ?? browser.active
            guard let tab else { return true }
            // Over the other pane of a split, that pane is the one that moves
            // — and, as with a click into it, the one that becomes live.
            if Split.shared.has(tab.id) { Split.shared.touched(tab, in: browser) }
            button == back ? tab.back() : tab.forward()
            lastAction = ["button": button, "did": button == back ? "back" : "forward",
                          "tab": String(tab.id.uuidString.prefix(8)).lowercased()]
            return true

        case middle:
            // Over a page the click is WebKit's: a link becomes a background
            // tab through the navigation policy (Browser.decidePolicyFor),
            // which is the only route that also sees links in iframes. Over
            // the column, the release closes the row under the pointer.
            if page(under: location, in: window, browser: browser) != nil { return false }
            guard SpaceSwipe.overSidebar(location, in: browser) else { return false }
            if !down {
                // AppKit's window point is from the bottom left; SwiftUI's
                // global frames are from the top left of the content view.
                let height = window.contentView?.bounds.height ?? window.frame.height
                let point = CGPoint(x: location.x, y: height - location.y)
                NotificationCenter.default.post(name: middleClickedSidebar, object: NSValue(point: point))
                lastAction = ["button": middle, "did": "sidebar", "at": [Int(point.x), Int(point.y)]]
            }
            return true

        default:
            return false
        }
    }

    /// The tab whose page is under a point in the window, if it is on a page.
    static func page(under location: CGPoint, in window: NSWindow, browser: Browser) -> Tab? {
        guard let hit = window.contentView?.hitTest(location), let web = LineKeys.page(of: hit) else { return nil }
        return browser.tabs.first { $0.built === web }
    }

    /// `bench mouse back|forward|middle [X Y] [--shift]`: a click of that
    /// button at a point in the window (X Y from the top left, as a
    /// screenshot reads; the page's middle when none is given) — for a run
    /// without a five-button mouse to hand, and for a Mac that will not let a
    /// shell post events (no Accessibility grant).
    ///
    /// The click is real as far as the app can make it: an NSEvent built on a
    /// CGEvent, which is the only way to give it a button number, put through
    /// the same routing the monitor runs, and — when the app leaves it alone
    /// — handed to the view under the point the way NSWindow.sendEvent would,
    /// so WebKit sees the wheel button on a link and reports it back through
    /// the navigation policy (`bench probe` → `lastLinkClick`, a moment later).
    static func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        var words = (request["arg"] as? String ?? "back").split(separator: " ").map(String.init)
        // `--window N`: the click in that browser window (as `windows` lists
        // them) rather than the first — each window's column switches its
        // own space. (Fork: windows)
        var browser = browser
        if let at = words.firstIndex(of: "--window"), at + 1 < words.count, let n = Int(words[at + 1]) {
            guard Windows.all.indices.contains(n) else { return ["error": "no window \(n)"] }
            browser = Windows.all[n]
            words.removeSubrange(at...(at + 1))
        }
        guard let window = Windows.window(of: browser) ?? Links.window else { return ["error": "no window"] }
        let shifted = words.contains("--shift")
        let arg = words.filter { $0 != "--shift" }
        let number: Int
        switch arg.first ?? "back" {
        case "back": number = back
        case "forward": number = forward
        case "middle": number = middle
        default: return ["error": "mouse back|forward|middle [X Y] [--shift]"]
        }
        var point = CGPoint(x: window.frame.width * 0.6, y: window.frame.height * 0.5)
        if arg.count >= 3, let x = Double(arg[1]), let y = Double(arg[2]) { point = CGPoint(x: x, y: y) }
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        // An event made from a CGEvent has no window, so its location reads
        // as the window's own coordinates by every view that converts it
        // `from: nil` — WebKit included. The screen height flips it back.
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cursor = CGPoint(x: location.x, y: screenHeight - location.y)
        func event(_ type: CGEventType) -> NSEvent? {
            guard let button = CGMouseButton(rawValue: UInt32(number)),
                  let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: button)
            else { return nil }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
            cg.setIntegerValueField(.mouseEventClickState, value: 1)
            if shifted { cg.flags = .maskShift }
            return NSEvent(cgEvent: cg)
        }
        guard let down = event(.otherMouseDown), let up = event(.otherMouseUp) else { return ["error": "no event"] }
        lastAction = [:]
        let hit = window.contentView?.hitTest(location)
        let took = route(button: number, down: true, at: location, in: window, browser: browser)
        _ = route(button: number, down: false, at: location, in: window, browser: browser)
        if !took, let hit {
            hit.otherMouseDown(with: down)
            hit.otherMouseUp(with: up)
        }
        let over = page(under: location, in: window, browser: browser)
        return ["button": down.buttonNumber, "shift": shifted, "took": took, "at": [Int(point.x), Int(point.y)], "last": lastAction,
                "hit": hit.map { "\(type(of: $0))" } ?? "",
                "over": over.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
                "active": browser.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                "url": browser.active?.address?.absoluteString ?? ""]
    }
}

/// Where every favourite and row of the column is, for the wheel button:
/// each hands up its own bounds, the scroll hands up the part of the column
/// the rows can be seen in, and the column's one listener asks which is
/// under the click. Anchors rather than frames, so nothing is measured until
/// a click comes — no reader per row, and no redraw when a row moves.
struct SideTargets: PreferenceKey, Equatable {
    var pins: [Tab.ID: Anchor<CGRect>] = [:]
    var rows: [Tab.ID: Anchor<CGRect>] = [:]
    /// The scroll the rows live in. A row scrolled off the top still has a
    /// frame, and it is under the favourites.
    var window: Anchor<CGRect>?

    static let defaultValue = SideTargets()

    static func reduce(value: inout SideTargets, nextValue: () -> SideTargets) {
        let next = nextValue()
        value.pins.merge(next.pins) { $1 }
        value.rows.merge(next.rows) { $1 }
        value.window = next.window ?? value.window
    }

    /// The tab under a point in SwiftUI's global space (as the sidebar
    /// notification carries it), read in the listener's own geometry.
    /// Fork (space-perf): rows hand up no anchor each; `row` finds one from
    /// a global point (SideDrag.row), inside the scroll only.
    func hit(_ point: CGPoint, in geo: GeometryProxy, row: (CGPoint) -> Tab.ID? = { _ in nil }) -> Tab.ID? {
        let origin = geo.frame(in: .global).origin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if let pin = pins.first(where: { geo[$0.value].contains(local) }) { return pin.key }
        if let window, !geo[window].contains(local) { return nil }
        return rows.first { geo[$0.value].contains(local) }?.key ?? row(point)
    }
}
