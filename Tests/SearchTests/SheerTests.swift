import AppKit
import Testing
@testable import Search

// Fork (sheer): which spaces turn see-through, when the window may, and the
// window going non-opaque with its glass and solid again without it.

@Suite("See-through window")
@MainActor
struct SheerTests {
    @Test("A colour, a gradient and Copper's default clear; your own picture and a scene stay solid")
    func whichSpacesClear() {
        #expect(Sheer.clears(.plain))
        #expect(Sheer.clears(SpaceTheme.hue(0.6)))
        #expect(Sheer.clears(SpaceTheme(colors: [.init(r: 0.9, g: 0.4, b: 0.3), .init(r: 0.3, g: 0.4, b: 0.9)], intensity: 0.6)))
        #expect(Sheer.clears(.copper))
        var picture = SpaceTheme.plain
        picture.image = "mine.jpg"
        #expect(!Sheer.clears(picture))
        var scene = SpaceTheme.plain
        scene.motion = .init(style: "ribbons")
        #expect(!Sheer.clears(scene))
    }

    @Test("Off when turned off, under Reduce transparency or Increase contrast, and in full screen")
    func whenAllowed() {
        #expect(Sheer.allowed(chosen: true, refused: false, fullScreen: false))
        #expect(!Sheer.allowed(chosen: false, refused: false, fullScreen: false))
        #expect(!Sheer.allowed(chosen: true, refused: true, fullScreen: false))
        #expect(!Sheer.allowed(chosen: true, refused: false, fullScreen: true))
    }

    @Test("A window with glass is clear; once its last pane goes it is the solid ground again")
    func windowFollowsItsGlass() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        Sheer.dress(window)
        #expect(window.isOpaque && window.backgroundColor == Palette.NS.ground)

        let one = Glass.Pane(), two = Glass.Pane()
        root.addSubview(one)
        root.addSubview(two)
        #expect(!window.isOpaque && window.backgroundColor == .clear)
        one.removeFromSuperview()
        #expect(!window.isOpaque, "one pane still there")
        two.removeFromSuperview()
        #expect(window.isOpaque && window.backgroundColor == Palette.NS.ground)
    }
}
