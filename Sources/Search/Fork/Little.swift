import AppKit
import Combine
import SwiftUI

// Little Copper (⌥⌘N): one page in a small window. No sidebar and no row of
// tabs — a slim bar with the address and "Open in Copper", which moves the
// page into the browser window as a tab: the same web view, nothing loads
// again. Air Traffic Control can send links from other apps here
// (Fork/AirTraffic.swift).
//
// The page is a Tab in no window's row: it is not in the session, never
// sleeps, and closes with its window. Its navigation and pop-ups are the
// front browser's, as every tab's are, so a link that asks for a new window
// opens a tab there.

@MainActor
final class Little: NSObject, NSWindowDelegate {
    private(set) static var all: [Little] = []

    let tab: Tab
    /// The space whose cookie jar the page uses, and where "Open in Copper" takes it.
    let space: UUID
    let window: NSWindow
    let bar = LittleBar.Model()
    /// "Open in Copper" took the page: closing the window leaves it be.
    private var moved = false
    private var titled: AnyCancellable?

    static let size = NSSize(width: 960, height: 680)

    @discardableResult
    static func open(_ url: URL?, space: UUID? = nil) -> Little {
        let browser = Windows.current
        let space = space.flatMap { id in Spaces.shared.all.contains { $0.id == id } ? id : nil } ?? Spaces.shared.current(in: browser)
        let tab = Spaces.shared.building(for: space) { Tab() }
        browser.prepare(tab)
        let little = Little(tab: tab, space: space)
        all.append(little)
        if let url { tab.go(to: url) }
        little.show()
        return little
    }

    private init(tab: Tab, space: UUID) {
        self.tab = tab
        self.space = space
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Little.size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 300)
        window.backgroundColor = Palette.NS.ground
        window.delegate = self
        window.title = "Little Copper"
        titled = tab.$title.sink { [weak self] title in self?.window.title = title.isEmpty ? "Little Copper" : title }

