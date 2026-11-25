import AppKit
import SwiftUI
import WebKit

// Peek: ⇧-click a link and it opens in a card over the page you are on,
// rather than taking you away from it. ⎋ (or a click outside the card)
// puts it away, ⌘↩ keeps it as a tab beside this one, ⌥⌘↩ opens it in a
// split. Settings › General › Where links open can send a pinned tab's
// links to other sites here too, so a pin stays on its own site.
//
// The card is a borderless child window over the browser window, so it
// moves with it and needs nothing from the stage. Its page is a Tab in no
// row until it is kept: then the same web view joins the row
// (Browser.bringIn), and nothing loads again.

@MainActor
final class Peek: NSObject {
    private(set) static var shown: Peek?

    /// A pinned tab's links to another site peek (off by default).
    static var pins: Bool {
        get { Store.settings.bool(forKey: "peek.pins") }
        set { Store.settings.set(newValue, forKey: "peek.pins") }
    }

    let tab: Tab
    let panel: PeekPanel
    private weak var browser: Browser?
    private weak var parent: NSWindow?
    private let card: NSView
    private var watching: [NSObjectProtocol] = []

    /// Browser.decidePolicyFor's link click, ⌘ handled already: ⇧ alone
    /// peeks, and so — opted in — does a plain click in a pinned tab that
    /// leaves its site. Only for a page in the row; a link inside a peek
    /// or a Little Copper goes where it always did.
    static func wants(_ action: WKNavigationAction, from webView: WKWebView, in browser: Browser) -> Bool {
        guard let tab = browser.tab(for: webView) else { return false }
        let flags = action.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .shift { return true }
        guard flags.isEmpty, pins, tab.pin != nil, action.targetFrame?.isMainFrame ?? true,
              let to = action.request.url?.host(), let from = tab.address?.host() else { return false }
        return Fork.brand(to) != Fork.brand(from)
    }

    static func open(_ url: URL, over browser: Browser) {
        shown?.close()
        guard let parent = Windows.window(of: browser) ?? (browser.primary ? Links.window : nil), parent.isVisible else {
            browser.open(url, foreground: true)
            return
        }
        let tab = Spaces.shared.building(for: Spaces.shared.current(in: browser)) { Tab() }
        browser.prepare(tab)
        tab.go(to: url)
        let peek = Peek(tab: tab, browser: browser, parent: parent)
        shown = peek
        peek.show()
    }

