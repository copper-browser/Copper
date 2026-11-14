import AppKit
import Combine
import ObjectiveC
import SwiftUI

/// The one owner of the Move-in sheet.
///
/// The sheet was a SwiftUI `.sheet` on the page area (`SplitStage`), which
/// exists once per window and is rebuilt whenever a window's page goes away
/// (a tab taken by another window, the last tab closed). So with two windows
/// two sheets came up for one click, and any rebuild dismissed the sheet and
/// presented it again mid-move — the cycling, with two states drawn over each
/// other while one sheet faded out and the next faded in. Here the sheet is
/// an AppKit sheet on one window, begun when `Flow.open` turns on and ended
/// when it turns off, and nothing else can present or dismiss it. It keeps
/// one size while it is up (only a resize of its window changes it), so a
/// change of phase never moves or re-centres it.
@MainActor
final class FlowPresenter: NSObject {
    static let shared = FlowPresenter()

    /// The sheet's width; its height is its step's (`want`), within the
    /// window it hangs from. Fork (move-in-polish): it was always 640, so a
    /// three-line summary sat in a tall empty sheet.
    static let width: CGFloat = 560
    static let idealHeight: CGFloat = 640
    static let maxHeight: CGFloat = 720
    static let minHeight: CGFloat = 240
    /// What the sheet's content asks for (`FlowSheet` measures it).
    private var wanted: CGFloat?

    private var sheet: FlowSheetWindow?
    private weak var host: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var watching: [NSObjectProtocol] = []
    private var started = false

    var showing: Bool { sheet != nil }
    var sheetWindow: NSWindow? { sheet }
    var hostWindow: NSWindow? { host }

