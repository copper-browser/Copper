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
                Still(theme: layer.theme, dark: dark, span: span)
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
                Veil(tone: layer.theme.tone, grain: layer.theme.grain)
                    .equatable()
                    .opacity(layer.incoming ? 1 : 1 - x)
            }
        }
        .clipped()
    }

    /// One space's colour, gradient or picture, redrawn only when the theme does.
    private struct Still: View, Equatable {
        let theme: SpaceTheme
        let dark: Bool
        let span: CGFloat?
        var body: some View { ThemeBackdrop.Still(theme: theme, dark: dark, span: span) }
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
    @ObservedObject private var slide = SpaceSlide.shared
    @ObservedObject private var spaces = Spaces.shared

    init(browser: Browser, dark: Bool, span: CGFloat? = nil) {
        self.browser = browser
        self.dark = dark
        self.span = span
    }

    var body: some View {
        let space = spaces.space(in: browser)
        let on = slide.sliding && slide.owner === browser
        let from = on ? slide.from ?? space : space
        let to = on ? slide.to ?? space : space
        SpaceGround(from: from.look, to: to.look, fromKey: from.id.uuidString, toKey: to.id.uuidString,
                    t: on ? slide.phase : 1, dark: dark, span: span)
    }
}