    private init(tab: Tab, browser: Browser, parent: NSWindow) {
        self.tab = tab
        self.browser = browser
        self.parent = parent
        panel = PeekPanel(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        card = NSView()
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none

        let size = parent.frame.size
        let dim = PeekDim(frame: NSRect(origin: .zero, size: size))
        dim.autoresizingMask = [.width, .height]
        dim.onClick = { [weak self] point in
            guard let self, !self.card.frame.contains(point) else { return }
            self.close()
        }

        // The card: a shadow under, a rounded clip over its bar and page.
        let inset = NSSize(width: max(48, size.width * 0.07), height: max(36, size.height * 0.06))
        let frame = NSRect(x: inset.width, y: inset.height, width: size.width - 2 * inset.width, height: size.height - inset.height - max(52, size.height * 0.07))
        card.frame = frame
        card.autoresizingMask = [.width, .height]
        card.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        card.shadow = shadow
        let clip = NSView(frame: NSRect(origin: .zero, size: frame.size))
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = Palette.NS.ground.cgColor
        let page = tab.web
        page.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - PeekBar.height)
        page.autoresizingMask = [.width, .height]
        clip.addSubview(page)
        let bar = NSHostingView(rootView: PeekBar(tab: tab,
                                                  keep: { [weak self] in self?.toTab() },
                                                  split: { [weak self] in self?.toSplit() },
                                                  close: { [weak self] in self?.close() }))
        bar.frame = NSRect(x: 0, y: frame.height - PeekBar.height, width: frame.width, height: PeekBar.height)
        bar.autoresizingMask = [.width, .minYMargin]
        clip.addSubview(bar)
        card.addSubview(clip)
        dim.addSubview(card)
        panel.contentView = dim

        let center = NotificationCenter.default
        watching = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, let parent = self.parent { self.panel.setFrame(parent.frame, display: true) } }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ]
    }

    private func show() {
        guard let parent else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = still ? 1 : 0
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tab.web)
        guard !still else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    /// The card goes; the page goes with it unless it was kept.
    func close() { leave(keeping: false) }

    private func leave(keeping: Bool) {
        guard Peek.shown === self else { return }
        Peek.shown = nil
        for token in watching { NotificationCenter.default.removeObserver(token) }
        watching = []
        if keeping { tab.web.removeFromSuperview() } else { tab.close() }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
    }

    /// ⌘↩: kept, as a tab beside the one it was opened from, and gone to.
    func toTab() {
        guard let browser else { return close() }
        leave(keeping: true)
        browser.bringIn(tab)
    }

    /// ⌥⌘↩: kept, beside the page it was opened from, in a split.
    func toSplit() {
        guard let browser else { return close() }
        leave(keeping: true)
        browser.bringIn(tab, foreground: false)
        Split.shared.open(with: tab, in: browser)
    }

    /// Keys typed while the card is key (Little.key): ⎋ and ⌘W put it away,
    /// ⌘↩ keeps it as a tab, ⌥⌘↩ in a split. The rest are the page's.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let enter = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53, flags.isEmpty { close(); return true }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" { close(); return true }
        if flags == .command, enter { toTab(); return true }
        if flags == [.command, .option], enter { toSplit(); return true }
        return false
    }

    // MARK: - bench

    /// `peek` what is up; `peek open URL` over the active tab, as a ⇧-click
    /// would; `peek click SELECTOR [plain]` a real ⇧-click (or a plain
    /// click) on that element of the active tab; `peek key ⎋|⌘↩|⌥⌘↩|⌘W` through the app's key monitor;
    /// `peek tab` (⌘↩); `peek split` (⌥⌘↩); `peek close` (⎋);
    /// `peek pins on|off`.
    static func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "state"
        let arg = request["arg"] as? String ?? ""
        switch op {
        case "open":
            guard let url = URL(string: arg), url.scheme != nil else { return ["error": "peek open URL"] }
            Peek.open(url, over: browser)
        case "click":
            guard let tab = browser.active, let web = tab.built, let window = web.window else { return ["error": "no page to click"] }
            let words = arg.split(separator: " ").map(String.init)
            let held: NSEvent.ModifierFlags = words.contains("plain") ? [] : [.shift]
            let find = "(function(){var e=document.querySelector(\(String(reflecting: words.first ?? "")));if(!e)return null;var r=e.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2];})()"
            web.evaluateJavaScript(find) { answer, _ in
                MainActor.assumeIsolated {
                    guard let spot = answer as? [Double], spot.count == 2 else { return }
                    let inView = NSPoint(x: spot[0], y: web.isFlipped ? spot[1] : web.bounds.height - spot[1])
                    let at = web.convert(inView, to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                        else { continue }
                        if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
                    }
                }
            }
            return ["clicking": arg]
        case "key":
            guard let panel = shown?.panel else { return ["error": "no peek"] }
            var flags: NSEvent.ModifierFlags = []
            if arg.contains("⌘") { flags.insert(.command) }
            if arg.contains("⌥") { flags.insert(.option) }
            let (code, text): (UInt16, String) = arg.hasSuffix("↩") ? (36, "\r") : arg.lowercased().hasSuffix("w") ? (13, "w") : (53, "\u{1b}")
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
            else { return ["error": "no event"] }
            NSApp.postEvent(event, atStart: false)
        case "tab": shown?.toTab()
        case "split": shown?.toSplit()
        case "close": shown?.close()
        case "pins": pins = arg == "on"
        default: break
        }
        return ["showing": shown != nil, "url": shown?.tab.address?.absoluteString ?? "", "title": shown?.tab.title ?? "",
                "key": shown?.panel.isKeyWindow ?? false, "pins": pins,
                "frame": shown.map { [Int($0.panel.frame.width), Int($0.panel.frame.height)] } ?? [],
                "tabs": browser.tabs.count, "active": browser.active?.address?.absoluteString ?? "",
                "split": Split.shared.on(in: browser)]
    }
}

final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The dimmed window under the card; a click on it, outside the card, puts the card away.
final class PeekDim: NSView {
    var onClick: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

/// The card's bar: what the page is, and keep it (as a tab, or in a split) or close it.
struct PeekBar: View {
    static let height: CGFloat = 44

    @ObservedObject var tab: Tab
    let keep: () -> Void
    let split: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Peek" : tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(tab.address?.host() ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            button("rectangle.split.2x1", "Open in Split (⌥⌘↩)", split)
            button("arrow.up.left.and.arrow.down.right", "Open as Tab (⌘↩)", keep)
            button("xmark", "Close (esc)", close)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