    /// Begins watching `Flow.open`. Called once, from `Flow.init`.
    func start(_ flow: Flow) {
        guard !started else { return }
        started = true
        // The next turn of the run loop, not inside whatever transaction
        // flipped `open` (Settings closing, a menu): the sheet is begun on
        // its own, with nothing animating around it.
        flow.$open
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak flow] open in
                guard let self, let flow else { return }
                if open { self.present(flow) } else { self.dismiss(flow) }
            }
            .store(in: &bag)
        // ⌘Q (and a SIGTERM, which headless takes as ⌘Q) with the sheet up:
        // the sheet goes first, so nothing is left hanging off a window that
        // is being torn down.
        Self.endBeforeQuit()
    }

    /// ⌘Q (the menu, the key, a SIGTERM in headless, an update's relaunch)
    /// with the sheet up was refused without a word: quitting closes every
    /// window first, and a window with a sheet attached will not close. So
    /// every quit ends the sheet first, then goes on as it would have —
    /// `terminate:` itself, which all of those paths call, wrapped once.
    private static func endBeforeQuit() {
        let selector = #selector(NSApplication.terminate(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        typealias Terminate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Terminate.self)
        let wrapped: @convention(block) (AnyObject, AnyObject?) -> Void = { app, sender in
            if Thread.isMainThread {
                MainActor.assumeIsolated { FlowPresenter.shared.endForQuit() }
            }
            original(app, selector, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapped))
    }

    /// The height the sheet takes over a window this tall: as much as it
    /// wants, but never past the window's edges, so a small window scrolls
    /// the middle of the sheet rather than clipping it.
    static func height(for host: NSWindow?, wanting wanted: CGFloat? = nil) -> CGFloat {
        let ideal = min(wanted ?? idealHeight, maxHeight)
        guard let host else { return max(minHeight, ideal) }
        let room = host.contentLayoutRect.height - 24
        return max(minHeight, min(ideal, room))
    }

    /// The content's height for this step. Changes under a few points are
    /// noise from text settling, not a new step.
    func want(_ height: CGFloat) {
        let height = height.rounded(.up)
        guard abs((wanted ?? 0) - height) > 4 else { return }
        wanted = height
        fit()
    }

    private func present(_ flow: Flow) {
        if sheet != nil {
            flow.log("present-skipped", "already up")
            return
        }
        guard let (window, browser) = target(for: flow.requester) else {
            flow.log("present-failed", "no browser window")
            // Nothing to hang it from; say so rather than leave `open` on
            // with no sheet, which would block the next try.
            flow.close()
            return
        }
        wanted = nil
        let size = NSSize(width: Self.width, height: Self.height(for: window))
        let content = NSHostingController(rootView: FlowSheet(browser: browser))
        // The sheet's size is ours, never the content's: a phase that draws
        // less does not shrink it, so nothing jumps.
        content.sizingOptions = []
        let panel = FlowSheetWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .documentWindow
        panel.backgroundColor = Palette.NS.ground
        panel.contentViewController = content
        panel.setContentSize(size)
        panel.onCancel = { [weak flow] in flow?.close() }
        panel.setAccessibilityLabel("Move in")
        sheet = panel
        host = window
        watch(window, flow: flow)
        window.beginSheet(panel) { _ in }
        flow.log("present", "window \(window.windowNumber) \(Int(size.width))×\(Int(size.height))")
    }

    /// Asked for again while it is up — ⌘K or the menu in another window:
    /// the window it hangs from comes forward, so the person sees the sheet
    /// rather than nothing happening.
    func raise() {
        guard let sheet, let host else { return }
        Flow.shared.log("present-skipped", "already up on window \(host.windowNumber)")
        if NSApp.keyWindow !== sheet {
            host.makeKeyAndOrderFront(nil)
            sheet.makeKey()
        }
    }

    private func dismiss(_ flow: Flow) {
        guard let panel = sheet else { return }
        sheet = nil
        unwatch()
        if let host, host.attachedSheet === panel {
            host.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        host = nil
        flow.log("dismiss")
    }

    /// Quitting: end the sheet without a fuss. `Flow.open` follows.
    func endForQuit() {
        guard sheet != nil else { return }
        Flow.shared.log("quit")
        Flow.shared.close()
        dismiss(Flow.shared)
    }

    /// The window to hang the sheet from: the asking window's, else the
    /// browser window in front, else the first.
    private func target(for requester: Browser?) -> (NSWindow, Browser)? {
        var candidates: [Browser] = []
        if let requester { candidates.append(requester) }
        if let key = Windows.owner(of: NSApp.keyWindow) { candidates.append(key) }
        candidates.append(Windows.current)
        candidates.append(contentsOf: Windows.all)
        for browser in candidates {
            if let window = Windows.window(of: browser), window.attachedSheet == nil {
                return (window, browser)
            }
        }
        // Every window already has a sheet of its own; queue on the first.
        if let browser = candidates.first, let window = Windows.window(of: browser) { return (window, browser) }
        return nil
    }

    private func watch(_ window: NSWindow, flow: Flow) {
        let center = NotificationCenter.default
        watching.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        })
        watching.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak flow] _ in
            MainActor.assumeIsolated { flow?.close() }
        })
    }

    private func unwatch() {
        watching.forEach { NotificationCenter.default.removeObserver($0) }
        watching.removeAll()
    }

    /// The window it hangs from changed size, or the step did: the sheet's
    /// height follows, within its bounds, about the same centre (where macOS
    /// puts a sheet). Its width never changes.
    private func fit() {
        guard let sheet, let host else { return }
        let height = Self.height(for: host, wanting: wanted)
        guard abs(sheet.contentLayoutRect.height - height) > 0.5 else { return }
        let old = sheet.frame
        let outer = sheet.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height)).size
        sheet.setFrame(NSRect(x: old.midX - outer.width / 2, y: old.midY - outer.height / 2, width: outer.width, height: outer.height), display: true)
        Flow.shared.log("resize", "\(Int(Self.width))×\(Int(height))")
    }

    // MARK: - bench

    /// Where the sheet is and what it hangs from, for `bench flow state`:
    /// one sheet across every window, and a size that stays put.
    func describe() -> [String: Any] {
        var out: [String: Any] = ["showing": sheet != nil]
        if let sheet {
            out["sheet"] = [Int(sheet.frame.width), Int(sheet.frame.height)]
            out["sheetVisible"] = sheet.isVisible
            out["attached"] = host?.attachedSheet === sheet
        }
        if let host {
            out["host"] = host.windowNumber
            out["hostSize"] = [Int(host.frame.width), Int(host.frame.height)]
        }
        // Every sheet hanging off any window of the app: the one rule is
        // that this is never more than one Move-in sheet.
        let attached = NSApp.windows.compactMap { $0.attachedSheet }
        out["attachedSheets"] = attached.count
        out["flowSheets"] = NSApp.windows.filter { $0 is FlowSheetWindow && $0.isVisible }.count
        return out
    }

    /// The sheet's content as a PNG, drawn the way it is on screen in the
    /// app's current appearance, at 2× whatever the screen is (a review copy
    /// is as sharp on a 1× display). Never brings anything to the front.
    func shot(to path: String) -> [String: Any] {
        guard let sheet, let view = sheet.contentView else { return ["error": "the sheet is not up"] }
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return ["error": "could not draw the sheet"] }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return ["error": "could not encode the picture"] }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return ["error": error.localizedDescription] }
        return ["path": path, "size": [Int(view.bounds.width), Int(view.bounds.height)],
                "appearance": view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""]
    }

    /// A key pressed on the sheet, as a real key event (`bench flow key`):
    /// Escape, Return, Tab. Goes through the window as a press would.
    func press(_ key: String) -> [String: Any] {
        guard let sheet else { return ["error": "the sheet is not up"] }
        // `cmd-w`, `cmd-k`, `cmd-t`, `cmd-comma`…: a ⌘ shortcut typed with
        // the sheet in front, handed in where a real press comes in
        // (NSApp.sendEvent: the app's key monitor, then the menus), so what
        // it does behind the sheet is what a person would get.
        if key.lowercased().hasPrefix("cmd-") {
            let name = String(key.lowercased().dropFirst(4))
            let character = name == "comma" ? "," : name
            guard character.count == 1, let first = character.first else { return ["error": "cmd- takes one key: cmd-w, cmd-k, cmd-comma…"] }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheet.windowNumber, context: nil,
                    characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: first == "," ? 43 : Bench.keyCode(for: first)
                ) else { continue }
                NSApp.sendEvent(event)
            }
            return ["pressed": key]
        }
        let table: [String: (UInt16, String)] = ["escape": (53, "\u{1B}"), "return": (36, "\r"), "tab": (48, "\t")]
        guard let (code, characters) = table[key.lowercased()] else { return ["error": "key is escape, return, tab or cmd-KEY"] }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ) else { continue }
            if type == .keyDown, sheet.performKeyEquivalent(with: event) { continue }
            sheet.sendEvent(event)
        }
        return ["pressed": key]
    }
}

