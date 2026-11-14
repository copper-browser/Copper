import AppKit
import WebKit

// Real input. A click made here is an NSEvent delivered to the web view
// the way the window would deliver one, so the page sees a trusted event
// with the same hit-testing, focus and default actions a finger would get —
// which is what separates "the agent clicked" from "a script called
// element.click()", and what makes menus, editors and canvas apps work.
//
// Points arrive in the web view's coordinate space, CSS pixels from the
// top-left of the viewport (the snapshot and screenshots are both taken at
// 1× so they agree). AppKit wants window points with y up; the maths is here
// and nowhere else.

enum Input {
    /// A view can only take events while it has a window.
    @MainActor static func canPost(to web: WKWebView) -> Bool {
        web.window != nil && !web.isHiddenOrHasHiddenAncestor && web.bounds.width > 0
    }

    /// The web view takes first responder in its own window, and that is
    /// all: an agent never brings a window forward, never takes key from
    /// the window you are typing in, never activates the app. Events sent to
    /// a view in a window that is not key still land — that is how agents
    /// drove Copper from a terminal in front of it all along. A backstage
    /// window (Backstage.swift) says it is key, so its page counts as focused.
    /// Only when Copper is in front with no key window at all does the
    /// window take key, the way a click would give it.
    @MainActor private static func focus(_ web: WKWebView, in window: NSWindow) {
        if !(window is Backstage.Window), NSApp.isActive, NSApp.keyWindow == nil, window.isVisible, window.canBecomeKey {
            window.makeKey()
        }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
    }

    @MainActor private static func windowPoint(_ web: WKWebView, _ point: CGPoint) -> CGPoint {
        // Points come in with the page's origin, top-left. WKWebView is a
        // flipped view, so that is its own space too; should a build say
        // otherwise, the y is turned here and nowhere else. convert(_:to: nil)
        // then puts it in the window.
        let local = web.isFlipped ? point : CGPoint(x: point.x, y: web.bounds.height - point.y)
        return web.convert(local, to: nil)
    }

    static func modifiers(from names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "alt", "option": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            case "meta", "cmd", "command", "controlormeta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    // MARK: - mouse

    /// WKWebView takes mouse moves from its own tracking area; it has no
    /// `mouseMoved(with:)` of its own, so a move sent there went up the
    /// responder chain to nobody and `:hover` never changed. WebKit's entry
    /// for a move made in code is `_simulateMouseMove:` — asked for by name
    /// first, as with the other private calls here.
    private static let simulateMove = NSSelectorFromString("_simulateMouseMove:")
    private static let afterMouse = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")

    @MainActor
    static func move(_ web: WKWebView, to point: CGPoint) {
        guard let window = web.window else { return }
        let at = windowPoint(web, point)
        guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        if web.responds(to: simulateMove) { web.perform(simulateMove, with: e) } else { web.mouseMoved(with: e) }
    }

    /// Until the web process has taken every mouse event sent so far, or a
    /// beat when WebKit can't say.
    @MainActor
    static func settled(_ web: WKWebView) async {
        guard web.responds(to: afterMouse) else { try? await Task.sleep(nanoseconds: 50_000_000); return }
        typealias After = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(web.method(for: afterMouse), to: After.self)
        let done = Tools.Trail.Latch()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            call(web, afterMouse) { if done.take() { continuation.resume() } }
            // Never longer than half a second: a page busy in a loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if done.take() { continuation.resume() } }
        }
    }

    /// The pointer onto `point` the way a hand brings it: in, then a pixel
    /// further, a frame apart, so `mouseenter` and the `mousemove` a menu
    /// waits for both fire.
    @MainActor
    static func hover(_ web: WKWebView, at point: CGPoint) async {
        move(web, to: point)
        try? await Task.sleep(nanoseconds: 16_000_000)
        move(web, to: CGPoint(x: point.x + 1, y: point.y + 1))
        await settled(web)
    }

