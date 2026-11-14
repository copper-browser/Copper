import AppKit
import CoreImage
import ImageIO
import SwiftUI

// What a space looks like: a colour, a gradient, or a picture, laid over the
// whole column the way Arc lays its themes.
//
// Arc stores a theme as one colour or a few, an intensity, and a grain; it
// draws the column as those colours pulled most of the way from white and
// dimmed a touch, which is why its sidebars read as salmon or sage rather
// than as a pastel wash. The same numbers come in from an Arc import, so a
// moved space looks the way it did. A picture goes under the colour, which
// stays on it thinly so the rows keep one ink.
//
// Everything the column draws on top — favourites, hover, the live pill, the
// hairline — is a translucent white or black over this (see `SpaceTint`), so
// it reads the same over a flat colour, a gradient or a photograph.
//
// Over whichever ground it is, the tone lays black or white, and the ink
// follows it (`SpaceTint` reads `toned`): a space taken most of the way to
// black gets light titles even in the light, and one taken to white gets
// dark ones in the dark.

struct SpaceTheme: Codable, Hashable {
    struct Stop: Codable, Hashable {
        var r: Double
        var g: Double
        var b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = min(1, max(0, r))
            self.g = min(1, max(0, g))
            self.b = min(1, max(0, b))
        }

        init(hue: Double, saturation: Double, brightness: Double) {
            let c = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
                .usingColorSpace(.sRGB) ?? .gray
            self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }

        init?(_ color: Color) {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

        var hsb: (h: Double, s: Double, v: Double) {
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            return (c.hueComponent, c.saturationComponent, c.brightnessComponent)
        }

        func mixed(_ other: Stop, _ t: Double) -> Stop {
            Stop(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }

        func scaled(_ k: Double) -> Stop { Stop(r: r * k, g: g * k, b: b * k) }

        /// Relative luminance, 0 for black to 1 for white — what decides
        /// which ink a ground of this colour needs.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// `#e8a07a`, `e8a07a` or `#fa7`; nil for anything else.
        init?(hex: String) {
            var digits = hex.trimmingCharacters(in: .whitespaces)
            if digits.hasPrefix("#") { digits.removeFirst() }
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let n = UInt32(digits, radix: 16) else { return nil }
            self.init(r: Double(n >> 16 & 0xFF) / 255, g: Double(n >> 8 & 0xFF) / 255, b: Double(n & 0xFF) / 255)
        }

        var hex: String {
            String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        static let white = Stop(r: 1, g: 1, b: 1)
        static let black = Stop(r: 0, g: 0, b: 0)
    }

    /// One colour is a flat column; two or three run top-leading to
    /// bottom-trailing.
    var colors: [Stop]
    /// How far the column goes from white towards the colours — Arc's
    /// `intensityFactor`, 0…1.
    var intensity: Double = 0.8
    /// Film grain over the column, 0…1 — Arc's `noiseFactor`.
    var grain: Double = 0
    /// A picture under the colour: a file name in `themes/`.
    var image: String? = nil

    /// A living backdrop instead of a still one: a three.js scene drawn in
    /// the theme's colours (see `AnimatedBackdrop`). Nil is still.
    struct Motion: Codable, Hashable {
        /// Which scene: one of `AnimatedBackdrop.styles`.
        var style: String
        /// How fast it moves, 0…2; 1 is the scene's own pace.
        var speed: Double = 1

        init(style: String, speed: Double = 1) {
            self.style = style
            self.speed = speed
        }

        private enum CodingKeys: String, CodingKey { case style, speed }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? "ribbons"
            speed = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? 1))
        }
    }
    var motion: Motion? = nil
    /// How soft the picture or the scene is drawn, 0…1 — a frosted column.
    var blur: Double = 0
    /// Dark to bright, -1…1: 0 is the theme as it is, below it is tinted
    /// towards black and above it towards white. The ink follows, so the
    /// titles turn light once the column is dark enough.
    var tone: Double = 0

    init(colors: [Stop], intensity: Double = 0.8, grain: Double = 0, image: String? = nil,
         motion: Motion? = nil, blur: Double = 0, tone: Double = 0) {
        self.colors = colors
        self.intensity = intensity
        self.grain = grain
        self.image = image
        self.motion = motion
        self.blur = blur
        self.tone = tone
    }

    private enum CodingKeys: String, CodingKey { case colors, intensity, grain, image, motion, blur, tone }

    // Read by hand, not synthesized: a synthesized decoder wants every
    // non-optional key there, defaults or no, so a theme written before a
    // field existed — or by hand, or by an importer that only knew the
    // colours — would throw and take the whole session with it. A missing
    // number is its default; a theme with no colours at all is graphite's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let colors = (try? c.decodeIfPresent([Stop].self, forKey: .colors)) ?? []
        self.colors = Array((colors.isEmpty ? SpaceTheme.plain.colors : colors).prefix(3))
        intensity = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .intensity)) ?? 0.8))
        grain = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .grain)) ?? 0))
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        motion = try? c.decodeIfPresent(Motion.self, forKey: .motion)
        blur = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0))
        tone = min(1, max(-1, (try? c.decodeIfPresent(Double.self, forKey: .tone)) ?? 0))
    }

    /// A space that only ever had a hue: that hue, at the strength that
    /// hue can carry.
    static func hue(_ hue: Double) -> SpaceTheme {
        let (s, v) = strength(hue)
        return SpaceTheme(colors: [Stop(hue: hue, saturation: s, brightness: v)], intensity: 0.8)
    }

    /// How full and how bright a bare hue is taken, around the wheel. One
    /// number for all of them made the warm ones right and the rest neon:
    /// green and cyan are so much lighter to the eye than red at the same
    /// saturation that they came out highlighter-bright, and blue to pink
    /// shouted. So the warm side keeps its strength — salmon, apricot,
    /// butter — green and teal are thinned and dimmed to sage and sea glass,
    /// and blue round to pink sit between. Straight lines between these
    /// points, so an imported hue between two names lands between them.
    private static let strengths: [(h: Double, s: Double, v: Double)] = [
        (0.00, 0.74, 1.00), (0.07, 0.74, 1.00), (0.10, 0.72, 1.00), (0.14, 0.66, 1.00),
        (0.22, 0.56, 0.94), (0.36, 0.50, 0.86), (0.48, 0.52, 0.84), (0.60, 0.62, 0.98),
        (0.70, 0.58, 0.98), (0.80, 0.54, 0.98), (0.90, 0.62, 1.00), (1.00, 0.74, 1.00),
    ]

    static func strength(_ hue: Double) -> (s: Double, v: Double) {
        let h = hue - hue.rounded(.down)
        for (a, b) in zip(strengths, strengths.dropFirst()) where h <= b.h {
            let t = b.h > a.h ? (h - a.h) / (b.h - a.h) : 0
            return (a.s + (b.s - a.s) * t, a.v + (b.v - a.v) * t)
        }
        return (0.74, 1)
    }

    /// The colour a new stop starts as: the last one moved a step round the
    /// wheel, so a second stop makes a gradient you can see at once rather
    /// than a paler copy of the first. A grey gets a lighter grey.
    static func next(after last: Stop?) -> Stop {
        guard let last else { return plain.colors[0] }
        let (h, s, v) = last.hsb
        guard s > 0.12 else { return last.mixed(.white, 0.35) }
        return Stop(hue: (h + 0.09).truncatingRemainder(dividingBy: 1), saturation: s, brightness: v)
    }

    /// What the editor calls it. A scene outranks a picture, as it does
    /// on the column (see `ThemeBackdrop`).
    var kind: String { motion != nil ? "Animated" : image != nil ? "Picture" : colors.count > 1 ? "Gradient" : "Colour" }

    /// How far the tone's black or white goes over the column at its ends:
    /// short of all the way, so the theme's colour still shows through at
    /// -1 and +1.
    static let toneReach = 0.7

    /// Graphite: no colour at all.
    static let plain = SpaceTheme(colors: [Stop(r: 0.62, g: 0.62, b: 0.64)], intensity: 0.34)

    /// The default a space wears until it is given a colour: Copper's own
    /// column — the copper picture over a pale copper colour, so the ink that
    /// suits copper is the one the rows get. Graphite stays grey (`plain`).
    static let copper = SpaceTheme(colors: [Stop(r: 0.90, g: 0.76, b: 0.67)], intensity: 0.45, image: copperPicture)

    /// The hue the rest of the app knows the space by — the dot, the picker,
    /// the split's outline. Nil when the theme has no colour worth naming.
    var hue: Double? {
        guard let first = colors.max(by: { $0.hsb.s < $1.hsb.s }), first.hsb.s > 0.12 else { return nil }
        return first.hsb.h
    }

    /// The column's own colour for one stop. In the light: pulled from white
    /// by the intensity, then dimmed — the sum Arc's vibrant sidebar comes
    /// to over a white desktop. In the dark: the same hue, deep and quiet.
    func ground(_ stop: Stop, dark: Bool) -> Stop {
        if dark {
            let (h, s, _) = stop.hsb
            return Stop(hue: h, saturation: min(1, s * 0.8), brightness: 0.17 + 0.09 * intensity)
        }
        return Stop.white.mixed(stop, 0.8 * intensity).scaled(0.96)
    }

    /// One colour standing for the whole column: what a flat surface beside
    /// it (the split's gutter, a popover's arrow) should be.
    func flat(dark: Bool) -> Color {
        guard !colors.isEmpty else { return Palette.ground }
        return toned(dark: dark).color
    }

    /// The same one colour with the tone laid over it — the ground the ink
    /// has to read on.
    /// The one colour is the gradient's mean along its run (the trapezoid
    /// over evenly spaced stops), so a gradient resampled to more stops —
    /// which `mixed` does to morph a flat colour into a gradient — comes to
    /// the same ink, and a slide's end and the space at rest agree.
    func toned(dark: Bool) -> Stop {
        let stops = colors.isEmpty ? SpaceTheme.plain.colors : colors
        let sum: Stop
        if stops.count == 1 {
            sum = ground(stops[0], dark: dark)
        } else {
            let n = Double(stops.count - 1)
            var r = 0.0, g = 0.0, b = 0.0
            for (i, stop) in stops.enumerated() {
                let w = (i == 0 || i == stops.count - 1 ? 0.5 : 1) / n
                r += stop.r * w; g += stop.g * w; b += stop.b * w
            }
            sum = ground(Stop(r: r, g: g, b: b), dark: dark)
        }
        guard abs(tone) > 0.005 else { return sum }
        return sum.mixed(tone < 0 ? .black : .white, abs(tone) * SpaceTheme.toneReach)
    }

    /// The colours the backdrop runs through.
    func grounds(dark: Bool) -> [Color] { colors.map { ground($0, dark: dark).color } }

    /// A still theme with no picture and no scene: one the column can draw
    /// as a colour or gradient alone, and so morph into another such.
    var simple: Bool { image == nil && motion == nil }

    /// This theme `t` of the way to `other`, stop by stop — what the ground
    /// is part-way through a slide between two simple themes, and what the
    /// ink of the parts that stay put is mixed from on the way. A flat
    /// colour against a gradient is given the gradient's number of stops,
    /// all the one colour, so each stop has a partner to move towards and
    /// the morph is one surface changing colour rather than two crossfading.
    /// The picture and the scene are left out: they cannot be mixed, and
    /// the ink never depended on them.
    func mixed(_ other: SpaceTheme, _ t: Double) -> SpaceTheme {
        let count = max(colors.count, other.colors.count, 1)
        // A gradient resampled at `count` evenly spaced points draws the
        // same as it did (stops are joined by straight runs), so the two
        // sides pair stop for stop and the mix at 1 is `other` exactly.
        func resampled(_ stops: [Stop]) -> [Stop] {
            let base = stops.isEmpty ? SpaceTheme.plain.colors : stops
            guard base.count > 1, count > 1 else { return (0..<count).map { _ in base[0] } }
            return (0..<count).map { i in
                let at = Double(i) / Double(count - 1) * Double(base.count - 1)
                let k = min(base.count - 2, Int(at.rounded(.down)))
                return base[k].mixed(base[k + 1], at - Double(k))
            }
        }
        let stops = zip(resampled(colors), resampled(other.colors)).map { $0.mixed($1, t) }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return SpaceTheme(colors: stops, intensity: mix(intensity, other.intensity), grain: mix(grain, other.grain),
                          image: nil, motion: nil, blur: 0, tone: mix(tone, other.tone))
    }

    /// Arc's theme for a space — `customInfo.windowTheme` in its sidebar
    /// file: a single colour or a gradient's colours, the intensity and the
    /// grain. Nil for a space Arc left on its default.
    static func arc(_ windowTheme: [String: Any]?) -> SpaceTheme? {
        func dig(_ value: Any?, _ keys: [String]) -> Any? {
            keys.reduce(value) { ($0 as? [String: Any])?[$1] }
        }
        guard let colour = dig(windowTheme, ["background", "single", "_0", "style", "color", "_0"]) as? [String: Any] else { return nil }
        func stop(_ raw: Any?) -> Stop? {
            guard let raw = raw as? [String: Any], (raw["alpha"] as? Double ?? 1) > 0.05,
                  let r = raw["red"] as? Double, let g = raw["green"] as? Double, let b = raw["blue"] as? Double else { return nil }
            return Stop(r: r, g: g, b: b)
        }
        var body: [String: Any]?
        var stops: [Stop] = []
        if let single = dig(colour, ["blendedSingleColor", "_0"]) as? [String: Any] {
            body = single
            stops = [stop(single["color"])].compactMap { $0 }
        } else if let gradient = dig(colour, ["blendedGradient", "_0"]) as? [String: Any] {
            body = gradient
            // The base colours run the gradient; an overlay colour that is
            // actually there is Arc's third stop.
            stops = ((gradient["baseColors"] as? [Any] ?? []) + (gradient["overlayColors"] as? [Any] ?? [])).compactMap(stop)
        }
        guard !stops.isEmpty else { return nil }
        let modifiers = body?["modifiers"] as? [String: Any]
        return SpaceTheme(colors: Array(stops.prefix(3)),
                          intensity: modifiers?["intensityFactor"] as? Double ?? 0.8,
                          grain: modifiers?["noiseFactor"] as? Double ?? 0)
    }

    /// Arc's icon for a space: its emoji, when it has one.
    static func arcIcon(_ iconType: [String: Any]?) -> String? {
        guard let emoji = iconType?["emoji_v2"] as? String, !emoji.isEmpty else { return nil }
        return emoji
    }

    /// Where a theme's picture is kept.
    /// Where a theme's picture is kept. A `builtin:` name is one of the
    /// pictures that ship inside Copper (the default copper column), read
    /// from the app's own resources and never copied or deleted.
    static func file(_ name: String) -> URL {
        if name.hasPrefix(builtin), let folder = BackdropScene.folder {
            return folder.appendingPathComponent(String(name.dropFirst(builtin.count)) + ".jpg")
        }
        return Store.file("themes").appendingPathComponent(name)
    }

    static let builtin = "builtin:"
    /// The picture a space with no colour of its own wears: the app icon's
    /// copper plate and verdigris, lightened to a pale rose-copper with soft
    /// patina ribbons (rendered with three.js; see copper-themes/copper-default).
    static let copperPicture = builtin + "copper-default"

    /// A picture chosen in the editor, copied in so the theme owns it —
    /// taken down to at most `largest` pixels on its long side and kept as
    /// a JPEG. The column is 300pt wide; a 6K desktop picture is 20 MB of
    /// HEIC that would be decoded whole on the main thread at first draw
    /// and held in memory for good. A file ImageIO cannot read is copied
    /// as it is and left to NSImage.
    static func adopt(image source: URL, largest: Int = 2800) -> String? {
        let folder = Store.file("themes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
           let small = CGImageSourceCreateThumbnailAtIndex(reader, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: largest,
           ] as CFDictionary) {
            let name = UUID().uuidString + ".jpg"
            if let writer = CGImageDestinationCreateWithURL(file(name) as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(writer, small, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
                if CGImageDestinationFinalize(writer) { return name }
            }
        }
        let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: source, to: file(name))
            return name
        } catch {
            return nil
        }
    }
}

