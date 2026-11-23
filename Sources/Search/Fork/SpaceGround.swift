import AppKit
import SwiftUI

// The column's ground, as one surface.
//
// Arc's sidebar background never slides. Swipe between two spaces and the
// favourites, the title and the rows travel, but the colour under them
// changes in place — salmon becomes sage across the whole column at once,
// with no edge between the two. So the ground here is one view that is
// always drawn live, never pictured: at rest it is the current space's
// theme; while a slide or a swipe is on it is the outgoing theme fading
// out over the incoming one by the slide's progress; an animated space keeps
// the column's one scene, which mixes its own colours (see AnimatedBackdrop)
// and fades in or out against a still neighbour.
//
// Fork (space-switch perf): each space's ground is a still layer, drawn once
// when the slide starts, and only the outgoing one's opacity moves. The
// ground used to be redrawn on every frame of a slide — gradient, picture,
// mask, tone and grain, window-wide since the page became a card on it —
// and a click's slide sent the scene a new mix on every frame too.
//
// It is plain SwiftUI, sitting as the column's `.background` inside the
// window's own hosting view — the one that already ignores the safe area,
// so the ground runs under the title bar's band where the lights are. An
// earlier version (#18) put it in an NSHostingView of its own so it could
// be hidden for a picture; a hosting view nested like that insets its
// content by the window's safe area, and the top 28–32 points of the
// column came out as the window's white. Nothing here is ever pictured, so
// there is no host and nothing to inset.

/// Two themes and how far between them: 0 is all `from`, 1 all `to`. At
/// rest both are the current space's.
struct SpaceGround: View {
    var from: SpaceTheme
    var to: SpaceTheme
    /// Which spaces these are the looks of — the scene keeps a clock per key.
    var fromKey: String
    var toKey: String
    var t: CGFloat
    let dark: Bool
    /// Fork (page-frame): a picture's width, when the ground is the window's (ThemeBackdrop.Still).
    var span: CGFloat? = nil
    /// Fork (sheer): the window's glass is under this ground — a space that
    /// clears (Sheer.clears) is its colour laid thin over it.
    var sheer = false

    /// The grounds on screen, the incoming first: one at rest, two while a
    /// slide is on. Keyed by space, so the ground on screen when a slide
    /// starts is the same view as it fades out — nothing is drawn again.
    private var layers: [Layer] {
        let incoming = Layer(key: toKey, theme: to, incoming: true)
        return fromKey == toKey ? [incoming] : [incoming, Layer(key: fromKey, theme: from, incoming: false)]
    }

    private struct Layer: Identifiable {
        let key: String
        let theme: SpaceTheme
        let incoming: Bool
        var id: String { key }
    }

    var body: some View {
        let x = Double(min(1, max(0, t)))
        ZStack {
            // The outgoing ground fades out over the incoming one, both whole,
            // so there is no edge, only a change. A timed slide animates `t`:
            // SwiftUI moves the one opacity, frame by frame, and runs no body.
            ForEach(layers) { layer in
                Still(theme: layer.theme, dark: dark, span: span, sheer: sheer && Sheer.clears(layer.theme))
                    .equatable()
                    .opacity(layer.incoming ? 1 : 1 - x)
            }
            // Fork (page-frame): as wide as the column, never the window —
            // the scene is a WebGL page, and under the page card only its
            // margin would show.
            Scene(from: from, to: to, fromKey: fromKey, toKey: toKey, x: x, dark: dark)
                .frame(width: span)
                .mask { if let span { ThemeBackdrop.Still.fade(span) } else { Rectangle() } }
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(layers) { layer in
                let thin = sheer && Sheer.clears(layer.theme)
                // Fork (sheer): the tone as thin as the colour, and no grain
                // over glass — the overlay grain greyed it to a flat sheet.
                Veil(tone: layer.theme.tone * (thin ? Sheer.tint : 1), grain: thin ? 0 : layer.theme.grain)
                    .equatable()
                    .opacity(layer.incoming ? 1 : 1 - x)
            }
        }
        .clipped()
    }

    /// One still ground on its own, as `body` stacks it (GroundRide).
    static func whole(_ theme: SpaceTheme, dark: Bool, span: CGFloat?, sheer: Bool = false) -> some View {
        let thin = sheer && Sheer.clears(theme)
        return ZStack {
            Still(theme: theme, dark: dark, span: span, sheer: thin)
            Veil(tone: theme.tone * (thin ? Sheer.tint : 1), grain: thin ? 0 : theme.grain)
        }
        .clipped()
    }

    /// One space's colour, gradient or picture, redrawn only when the theme does.
    private struct Still: View, Equatable {
        let theme: SpaceTheme
        let dark: Bool
        let span: CGFloat?
        /// Fork (sheer): the colour alone, thin, over the window's glass.
        var sheer = false
        var body: some View {
            if sheer {
                ThemeBackdrop.Colour(theme: theme, dark: dark).opacity(Sheer.tint)
            } else {
                ThemeBackdrop.Still(theme: theme, dark: dark, span: span)
            }
        }
    }

    /// One space's tone and grain, the same.
    private struct Veil: View, Equatable {
        let tone: Double
        let grain: Double
        var body: some View { ThemeBackdrop.Veil(tone: tone, grain: grain) }
    }