/// The sheet's own window: Escape is Close, whatever has focus inside it.
final class FlowSheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}


/// The keyboard while Move in is up (`App.swift` `take()` asks first). The
/// sheet covers its window, so the window's shortcuts wait: ⌘W closes the
/// sheet, as it closes Settings, and the rest — ⌘T, ⌘K, ⌘L, ⌘N, ⌘, … — do
/// nothing, rather than closing a tab or opening a launcher behind the sheet
/// where nobody sees it. ⌘Q, ⌘H, ⌘M, ⌘` and editing (⌘C, ⌘V, ⌘X, ⌘A, ⌘Z)
/// stay the system's; a key without ⌘ (Escape, Return, Tab, Space) is the
/// sheet's own and goes to it untouched.
@MainActor
enum FlowKeys {
    static let passed: Set<String> = ["q", "h", "m", "`", "~", "c", "v", "x", "a", "z"]

    /// nil: not typed on the sheet. true: taken here. false: the sheet's or
    /// the system's — hand it on as it is.
    static func take(_ event: NSEvent) -> Bool? {
        guard event.type == .keyDown, let sheet = FlowPresenter.shared.sheetWindow,
              event.window === sheet || (event.window == nil && NSApp.keyWindow === sheet) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "w", flags.isDisjoint(with: [.option, .control]) {
            Flow.shared.log("key", "⌘W closes the sheet")
            Flow.shared.close()
            return true
        }
        if passed.contains(key) { return false }
        Flow.shared.log("key", "⌘\(key) waits behind the sheet")
        return true
    }
}