/// The column's ground: the theme's colour, gradient, picture or scene, its
/// tone, and its grain.
struct ThemeBackdrop: View {
    let theme: SpaceTheme
    let dark: Bool
    /// A ground that keeps one web view through theme changes (`LiveScene`)
    /// instead of a scene per backdrop — the Space page's preview column.
    /// The column itself is `SpaceGround`, which draws the same parts and
    /// blends two themes while a slide is on.
    var live = false
    /// The window whose column this is, when it is one: its own space keys
    /// the scene, and only its own swipe mixes the next space in. (Fork: windows)
    weak var browser: Browser? = nil

    var body: some View {
        ZStack {
            // A scene wins over a picture: choosing Animated keeps the
            // picture in the theme, so going back to Picture finds it again,
            // but the column only ever draws one of the two.
            if live {
                // The still ground first — all there is for a still space,
                // and what shows while the page loads for an animated one —
                // with the scene over it, hidden while there is nothing to draw.
                if theme.motion == nil { still } else { colour }
                LiveScene(theme: theme, dark: dark, browser: browser)
            } else if let motion = theme.motion {
                AnimatedBackdrop(style: motion.style, colors: theme.grounds(dark: dark), speed: motion.speed,
                                 blur: theme.blur, dark: dark)
            } else {
                still
            }
            // The tone over everything but the grain, so a dark column is
            // still grainy rather than grain under a black sheet. The grain
            // is an overlay round a middle grey: it lightens and darkens by
            // the same amount, so it is grain on a dark column too rather
            // than a lift or a shadow.
            Veil(tone: theme.tone, grain: theme.grain)
        }
        .clipped()
    }

