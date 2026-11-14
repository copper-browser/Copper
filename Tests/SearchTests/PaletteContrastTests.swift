import AppKit
import Testing
@testable import Search

// Fork (ui-system): the palette's words must read. Every pair that carries
// text — secondary ink on the ground and on the wash, words on the copper
// accent, the accent as a word — is at least WCAG AA (4.5:1) in both
// appearances. `faint` is decoration only and isn't held to it.

private func luminance(_ color: NSColor, _ name: NSAppearance.Name) -> Double {
    var result = 0.0
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        result = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    return result
}

private func contrast(_ a: NSColor, _ b: NSColor, _ name: NSAppearance.Name) -> Double {
    let (x, y) = (luminance(a, name), luminance(b, name))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func paletteWordsReadAA(_ look: NSAppearance.Name) {
    let ns = Palette.NS.self
    for (ink, ground, what) in [(ns.muted, ns.ground, "muted on ground"), (ns.muted, ns.wash, "muted on wash"),
                                (ns.ink, ns.ground, "ink on ground"), (ns.onAccent, ns.accent, "words on accent"),
                                (ns.accent, ns.ground, "accent on ground")] {
        let ratio = contrast(ink, ground, look)
        #expect(ratio >= 4.5, "\(what) in \(look.rawValue): \(ratio)")
    }
}

// Fork (uitype): measured off the pictures, 11–12 pt secondary words lose
// up to a fifth of their contrast to antialiasing — 0.40 grey (5.7:1 on
// paper, 4.9 on the wash) drew 3.4–4.4:1. Small words need ~5.5:1 on paper
// to read AA on screen; the danger red is held to the same, on the ground
// and the wash.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func smallWordsKeepAAOnceDrawn(_ look: NSAppearance.Name) {
    let ns = Palette.NS.self
    for (ink, ground, what) in [(ns.muted, ns.ground, "muted on ground"), (ns.muted, ns.wash, "muted on wash"),
                                (ns.danger, ns.ground, "danger on ground"), (ns.danger, ns.wash, "danger on wash")] {
        let ratio = contrast(ink, ground, look)
        #expect(ratio >= 5.5, "\(what) in \(look.rawValue): \(ratio)")
    }
}
