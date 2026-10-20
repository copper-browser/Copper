import SwiftUI

// The space's look, and every surface the column draws over it.
//
// The ground is the space's theme — a colour, a gradient or a picture (see
// `SpaceTheme`), at Arc's strength rather than a pastel wash. Everything on
// top of it is a translucent white or black: the resting favourite a shade
// in, the row under the pointer a shade more, the live pill half-way to
// white. That is how Arc keeps one surface whatever the theme, and it is
// the only way a gradient or a photograph can sit under the rows at all.
// Ink is the theme's own hue taken nearly to black (to white in the dark),
// so a salmon column has warm brown titles, not grey ones.
//
// "Dark" here is the column, not the window. They are the same until a
// theme is toned (or simply chosen) far enough the other way: a column taken
// most of the way to black in light mode is a dark column, and gets light
// ink and white-translucent surfaces, as if the window were dark; a column
// toned to near white in dark mode gets the light column's. The window's own
// appearance is `night`, which only picks the theme's ground.

struct SpaceTint: Equatable { // Equatable: a parked column is redrawn only when its ink changes (SpaceColumns)
    /// The hue the rest of the app knows the space by, or nil for grey.
    let hue: Double?
    /// Whether the column, as drawn, is dark: light ink on it, and white
    /// rather than black for its translucent surfaces.
    let dark: Bool
    /// Whether the window is in dark mode — which of the theme's two
    /// grounds the column is drawn from.
    let night: Bool
    /// What the column is washed in.
    let theme: SpaceTheme

    /// Where the ink changes sides: the luminance at which light and dark
    /// titles read about equally well on the ground (their contrast ratios
    /// cross near 0.2 for inks this deep and this pale).
    static let turn = 0.2

    init(hue: Double?, dark: Bool) {
        self.init(theme: hue.map(SpaceTheme.hue) ?? .plain, dark: dark)
    }

    init(theme: SpaceTheme, dark: Bool) {
        self.init(theme: theme, night: dark, column: theme.toned(dark: dark).luminance < SpaceTint.turn)
    }

    private init(theme: SpaceTheme, night: Bool, column dark: Bool) {
        self.theme = theme
        self.hue = theme.hue
        self.night = night
        self.dark = dark
    }

    /// The same space's tint for a surface that is not the column — a card
    /// on the app's own ground, like ⌘K's rows or Settings › Spaces' tiles —
    /// where the ink has to follow the window, not the column's tone.
    var offColumn: SpaceTint { SpaceTint(theme: theme, night: night, column: night) }

    init(space: Space, dark: Bool) {
        self.init(theme: space.look, dark: dark)
    }

    /// The tint the column is wearing right now.
    @MainActor init(_ scheme: ColorScheme) {
        self.init(space: Spaces.shared.space, dark: scheme == .dark)
    }

    /// The hue at a given strength, or a neutral of the same brightness for a
    /// space that never picked one.
    private func mix(_ saturation: Double, _ brightness: Double) -> Color {
        Color(hue: hue ?? 0, saturation: hue == nil ? 0 : saturation, brightness: brightness)
    }

    /// The column's ground, drawn: colour, gradient or picture, and grain.
    /// Live: this is the column itself, whose scene lasts across spaces
    /// (anything else that wants a theme's ground uses `ThemeBackdrop`).
    var backdrop: ThemeBackdrop { ThemeBackdrop(theme: theme, dark: night, live: true) }
    /// The column of one window. (Fork: windows)
    @MainActor func backdrop(in browser: Browser) -> ThemeBackdrop { ThemeBackdrop(theme: theme, dark: night, live: true, browser: browser) }

    /// One flat colour for the whole column, where a surface beside it has
    /// to match it: the split's gutter, a drop target.
    var ground: Color { theme.flat(dark: night) }

    /// A favourite at rest, the address field: one shade in from the ground.
    var square: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045) }

    /// Under the pointer. A shade more than a favourite at rest, never close
    /// to the live pill.
    var hover: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }

    /// The live row and the live favourite: half-way to white, the page you
    /// are reading looking like paper laid on the column.
    var pill: Color { dark ? Color.white.opacity(0.16) : Color.white.opacity(0.48) }

    /// The live pill's edge, lighter still, so it holds on a pale theme.
    var rim: Color { dark ? Color.white.opacity(0.14) : Color.white.opacity(0.6) }

    /// The soft shadow the live pill lifts off the column with.
    var lift: Color { .black.opacity(dark ? 0.32 : 0.07) }

    /// The space's colour at full strength, for a short mark of it.
    var bar: Color { hue == nil ? Palette.ink.opacity(0.55) : dot }

    /// The only line in the column, and it is half a line at that.
    var hairline: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08) }

    /// The soft square a letter sits on for a site that has no icon yet.
    var chip: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.07) }

    /// A space's colour at full strength: the swatch in the picker, the
    /// split's outline, and what the chips at the foot are thinned from.
    var dot: Color { mix(0.62, night ? 0.86 : 0.70) }

    /// The space's colour as a swatch shows it — in the editor and the
    /// Colour menu: the theme's own colour, a touch fuller and deeper so it
    /// holds on a white popover. `dot` is darker and duller on purpose (it
    /// is thinned for the chips); on a swatch it made yellow olive.
    var swatch: Color {
        guard let hue else { return Color(white: night ? 0.55 : 0.64) }
        let (s, v) = SpaceTheme.strength(hue)
        return Color(hue: hue, saturation: min(1, s + 0.14), brightness: v * (night ? 0.92 : 0.9))
    }

    /// A space's own mark — its letter or symbol — on a chip: the same hue,
    /// dark enough to read on a light square and light enough on a dark one.
    var mark: Color { mix(hue == nil ? 0 : 0.66, dark ? 0.92 : 0.40) }

    /// The square behind a mark, for every space but the current one: the
    /// dot, thinned until it is a colour rather than a button.
    var chipFill: Color { dot.opacity(dark ? 0.30 : 0.22) }
    /// The same square under the pointer.
    var chipLift: Color { dot.opacity(dark ? 0.48 : 0.40) }

    /// Titles: the theme's hue taken nearly to black, or nearly to white in
    /// the dark — warm brown on salmon, the way Arc sets its own.
    var ink: Color { dark ? mix(0.06, 0.96) : mix(0.9, 0.19) }
    var muted: Color { ink.opacity(0.62) }
    var faint: Color { ink.opacity(0.45) }
}