    /// The colour or gradient, and the picture over it when there is one.
    private var still: some View { Still(theme: theme, dark: dark) }

    private var colour: some View { Colour(theme: theme, dark: dark) }

    /// The colour or gradient alone. A flat colour is the one stop's ground
    /// — not `flat`, which has the tone in it already: the tone is laid over
    /// every ground once (`Veil`), so a toned flat column and a toned
    /// gradient come out the same, and a morph from one to the other
    /// (`SpaceGround`) has nothing to jump over.
    struct Colour: View {
        let theme: SpaceTheme
        let dark: Bool

        var body: some View {
            let stops = theme.grounds(dark: dark)
            if stops.count > 1 {
                LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                stops.first ?? Palette.ground
            }
        }
    }

    /// The colour or gradient and the picture over it, for a still theme;
    /// the colour alone for an animated one, whose scene is drawn by whoever
    /// owns it (`SpaceGround`'s one live scene, or `AnimatedBackdrop`).
    struct Still: View {
        let theme: SpaceTheme
        let dark: Bool
        /// Fork (page-frame): how wide the picture is laid — the column's
        /// width, when this ground runs on under the page as well. A picture
        /// is drawn for the column (the built-in one is a tall strip), so it
        /// keeps the column's crop and fades into the theme's colour past
        /// it rather than being blown up to the window. Nil is the whole
        /// width.
        var span: CGFloat? = nil