        // Frames, not constraints: the stage the page may move to lays it out by frame.
        // The bar is the title bar's own height, so its controls line up with the window's buttons.
        let tall = min(40, max(28, (window.contentView?.frame.height ?? window.frame.height) - window.contentLayoutRect.height))
        let content = NSView(frame: NSRect(origin: .zero, size: Little.size))
        let page = tab.web
        page.frame = NSRect(x: 0, y: 0, width: Little.size.width, height: Little.size.height - tall)
        page.autoresizingMask = [.width, .height]
        content.addSubview(page)
        let strip = NSHostingView(rootView: LittleBar(tab: tab, model: bar, height: tall) { [weak self] in self?.toCopper() })
        strip.safeAreaRegions = []
        strip.frame = NSRect(x: 0, y: Little.size.height - tall, width: Little.size.width, height: tall)
        strip.autoresizingMask = [.width, .minYMargin]
        content.addSubview(strip)
        window.contentView = content
        window.initialFirstResponder = page
    }

    private func show() {
        let anchor = Windows.window(of: Windows.current) ?? Links.window
        var frame = window.frame
        if !Headless.on, let visible = (anchor?.screen ?? NSScreen.main)?.visibleFrame {
            frame.size = NSSize(width: min(frame.width, visible.width * 0.8), height: min(frame.height, visible.height * 0.8))
            let step = CGFloat((Little.all.count - 1) % 6) * 24
            frame.origin = NSPoint(x: visible.midX - frame.width / 2 + step, y: visible.midY - frame.height / 2 - step)
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        // The page has the keyboard; an empty one leaves it to the address field.
        if !tab.isBlank { window.makeFirstResponder(tab.web) }
        // Headless parks every window off the displays at the browser's size; this one keeps its own.
        if Headless.on { window.setContentSize(Little.size) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Little.all.removeAll { $0 === self }
        titled = nil
        if !moved { tab.close() }
    }

    /// "Open in Copper": the page, as it is, into the browser window in
    /// front as its active tab — in the space it was opened for.
    func toCopper() {
        let browser = Windows.current
        moved = true
        tab.web.removeFromSuperview()
        window.close()
        if Spaces.shared.all.contains(where: { $0.id == space }) { Spaces.shared.select(space, in: browser) }
        browser.bringIn(tab)
        if let shown = Windows.window(of: browser) ?? (browser.primary ? Links.window : nil) {
            if shown.isMiniaturized { shown.deminiaturize(nil) }
            shown.makeKeyAndOrderFront(nil)
        } else {
            Windows.openFirst("little")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - keys

    /// The app's key monitor, first (App.swift): nil for a window that is
    /// neither Little Copper nor Peek; true when the key was theirs; false
    /// for any other key typed there, which goes to the page as it is —
    /// never to the browser window's own shortcuts.
    static func key(_ event: NSEvent) -> Bool? {
        if let peek = Peek.shown, event.window === peek.panel { return event.type == .keyDown && peek.key(event) }
        guard let little = all.first(where: { $0.window === event.window }) else { return nil }
        return event.type == .keyDown && little.key(event)
    }

    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, event.keyCode == 36 || key == "o" { toCopper(); return true }
        if flags == .command, key == "w" { window.performClose(nil); return true }
        if flags == .command, key == "r" { tab.reload(); return true }
        if flags == .command, key == "[" { tab.back(); return true }
        if flags == .command, key == "]" { tab.forward(); return true }
        if flags == .command, key == "l" { bar.focus += 1; return true }
        if flags == [.command, .shift], key == "c", let url = tab.address {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            return true
        }
        return false
    }

    // MARK: - bench

    /// `little` lists them; `little open [URL]`; `little copper [N]` (Open in
    /// Copper); `little close [N]`; `little shot N PATH` a PNG of the window.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let op = request["op"] as? String ?? "list"
        let words = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
        let pick = words.first.flatMap(Int.init).flatMap { all.indices.contains($0) ? all[$0] : nil } ?? all.last
        switch op {
        case "open":
            Little.open(words.first.flatMap { URL(string: $0) })
        case "copper":
            guard let pick else { return ["error": "no Little Copper"] }
            pick.toCopper()
        case "close":
            guard let pick else { return ["error": "no Little Copper"] }
            pick.window.performClose(nil)
        case "shot":
            guard words.count > 1, let pick else { return ["error": "little shot N PATH"] }
            guard let image = Fork.layered([CGWindowID(pick.window.windowNumber)]),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { return ["error": "no image"] }
            do { try png.write(to: URL(fileURLWithPath: words[1])) } catch { return ["error": "\(error)"] }
            return ["path": words[1], "size": [image.width, image.height]]
        default: break
        }
        return ["littles": all.map { little -> [String: Any] in
            ["url": little.tab.address?.absoluteString ?? "", "title": little.tab.title, "space": little.space.uuidString,
             "visible": little.window.isVisible, "key": little.window.isKeyWindow,
             "size": [Int(little.window.frame.width), Int(little.window.frame.height)]]
        }]
    }
}

extension Browser {
    /// Fork (ardia: windows): a page made outside the row — Little Copper's,
    /// Peek's — joins it beside the tab in front: the same web view, nothing
    /// loaded again.
    func bringIn(_ tab: Tab, foreground: Bool = true) {
        prepare(tab)
        let here = tabs.firstIndex { $0.id == activeID }
        tabs.insert(tab, at: here.map { max($0 + 1, pinnedCount) } ?? tabs.count)
        tab.touch()
        if foreground {
            activeID = tab.id
            editing = false
        }
    }
}

/// Little Copper's bar: back, the address (⌘L, or click it, to type
/// another), and Open in Copper.
struct LittleBar: View {
    final class Model: ObservableObject {
        @Published var focus = 0
    }

    @ObservedObject var tab: Tab
    @ObservedObject var model: Model
    let height: CGFloat
    let toCopper: () -> Void
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The window's own buttons sit here.
            Color.clear.frame(width: 64, height: 1)
            Button { tab.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tab.canGoBack ? Palette.ink : Palette.faint)
            .disabled(!tab.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(typing ? Palette.ink : Palette.muted)
                .focused($typing)
                .onSubmit(go)
                .padding(.horizontal, 10)
                .frame(height: height - 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.wash))
                .accessibilityLabel("Address")
            Button(action: toCopper) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app")
                    Text("Open in Copper")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: height - 6)
                .background(Capsule().fill(Palette.accent))
                .foregroundStyle(Palette.onAccent)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(tab.isBlank)
            .opacity(tab.isBlank ? 0.5 : 1)
            .help("Move this page into the browser window as a tab (⌘O)")
        }
        .padding(.trailing, 8)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .onAppear {
            text = shown
            if tab.isBlank { typing = true }
        }
        .onChange(of: tab.address) { _, _ in if !typing { text = shown } }
        .onChange(of: typing) { _, now in text = now ? (tab.address?.absoluteString ?? "") : shown }
        .onChange(of: model.focus) { _, _ in typing = true }
    }

    private var shown: String { tab.address.map(Address.pretty) ?? "" }

    private func go() {
        guard let url = Google.destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        tab.go(to: url)
        typing = false
    }
}
