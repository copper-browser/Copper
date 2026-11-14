import AppKit

// A hand on the column, for the bench: `./bench sections drag ID DY` picks
// a row up by its middle and moves it DY points (negative is up) in small
// steps, the way a person's drag arrives — each step a real mouse event
// posted to the app's own queue, so it reaches SwiftUI's gestures by the
// path a person's does — and lets go. With `hold`, it stops with the row
// still in the hand, for a picture of the drop indicator mid-drag;
// `sections release` lets go of it.
//
// The bench answers at once and the events follow on the main queue, a
// frame apart; `sections` afterwards says where the row ended up.
//
// Rows hand their frames up as they are laid out (GroupedRows), in SwiftUI's
// global space: the window's content, top-left origin.

@MainActor
enum SideHand {
    /// A loose row's frame as last laid out, in window-content points with
    /// the origin at the top left (Fork: space-perf — from SideDrag's
    /// frames, not one global frame reported by every row).
    static func frame(of tab: Tab, in browser: Browser) -> CGRect? { SideDrag.of(browser).global(tab.id) }

    /// The drag still in the hand: the window it is in and where the
    /// pointer is now, in window base coordinates.
    private static var held: (window: NSWindow, at: NSPoint)?

    /// How the events go in: `post` (the app's queue, the default),
    /// `window` (`NSWindow.sendEvent`, now) or `view` (the view under the
    /// pointer, as the canvas bench hands its events to the page).
    static var how = "view"

    static func window(of browser: Browser) -> NSWindow? {
        Windows.window(of: browser) ?? Links.window
    }

    /// A point in SwiftUI's global space, in the window's own coordinates.
    private static func base(_ point: CGPoint, in window: NSWindow) -> NSPoint {
        let height = window.contentView?.frame.height ?? window.frame.height
        return NSPoint(x: point.x, y: height - point.y)
    }

    private static var target: NSView?