        /// How far a picture is held down under light ink in the dark. At
        /// 0.3 the bright parts of a pastel picture came out a mid grey the
        /// column's titles read at 2.5–4.3:1; at this the brightest band of
        /// the built-in picture keeps even the muted titles at AA (4.5:1),
        /// and the saturation lifted with it keeps it a colour, not mud.
        static let nightVeil = 0.65

        var body: some View {
            Colour(theme: theme, dark: dark)
            if theme.motion == nil, let name = theme.image, let picture = ThemeBackdrop.picture(name, blur: theme.blur) {
                GeometryReader { geo in
                    let wide = span.map { min($0, geo.size.width) } ?? geo.size.width
                    ZStack {
                        Image(nsImage: picture)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: wide, height: geo.size.height)
                            .clipped()
                            .saturation(dark ? 1.3 : 1)
                        // A neutral veil first — white in the light, black in
                        // the dark — so the picture's own darks (or lights) are
                        // pulled towards the ground the ink was chosen for: over
                        // a photo's shadowed band the brown titles were going
                        // under. It greys the picture less than more colour would.
                        (dark ? Color.black.opacity(Still.nightVeil) : Color.white.opacity(0.22))
                        // The colour stays on the picture, thinly, so the ink
                        // that is right for the colour stays right over it — thin
                        // enough that a vivid picture keeps its colour; deeper in
                        // the dark, where light ink needs the picture held down.
                        Colour(theme: theme, dark: dark).opacity(dark ? 0.4 : 0.15)
                    }
                    .frame(width: wide, height: geo.size.height)
                    .mask { if span != nil { Still.fade(wide) } else { Rectangle() } }
                }
            }
        }

