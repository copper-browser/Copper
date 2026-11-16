import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Search

// A click's space switch travels in the render server (SpaceSlide `core`,
// Fork: r7 space): one Core Animation move per column, nothing left on the
// column's layer afterwards. And the card a page comes in over keeps its
// wash until the page is whole (SplitWaiting) — no white between the two.

@Suite("A space switch's travel is Core Animation's, and leaves nothing behind")
@MainActor
struct SpaceRideTests {
    @Test("The travel is one move on the slide's curve; the layer's own place is home throughout")
    func travelIsOneMove() throws {
        let layer = CALayer()
        SpaceSlide.travel(layer, from: 326, to: 0)
        let move = try #require(layer.animation(forKey: SpaceSlide.rideKey) as? CABasicAnimation)
        #expect(move.keyPath == "transform.translation.x")
        #expect(move.fromValue as? CGFloat == 326 && move.toValue as? CGFloat == 0)
        #expect(move.duration == SpaceSlide.duration)
        #expect(CATransform3DIsIdentity(layer.transform), "dropped mid-way, the rows are home")
    }

    @Test("The band is held to its own edges while it travels, and the layer is as it was once the slide ends")
    func rideLeavesNothing() {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 326, height: 600)
        let slide = SpaceSlide.shared
        slide.ride(layer, from: 326)
        #expect(layer.animation(forKey: SpaceSlide.rideKey) != nil)
        // The mask goes the other way at the same pace: still on screen, so
        // the rows on their way never draw over the page.
        let edge = layer.mask?.animation(forKey: SpaceSlide.rideKey) as? CABasicAnimation
        #expect(edge?.fromValue as? CGFloat == -326)
        slide.ride(layer, from: -326) // a second switch before the first has landed
        #expect((layer.mask?.animation(forKey: SpaceSlide.rideKey) as? CABasicAnimation)?.fromValue as? CGFloat == 326)
        slide.unride()
        #expect(layer.mask == nil && layer.animationKeys() == nil)
    }

    @Test("A layer that has a mask of its own keeps it")
    func ownMaskStays() {
        let layer = CALayer()
        let own = CALayer()
        layer.mask = own
        SpaceSlide.shared.ride(layer, from: 100)
        #expect(layer.mask === own)
        SpaceSlide.shared.unride()
        #expect(layer.mask === own && layer.animationKeys() == nil)
    }

    @Test("The ground being left fades out as one layer on the slide's curve, and is empty and hidden again at rest")
    func groundRide() throws {
        let box = GroundRide.Box(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(box.isHidden && box.layer?.animationKeys() == nil, "at rest: nothing over the ground")
        box.show(SpaceTheme(colors: [.init(r: 0.9, g: 0.5, b: 0.3)]), serial: 1, dark: false, span: 240)
        let fade = try #require(box.layer?.animation(forKey: GroundRide.fadeKey) as? CABasicAnimation)
        #expect(!box.isHidden && fade.keyPath == "opacity" && fade.duration == SpaceSlide.duration)
        #expect(fade.fromValue as? Int == 1 && fade.toValue as? Int == 0 && fade.fillMode == .forwards && !fade.isRemovedOnCompletion,
                "out, and held out until the slide ends")
        box.show(SpaceTheme(colors: [.init(r: 0.9, g: 0.5, b: 0.3)]), serial: 1, dark: false, span: 240) // the same slide, asked again: not started over
        #expect(box.layer?.animation(forKey: GroundRide.fadeKey) === fade)
        box.show(nil, serial: 1, dark: false, span: 240)
        #expect(box.isHidden && box.layer?.animationKeys() == nil)
    }

    /// The top-left of a waiting card, inside its corner: the wash's alpha.
    private func wash(_ host: NSView) -> CGFloat {
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: picture)
        return picture.colorAt(x: picture.pixelsWide / 2, y: 4)?.alphaComponent ?? -1
    }

    @Test("A waiting card's wash stays under the page until its fade-in is over (grey, then the page — never the white plate)")
    func washOutlastsTheFade() async throws {
        _ = NSApplication.shared
        let tab = Tab()
        let web = tab.web
        guard web.unpainted else { return } // a WebKit without the first-frame event shows a page at once
        let host = NSHostingView(rootView: SplitWaiting(tab: tab).frame(width: 240, height: 160))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
        let window = NSPanel(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(wash(host) > 0.9, "before the page has drawn: the card on its wash")
        web.showFirstFrame()
        try await Task.sleep(for: .milliseconds(40))
        #expect(wash(host) > 0.9, "the page is fading in: the wash is still under it")
        try await Task.sleep(for: .milliseconds(Int(PageView.fadeIn * 1000) + 250))
        #expect(wash(host) < 0.1, "the page is whole: nothing left under it")
    }
}
