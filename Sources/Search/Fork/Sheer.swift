import AppKit
import SwiftUI

// Fork (sheer): the see-through window. The desktop shows, blurred, through
// the column and the margin round the page — macOS's own sidebar material
// (NSVisualEffectView, blending behind the window) under the space's colour
// laid thin over it — while the page card stays as solid as it was. The
// glass is only ever the window's ground: nothing of it is over a web view,
// and the column folded out over a page (Fold.swift) keeps its solid ground,
// since glass there would show the desktop through the page.
//
// Which spaces turn see-through: a colour or a gradient, and the default
// copper picture (it is Copper's plain ground, not something anyone chose).
// A picture of your own or an animated scene is what you chose to look at,
// so it stays as it is, solid.
//
// The solid ground comes back with the setting off, with Reduce transparency
// or Increase contrast on (System Settings › Accessibility › Display), and in
// full screen, where there is no desktop behind the window to show.

@MainActor
final class Sheer: ObservableObject {
    static let shared = Sheer()

    /// Settings › See-through window (Preferences.sheer keeps it in step).
    @Published var chosen = true
    /// Reduce transparency or Increase contrast is on: the solid ground.
    @Published private(set) var refused = Sheer.accessibility()
    /// Windows on their way into, or in, full screen, by number.
    @Published private(set) var full: Set<Int> = []

    /// How much of the space's colour lies over the glass: enough that the
    /// space still reads as its colour, little enough that the desktop shows.
    static let tint = 0.55

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Sheer.shared.refused = Sheer.accessibility() }
        }
        let centre = NotificationCenter.default
        // In as the move to full screen starts, so it lands solid; out once it
        // has left, so the glass never stands over the black of the move.
        centre.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { Sheer.shared.full.insert(window.windowNumber) } }
        }
        centre.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { Sheer.shared.full.remove(window.windowNumber) } }
        }
    }

    static func accessibility() -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast
    }

    /// Whether this window's ground is glass now.
    func on(in browser: Browser) -> Bool {
        let window = Windows.window(of: browser)
        return Sheer.allowed(chosen: chosen, refused: refused,
                             fullScreen: window.map { full.contains($0.windowNumber) || $0.styleMask.contains(.fullScreen) } ?? false)
    }

    static func allowed(chosen: Bool, refused: Bool, fullScreen: Bool) -> Bool { chosen && !refused && !fullScreen }

    /// Whether a space's look turns see-through: its colour or gradient, or
    /// Copper's own default picture. A picture of your own or a scene stays solid.
    static func clears(_ theme: SpaceTheme) -> Bool {
        theme.motion == nil && (theme.image == nil || theme.image == SpaceTheme.copperPicture)
    }

    // MARK: - the window

    /// Panes of glass in each window, by window: a window with any is not
    /// opaque and has a clear background; with none, it is the solid ground again.
    private static var panes: [ObjectIdentifier: Int] = [:]

    static func glazed(_ window: NSWindow) -> Bool { (panes[ObjectIdentifier(window)] ?? 0) > 0 }

    fileprivate static func count(_ window: NSWindow, _ change: Int) {
        let key = ObjectIdentifier(window)
        let now = max(0, (panes[key] ?? 0) + change)
        panes[key] = now == 0 ? nil : now
        dress(window)
    }

    /// The window's own background for what it holds — also asked by
    /// ContentView.dress, which would otherwise paint the ground back in.
    static func dress(_ window: NSWindow) {
        let glass = glazed(window)
        if window.isOpaque == glass { window.isOpaque = !glass }
        let ground = glass ? NSColor.clear : Palette.NS.ground
        if window.backgroundColor != ground { window.backgroundColor = ground }
    }
}

/// macOS's sidebar material, blending what is behind the window. `dark`
/// sets its side of light and dark to the column's (a column toned dark in
/// light mode gets the dark material, so its light ink keeps its contrast);
/// nil follows the window.
struct Glass: NSViewRepresentable {
    var dark: Bool? = nil

    final class Pane: NSVisualEffectView {
        private weak var counted: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== counted else { return }
            if let counted { Sheer.count(counted, -1) }
            counted = window
            if let window { Sheer.count(window, 1) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Pane {
        let pane = Pane()
        pane.material = .sidebar
        pane.blendingMode = .behindWindow
        pane.state = .followsWindowActiveState
        return pane
    }

    func updateNSView(_ pane: Pane, context: Context) {
        let want = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        if pane.appearance?.name != want?.name { pane.appearance = want }
    }
}

/// The top-tab layout's ground: the glass, or the solid ground.
struct StripGround: View {
    let browser: Browser
    @ObservedObject private var sheer = Sheer.shared

    var body: some View {
        if sheer.on(in: browser) { Glass() } else { Palette.ground }
    }
}