    @MainActor
    static func click(_ web: WKWebView, at point: CGPoint, button: String, count: Int, modifiers: NSEvent.ModifierFlags) {
        guard let window = web.window else { return }
        // Focus follows the click, as it would for a person: the window
        // takes key, the web view takes first responder, and only then does
        // the page hear about the mouse.
        focus(web, in: window)
        let at = windowPoint(web, point)
        let (down, up, num): (NSEvent.EventType, NSEvent.EventType, Int) = {
            switch button {
            case "right": return (.rightMouseDown, .rightMouseUp, 1)
            case "middle": return (.otherMouseDown, .otherMouseUp, 2)
            default: return (.leftMouseDown, .leftMouseUp, 0)
            }
        }()
        move(web, to: point)
        for i in 1...max(1, count) {
            let stamp = ProcessInfo.processInfo.systemUptime
            guard let press = NSEvent.mouseEvent(with: down, location: at, modifierFlags: modifiers, timestamp: stamp, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: i, pressure: 1),
                  let release = NSEvent.mouseEvent(with: up, location: at, modifierFlags: modifiers, timestamp: stamp + 0.02, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: i, pressure: 0)
            else { return }
            switch num {
            case 1: web.rightMouseDown(with: press); web.rightMouseUp(with: release)
            case 2: web.otherMouseDown(with: press); web.otherMouseUp(with: release)
            default: web.mouseDown(with: press); web.mouseUp(with: release)
            }
        }
    }

