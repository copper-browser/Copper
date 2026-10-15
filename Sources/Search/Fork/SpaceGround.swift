import SwiftUI

// The column's ground, as one surface.
//
// Arc's sidebar background never slides. Swipe between two spaces and the
// favourites, the title and the rows travel, but the colour under them
// changes in place — salmon becomes sage across the whole column at once,
// with no edge between the two. So the ground here is one view that is
// always drawn live, never pictured: at rest it is the current space's
// theme; while a slide or a swipe is on it is the outgoing theme blended
// towards the incoming one by the slide's progress. Two plain themes
// (colours and gradients) are morphed stop by stop, so a flat salmon turns
// into a three-stop gradient as one surface; anything with a picture is
// crossfaded; an animated space keeps the column's one scene, which mixes
// its own colours (see AnimatedBackdrop) and fades in or out against a
// still neighbour.
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
struct SpaceGround: View, Animatable {
    var from: SpaceTheme
    var to: SpaceTheme
    /// Which spaces these are the looks of — the scene keeps a clock per key.
    var fromKey: String
    var toKey: String
    var t: CGFloat
    let dark: Bool

    /// Animatable, so a timed slide's `withAnimation { phase = 1 }` runs
    /// this body with every value in between rather than jumping the
    /// colours from one end to the other.
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        let x = Double(min(1, max(0, t)))
        ZStack {
            if from.simple, to.simple {
                // One surface changing colour: the stops move, nothing fades.
                ThemeBackdrop.Colour(theme: from.mixed(to, x), dark: dark)
            } else {
                // A picture (or a scene's own still colour) cannot be morphed
                // into something else, so the incoming ground fades in over
                // the outgoing one — both drawn live, both whole-column, so
                // there is still no edge, only a change.
                ThemeBackdrop.Still(theme: from, dark: dark)
                if x > 0.001 { ThemeBackdrop.Still(theme: to, dark: dark).opacity(x) }
            }
            Scene(from: from, to: to, fromKey: fromKey, toKey: toKey, x: x, dark: dark)
            ThemeBackdrop.Veil(tone: from.tone + (to.tone - from.tone) * x,
                               grain: from.grain + (to.grain - from.grain) * x)
        }
        .clipped()
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
                // Both animated: the shader mixes the two by the progress.
                drive.look = a
                drive.toward = b
                drive.x = x
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
    @ObservedObject private var slide = SpaceSlide.shared
    @ObservedObject private var spaces = Spaces.shared

    init(browser: Browser, dark: Bool) {
        self.browser = browser
        self.dark = dark
    }

    var body: some View {
        let space = spaces.space(in: browser)
        let on = slide.sliding && slide.owner === browser
        let from = on ? slide.from ?? space : space
        let to = on ? slide.to ?? space : space
        SpaceGround(from: from.look, to: to.look, fromKey: from.id.uuidString, toKey: to.id.uuidString,
                    t: on ? slide.phase : 1, dark: dark)
    }
}