    private static func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        switch how {
        case "window": window.sendEvent(event)
        case "view":
            if type == .leftMouseDown { target = window.contentView?.hitTest(point) }
            guard let view = target ?? window.contentView else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event); target = nil
            default: break
            }
        default: NSApp.postEvent(event, atStart: false)
        }
    }

    /// A probe never has the key window — it must not take focus from the
    /// person at the Mac — and AppKit spends a press on a window that isn't
    /// key on making it key ("first mouse") unless the view under it says
    /// it takes the first click. In a test world, for the bench's hand only,
    /// every view says so: the press reaches SwiftUI's gestures the way a
    /// click-through press reaches any Mac app's.
    private static var clickThrough = false
    private static func acceptFirstMouse() {
        guard Store.testing, !clickThrough else { return }
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let yes: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(yes))
        clickThrough = true
    }

    /// Pick `tab`'s row up and move it `dy` points over `steps` events, a
    /// frame apart. Answers at once with where the press went.
    static func drag(_ tab: Tab, dy: CGFloat, dx: CGFloat = 0, steps: Int, hold: Bool, in browser: Browser) -> [String: Any] {
        if held != nil { _ = release(in: browser) }
        guard let window = window(of: browser) else { return ["error": "no window"] }
        guard let frame = Self.frame(of: tab, in: browser) else { return ["error": "row \(Bench.short(tab)) is not laid out"] }
        acceptFirstMouse()
        let start = base(CGPoint(x: frame.midX, y: frame.midY), in: window)
        let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(start).map { "\(type(of: $0))" } ?? ""
        let count = max(2, steps)
        let tick = 1.0 / 60
        send(.leftMouseDown, at: start, in: window)
        held = (window, start)
        for step in 1...count {
            let t = CGFloat(step) / CGFloat(count)
            let at = NSPoint(x: start.x + dx * t, y: start.y - dy * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(step) * tick) {
                MainActor.assumeIsolated {
                    send(.leftMouseDragged, at: at, in: window)
                    held = (window, at)
                }
            }
        }
        if !hold {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(count) * tick) {
                MainActor.assumeIsolated { _ = release(in: browser) }
            }
        }
        return ["from": ["x": frame.midX, "y": frame.midY], "dy": dy, "steps": count, "hit": hit, "hold": hold,
                "how": how, "ms": Int((0.1 + Double(count) * tick) * 1000),
                "active": NSApp.isActive, "key": window.isKeyWindow]
    }

    /// A press and a release at `point` (window base coordinates) in any of
    /// the app's windows — a popover's too (DoorHand) — sent the way `how`
    /// says. Answers with what was under the pointer.
    static func tap(at point: NSPoint, in window: NSWindow) -> [String: Any] {
        acceptFirstMouse()
        let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(point).map { "\(type(of: $0))" } ?? ""
        send(.leftMouseDown, at: point, in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { send(.leftMouseUp, at: point, in: window) }
        }
        return ["at": ["x": point.x, "y": point.y], "how": how, "hit": hit, "window": window.windowNumber]
    }

    /// A click on the row's middle — or, with `cross`, on its cross, which
    /// answers only while the row is under the pointer (`hover` first).
    static func click(_ tab: Tab, cross: Bool = false, in browser: Browser) -> [String: Any] {
        guard let window = window(of: browser) else { return ["error": "no window"] }
        guard let frame = Self.frame(of: tab, in: browser) else { return ["error": "row \(Bench.short(tab)) is not laid out"] }
        acceptFirstMouse()
        // The cross: 15 points square, 8 in from the row's trailing edge.
        let at = base(CGPoint(x: cross ? frame.maxX - 15.5 : frame.midX, y: frame.midY), in: window)
        send(.leftMouseDown, at: at, in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { send(.leftMouseUp, at: at, in: window) }
        }
        return ["at": ["x": frame.midX, "y": frame.midY], "how": how]
    }

    /// The pointer resting on the row's middle (or, with nil, at the
    /// column's top-left corner, over no row), told to the view under it.
    static func hover(_ tab: Tab?, in browser: Browser) -> [String: Any] {
        // A synthetic move reaches the view but not SwiftUI's hover, which
        // listens to the window's tracking areas: the row is told as well.
        SideRowHover.shared.forced = tab?.id
        guard let window = window(of: browser), let view = window.contentView else { return ["error": "no window"] }
        var point = CGPoint(x: 2, y: 2)
        if let tab {
            guard let frame = Self.frame(of: tab, in: browser) else { return ["error": "row \(Bench.short(tab)) is not laid out"] }
            point = CGPoint(x: frame.midX, y: frame.midY)
        }
        let at = base(point, in: window)
        for type in [NSEvent.EventType.mouseMoved] {
            guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0) else { continue }
            (view.hitTest(at) ?? view).mouseMoved(with: event)
        }
        return ["at": ["x": point.x, "y": point.y]]
    }

    /// The window as WindowServer holds it, to a PNG — nothing activated,
    /// nothing brought forward (a probe takes no one's focus) — cut to the
    /// column's width plus `extra` points of the page beside it.
    static func picture(to path: String, extra: CGFloat, in browser: Browser) -> [String: Any] {
        guard let window = window(of: browser) else { return ["error": "no window"] }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return ["error": "no image"] }
        let scale = CGFloat(image.width) / max(1, window.frame.width)
        let width = min(CGFloat(image.width), (browser.prefs.sideWidth + extra) * scale)
        let cut = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: CGFloat(image.height))) ?? image
        let rep = NSBitmapImageRep(cgImage: cut)
        guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
        return ["path": path, "size": [cut.width, cut.height]]
    }

    /// Let go of the row in the hand, wherever it is.
    static func release(in browser: Browser) -> [String: Any] {
        guard let (window, at) = held else { return ["error": "nothing in the hand"] }
        held = nil
        send(.leftMouseUp, at: at, in: window)
        return ["released": true]
    }
}

/// The row the bench says the pointer is resting on (`sections hover ID`),
/// so its cross shows in a picture of a probe nobody is pointing at.
@MainActor
final class SideRowHover: ObservableObject {
    static let shared = SideRowHover()
    @Published var forced: Tab.ID?
}