    /// A press, a walk and a release, a frame (16 ms) between each step
    /// and a dwell over the target before letting go: sortable lists and
    /// sliders read the pointer on their own frame clock, and all of it in
    /// one turn of the run loop looked to them like a click.
    @MainActor
    static func drag(_ web: WKWebView, from: CGPoint, to: CGPoint) async {
        guard let window = web.window else { return }
        focus(web, in: window)
        let start = windowPoint(web, from)
        let end = windowPoint(web, to)
        func post(_ type: NSEvent.EventType, _ p: CGPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
            switch type {
            case .leftMouseDown: web.mouseDown(with: e)
            case .leftMouseUp: web.mouseUp(with: e)
            default: web.mouseDragged(with: e)
            }
        }
        func frame(_ ms: UInt64 = 16) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        move(web, to: from)
        await frame()
        post(.leftMouseDown, start)
        await frame(60)
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            await frame()
        }
        // The dwell: once more on the spot, then wait, so a list that moves
        // its items under the pointer has settled on where they go.
        post(.leftMouseDragged, end)
        await frame(120)
        post(.leftMouseUp, end)
        await settled(web)
    }

    // MARK: - keys

    /// Playwright's key names, to the Mac's virtual key codes. Letters and
    /// digits ride on Bench's US map; the rest are here.
    static let special: [String: (code: UInt16, text: String)] = [
        "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "backspace": (51, "\u{8}"), "delete": (117, "\u{7F}"),
        "escape": (53, "\u{1B}"), "esc": (53, "\u{1B}"),
        "arrowleft": (123, "\u{F702}"), "arrowright": (124, "\u{F703}"), "arrowdown": (125, "\u{F701}"), "arrowup": (126, "\u{F700}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
        "f1": (122, "\u{F704}"), "f2": (120, "\u{F705}"), "f3": (99, "\u{F706}"), "f4": (118, "\u{F707}"), "f5": (96, "\u{F708}"),
        "f6": (97, "\u{F709}"), "f7": (98, "\u{F70A}"), "f8": (100, "\u{F70B}"), "f9": (101, "\u{F70C}"), "f10": (109, "\u{F70D}"),
        "f11": (103, "\u{F70E}"), "f12": (111, "\u{F70F}"),
    ]

    /// "Control+Shift+K" → `K` with ⌃⇧ added to `modifiers`: the last part
    /// is the key.
    static func split(_ named: String, modifiers: NSEvent.ModifierFlags) -> (key: String, flags: NSEvent.ModifierFlags) {
        guard named.contains("+"), named.count > 1 else { return (named, modifiers) }
        var parts = named.split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { return (named, modifiers) }
        return (last, modifiers.union(Input.modifiers(from: parts)))
    }

    /// One key, named the way Playwright names them — `Enter`, `ArrowDown`,
    /// `a`, `Shift+Tab`, `Meta+a`.
    @MainActor
    static func key(_ web: WKWebView, _ named: String, modifiers: NSEvent.ModifierFlags) {
        let (name, held) = split(named, modifiers: modifiers)
        var flags = held
        let lower = name.lowercased()
        if let s = special[lower] {
            press(web, code: s.code, text: s.text, flags: flags)
            return
        }
        guard let scalar = name.unicodeScalars.first, name.count == 1 else {
            // Not a key we know by name: type it as text.
            type(web, name)
            return
        }
        let ch = Character(scalar)
        var text = String(ch)
        if ch.isUppercase { flags.insert(.shift) }
        if flags.contains(.shift) { text = text.uppercased() }
        let code = Bench.keyCode(for: ch)
        press(web, code: code, text: text, flags: flags)
    }

    /// Text, a character at a time, each a real key press: what a field
    /// with its own keystroke handling needs.
    @MainActor
    static func type(_ web: WKWebView, _ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" { press(web, code: 36, text: "\r", flags: []); continue }
            let code = Bench.keyCode(for: ch)
            press(web, code: code, text: String(ch), flags: ch.isUppercase ? [.shift] : [])
        }
    }

    @MainActor
    private static func press(_ web: WKWebView, code: UInt16, text: String, flags: NSEvent.ModifierFlags) {
        guard let window = web.window else { return }
        focus(web, in: window)
        let plain = flags.contains(.command) ? unmodified(text) : text
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: stamp, windowNumber: window.windowNumber,
                                          context: nil, characters: text, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: stamp + 0.02, windowNumber: window.windowNumber,
                                        context: nil, characters: text, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code)
        else { return }
        lend(down, to: web)
        // A ⌘ key goes to the page's view, never to its window: the window's
        // shortcuts (⌘W, ⌘T, ⌘L…) are the user's, and an agent's page may be
        // on the user's stage. WebKit gives the page its keydown first.
        if flags.contains(.command) {
            if !web.performKeyEquivalent(with: down) { web.keyDown(with: down) }
            return
        }
        web.keyDown(with: down)
        web.keyUp(with: up)
    }

    private static func unmodified(_ text: String) -> String { text.lowercased() }

    // MARK: - keys the page didn't use

    /// A key an agent pressed and the page it went to.
    private struct Lent {
        let event: NSEvent
        weak var web: WKWebView?
    }

    /// Every key an agent pressed, until it comes back or falls off the end.
    /// A key the page didn't use WebKit sends back up through
    /// `NSApp.sendEvent`, where the app's key monitor would take ⌘W, ⌘T, ⌃Tab
    /// or Escape as the user's — for the window in front, whichever page the
    /// agent was in — and the menus after it. The monitor asks `returned`
    /// first (App.swift `watchKeys`), and an agent's key ends here.
    @MainActor private static var lent: [Lent] = []

    @MainActor
    private static func lend(_ event: NSEvent, to web: WKWebView) {
        lent.append(Lent(event: event, web: web))
        if lent.count > 32 { lent.removeFirst() }
    }

    /// True when `event` is an agent's key coming back unused: nobody else
    /// gets it. A ⌘ shortcut the page left alone is the Edit or Format
    /// menu's in any browser; here it is run on the agent's page itself.
    @MainActor
    static func returned(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let at = lent.firstIndex(where: { PageView.same($0.event, event) }) else { return false }
        let web = lent.remove(at: at).web
        if let web, event.modifierFlags.contains(.command) { edit(web, event) }
        return true
    }

    /// The editing command each ⌘ key stands for, by its key (⇧ after it).
    static let editCommands: [String: String] = [
        "a": "SelectAll", "b": "ToggleBold", "i": "ToggleItalic", "u": "ToggleUnderline",
        "c": "Copy", "x": "Cut", "v": "Paste", "z": "Undo", "z⇧": "Redo",
    ]

    private static let executeEdit = NSSelectorFromString("_executeEditCommand:argument:completion:")

    /// Run the editing command for a ⌘ key on this page's selection —
    /// WebKit's own editor, the one its menu items reach.
    @MainActor
    static func edit(_ web: WKWebView, _ event: NSEvent) {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased() + (event.modifierFlags.contains(.shift) ? "⇧" : "")
        guard let command = editCommands[key] else { return }
        guard web.responds(to: executeEdit) else {
            // The public actions for the ones that have them (selectAll:, copy:, cut:, paste:).
            _ = web.tryToPerform(NSSelectorFromString(command.prefix(1).lowercased() + command.dropFirst() + ":"), with: nil)
            return
        }
        typealias Run = @convention(c) (AnyObject, Selector, NSString, NSString?, @escaping @convention(block) (Bool) -> Void) -> Void
        unsafeBitCast(web.method(for: executeEdit), to: Run.self)(web, executeEdit, command as NSString, nil) { _ in }
    }
}