        /// The picture's last few points, into the colour beyond it.
        static func fade(_ wide: CGFloat) -> some View {
            LinearGradient(stops: [.init(color: .black, location: max(0, 1 - 24 / max(wide, 1))), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }

    /// The tone and the grain over a ground.
    struct Veil: View {
        let tone: Double
        let grain: Double

        var body: some View {
            if abs(tone) > 0.005 {
                (tone < 0 ? Color.black : Color.white)
                    .opacity(abs(tone) * SpaceTheme.toneReach)
                    .allowsHitTesting(false)
            }
            if grain > 0.01 {
                Image(nsImage: ThemeBackdrop.noise)
                    .resizable(resizingMode: .tile)
                    .opacity(min(1, grain) * 0.45)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A scene of its own for a `live` backdrop that is not the column —
    /// the Space page's preview column (`SpaceTint.backdrop`). The column
    /// itself draws its one long-lived scene in `SpaceGround`, which blends
    /// it towards the arriving space while a slide is on; this one only
    /// shows the theme it is given, fading as that changes. Made only once
    /// some space is animated; a still theme hides it, which also pauses it.
    private struct LiveScene: View {
        let theme: SpaceTheme
        let dark: Bool
        weak var browser: Browser?
        @ObservedObject private var spaces = Spaces.shared

        var body: some View {
            if BackdropScene.folder != nil, theme.motion != nil || spaces.all.contains(where: { $0.look.motion != nil }) {
                BackdropWeb.Host(drive: BackdropScene.Drive(look: BackdropScene.Look(theme: theme, dark: dark, key: (browser.map { spaces.current(in: $0) } ?? spaces.current).uuidString),
                                                            fade: SpaceSlide.duration + 0.08))
                    .allowsHitTesting(false)
            }
        }
    }

    private static var pictures: [String: NSImage] = [:]

    static func picture(_ name: String) -> NSImage? {
        if let seen = pictures[name] { return seen }
        guard let image = NSImage(contentsOf: SpaceTheme.file(name)) else { return nil }
        pictures[name] = image
        return image
    }

    /// The picture made soft, once per name and step of blur. A live
    /// `.blur` on a 2800-pixel picture re-runs the filter on every frame
    /// the column draws (and fades its edges to clear); the backdrop is
    /// still, so it is blurred once here instead. The blur is taken in
    /// twentieths so a slider drag makes at most twenty of them, and the
    /// picture is taken down first — as far as the blur hides it — so a
    /// full blur runs on a couple of hundred pixels, not millions.
    private static var softened: [String: NSImage] = [:]
    private static let filters = CIContext(options: [.cacheIntermediates: false])

    static func picture(_ name: String, blur: Double) -> NSImage? {
        let step = Int((min(1, max(0, blur)) * 20).rounded())
        guard step > 0 else { return picture(name) }
        let key = "\(name)@\(step)"
        if let seen = softened[key] { return seen }
        guard let sharp = picture(name),
              let cg = sharp.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let long = max(input.extent.width, input.extent.height)
        // At full blur the soft edge is a fiftieth of the picture's long side.
        let sigma = Double(step) / 20 * 0.02 * long
        // Small enough that the blur is still six pixels wide in it, which
        // hides the pixels when it is stretched back over the column.
        let scale = min(1, max(160 / long, 6 / sigma))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Clamped first so the edges blur into more picture, not into clear.
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: sigma * scale).cropped(to: small.extent)
        guard let out = filters.createCGImage(soft, from: small.extent) else { return sharp }
        let image = NSImage(cgImage: out, size: NSSize(width: small.extent.width, height: small.extent.height))
        // A handful at most: a drag leaves a trail of steps nobody keeps.
        if softened.count >= 12 { softened.removeAll() }
        softened[key] = image
        return image
    }

    /// A small tile of grey noise round the middle, made once.
    static let noise: NSImage = {
        let side = 96
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(side * side) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            // 96…159: the top six bits of the step. (150 plus seven bits ran
            // past 255 and wrapped to black specks.)
            let v = UInt8(96 + Int(seed >> 58))
            bytes[i * 4] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = 255
        }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        if let provider = CGDataProvider(data: Data(bytes) as CFData),
           let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        }
        return image
    }()
}