    /// The column's scene: one web view for the column's whole life (see
    /// AnimatedBackdrop), told which look to draw and how far to mix towards
    /// the other, and faded against a still neighbour.
    private struct Scene: View {
        let from: SpaceTheme
        let to: SpaceTheme
        let fromKey: String
        let toKey: String
        let x: Double
        let dark: Bool
        @ObservedObject private var spaces = Spaces.shared
        /// The scene is a second content process running WebGL: at launch it
        /// waits for the restored page to draw first (Fork/Launch.swift); the
        /// still ground under it shows until then.
        @ObservedObject private var launch = Launch.shared

        var body: some View {
            if launch.settled, BackdropScene.folder != nil, spaces.all.contains(where: { $0.look.motion != nil }) {
                let a = BackdropScene.Look(theme: from, dark: dark, key: fromKey)
                let b = BackdropScene.Look(theme: to, dark: dark, key: toKey)
                BackdropWeb.Host(drive: drive(a, b))
                    .opacity(a != nil && b != nil ? 1 : a != nil ? 1 - x : x)
                    .allowsHitTesting(false)
            }
        }

        private func drive(_ a: BackdropScene.Look?, _ b: BackdropScene.Look?) -> BackdropScene.Drive {
            var drive = BackdropScene.Drive(look: a ?? b, fade: SpaceSlide.duration + 0.08)
            if let a, let b, a != b {
                if x > 0, x < 1 {
                    // Both animated, under the fingers: the shader mixes the
                    // two by how far they have come.
                    drive.look = a
                    drive.toward = b
                    drive.x = x
                } else {
                    // A click's slide: one change, which the page fades over
                    // `fade` on its own clock (Fork: space-switch perf).
                    drive.look = x >= 1 ? b : a
                }
            } else if a == nil, let b {
                // Still to animated: the scene is the incoming look from the
                // first frame, and fades in over the still ground.
                drive.look = b
            }
            return drive
        }
    }
}

/// The live column's ground: the current space at rest, the slide's two
/// spaces while one is on in this window. One `SpaceGround` whatever the
/// state — not one per branch — so the view keeps its identity when a slide
/// ends and the scene's web view inside it is never made twice.
struct SpaceGroundView: View {
    let browser: Browser
    let dark: Bool
    /// Fork (page-frame): the column's width when this is the window's ground.
    var span: CGFloat? = nil
    /// Fork (sheer): the window's ground is glass (Fork/Sheer.swift).
    var sheer = false
    @ObservedObject private var slide = SpaceSlide.shared
    @ObservedObject private var spaces = Spaces.shared

    init(browser: Browser, dark: Bool, span: CGFloat? = nil, sheer: Bool = false) {
        self.browser = browser
        self.dark = dark
        self.span = span
        self.sheer = sheer
    }

    var body: some View {
        let space = spaces.space(in: browser)
        let on = slide.sliding && slide.owner === browser
        let from = on ? slide.from ?? space : space
        let to = on ? slide.to ?? space : space
        // Fork (r7 space): a click's switch between two still grounds — the
        // new one is the ground from its first frame, and the old one fades
        // out over it as a layer of its own, in the render server
        // (GroundRide). The fade was SwiftUI's: the window-wide ground put
        // together again on the main thread in every frame of the slide,
        // ~30 of a switch's ~90 ms. A scene mixes its own (above), so a
        // switch to or from an animated space fades as it did.
        let ride = on && slide.riding && from.id != to.id && from.look.motion == nil && to.look.motion == nil
        let out = ride ? to : from
        // Fork (sheer): the glass only while a space on screen clears; its
        // side of light and dark is the arriving column's, so its ink reads.
        let glass = sheer && (Sheer.clears(from.look) || Sheer.clears(to.look))
        SpaceGround(from: out.look, to: to.look, fromKey: out.id.uuidString, toKey: to.id.uuidString,
                    t: on && !ride ? slide.phase : 1, dark: dark, span: span, sheer: glass)
            .overlay { GroundRide(leaving: ride ? from.look : nil, serial: slide.serial, dark: dark, span: span, sheer: glass) }
            .background { if glass { Glass(dark: SpaceTint(theme: to.look, dark: dark).dark) } }
    }
}

/// The ground being left by a click's switch, whole (colour or picture,
/// tone, grain), over the new one and fading out on the slide's curve — one
/// Core Animation fade of one layer. Always there, hidden and empty at rest,
/// so a switch adds no view to the window: it only fills this one.
struct GroundRide: NSViewRepresentable {
    let leaving: SpaceTheme?
    let serial: Int
    let dark: Bool
    let span: CGFloat?
    var sheer = false
    static let fadeKey = "copper.ground.ride"

    final class Box: NSView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        private(set) var riding: Int?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            isHidden = true
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The ground of slide `serial` on its way out, or nil: at rest.
        func show(_ leaving: SpaceTheme?, serial: Int, dark: Bool, span: CGFloat?, sheer: Bool = false) {
            guard let leaving else {
                guard riding != nil else { return }
                riding = nil
                isHidden = true
                layer?.removeAnimation(forKey: GroundRide.fadeKey)
                host.rootView = AnyView(EmptyView())
                return
            }
            guard riding != serial else { return }
            riding = serial
            host.rootView = AnyView(SpaceGround.whole(leaving, dark: dark, span: span, sheer: sheer))
            isHidden = false
            layer?.add(GroundRide.fade(), forKey: GroundRide.fadeKey)
        }
    }

    func makeNSView(context: Context) -> Box { Box(frame: .zero) }

    func updateNSView(_ box: Box, context: Context) { box.show(leaving, serial: serial, dark: dark, span: span, sheer: sheer) }

    /// Out, on the slide's curve, and held out until the slide takes it away.
    static func fade() -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = SpaceSlide.duration
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        return fade
    }
}
