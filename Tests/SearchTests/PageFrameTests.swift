import AppKit
import SwiftUI
import Testing
@testable import Search

// The window frame round the page (Fork/PageFrame.swift), the space chips
// (Fork/SpacesUI.swift), the dark picture veil (Fork/SpaceTheme.swift) and
// the one-colour site glyphs (Fork/IconInk.swift).

/// A 64-point square: a disc of `glyph` on clear, or on `ground` when given.
@MainActor
private func icon(_ glyph: NSColor, ground: NSColor? = nil) -> NSImage {
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    if let ground { ground.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill() }
    glyph.setFill()
    NSBezierPath(ovalIn: NSRect(x: 16, y: 16, width: 32, height: 32)).fill()
    image.unlockFocus()
    return image
}

/// The mean colour of the opaque pixels, 0…1 luminance-ish.
private func inkLevel(_ image: NSImage) -> Double {
    let side = 16
    var px = [UInt8](repeating: 0, count: side * side * 4)
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
    var sum = 0.0, n = 0.0
    for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 240 {
        sum += Double(px[i + 1]) / 255
        n += 1
    }
    return n > 0 ? sum / n : -1
}

@Suite("Site glyphs in the look's ink")
@MainActor
struct IconInkTests {
    @Test("A white glyph on clear is a pale glyph; a black one a dark one")
    func glyphs() {
        #expect(IconInk.tone(of: icon(.white)) == true)
        #expect(IconInk.tone(of: icon(.black)) == false)
    }

    @Test("Colour, or a ground of its own, is never touched")
    func notGlyphs() {
        #expect(IconInk.tone(of: icon(.systemRed)) == nil)
        #expect(IconInk.tone(of: icon(.black, ground: .white)) == nil)
    }

    @Test("A white glyph is drawn dark in the light and left white in the dark")
    func redrawn() {
        let white = icon(.white)
        #expect(inkLevel(IconInk.legible(white, dark: false)) < 0.2)
        #expect(IconInk.legible(white, dark: true) === white)
        let black = icon(.black)
        #expect(inkLevel(IconInk.legible(black, dark: true)) > 0.8)
        #expect(IconInk.legible(black, dark: false) === black)
    }
}

@Suite("Space chips")
struct SpaceChipTests {
    @Test("The tooltip names the space and its key")
    func help() {
        let space = Space(name: "Work")
        #expect(SpaceChip.help(space, index: 1, current: false) == "Work · ⌃2")
        #expect(SpaceChip.help(space, index: 9, current: false) == "Work")
        #expect(SpaceChip.help(space, index: 0, current: true) == "Work · ⌃1 — click to customize")
    }

    @Test("Every named colour gets its own tile, never one grey for all")
    func tiles() {
        let hues = SpaceColour.allCases.compactMap(\.hue)
        let tiles = hues.map { SpaceTint(hue: $0, dark: false).tile.hex }
        #expect(Set(tiles).count == hues.count)
    }

    @Test("The initial reads on its tile: white on a deep one, dark on a light one")
    func tileInk() {
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        for hue in SpaceColour.allCases.compactMap(\.hue) {
            for dark in [false, true] {
                let tint = SpaceTint(hue: hue, dark: dark)
                let tile = tint.tile.luminance
                let ink = tint.tileInkIsWhite ? 1 : SpaceTheme.Stop(r: SpaceTint.tileDark, g: SpaceTint.tileDark, b: SpaceTint.tileDark).luminance
                // Over the 3:1 a bold glyph needs, with room to spare.
                #expect(contrast(ink, tile) >= 3.5, "hue \(hue) dark \(dark)")
            }
        }
    }
}

@Suite("Dark picture veil")
struct NightVeilTests {
    /// sRGB → linear.
    private func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }

    @Test("The built-in picture's brightest pixel under the veil keeps the column's titles at AA")
    func titlesReadOnPicture() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Search/Fork/Backdrop/copper-default.jpg").standardized
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
        // The brightest pixel, on a coarse grid.
        var top = (r: 0.0, g: 0.0, b: 0.0)
        for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 6) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if lum(c.redComponent, c.greenComponent, c.blueComponent) > lum(top.r, top.g, top.b) {
                    top = (c.redComponent, c.greenComponent, c.blueComponent)
                }
            }
        }
        let theme = SpaceTheme.copper
        let ground = theme.ground(theme.colors[0], dark: true)
        let v = ThemeBackdrop.Still.nightVeil
        // Picture under the black veil, then the colour at 0.4 over it (gamma-space blending, as drawn).
        func mix(_ p: Double, _ g: Double) -> Double { p * (1 - v) * 0.6 + g * 0.4 }
        let bg = (mix(top.r, ground.r), mix(top.g, ground.g), mix(top.b, ground.b))
        let tint = SpaceTint(theme: theme, dark: true)
        #expect(tint.dark)
        let ink = try #require(NSColor(tint.ink).usingColorSpace(.sRGB))
        let (ir, ig, ib) = (Double(ink.redComponent), Double(ink.greenComponent), Double(ink.blueComponent))
        let ground0 = lum(bg.0, bg.1, bg.2)
        let titles = (lum(ir, ig, ib) + 0.05) / (ground0 + 0.05)
        #expect(titles >= 4.5, "titles \(titles)")
        // Titles sit at 0.85 of the ink over the ground (Side.swift).
        let a = 0.85
        let resting = (lum(ir * a + bg.0 * (1 - a), ig * a + bg.1 * (1 - a), ib * a + bg.2 * (1 - a)) + 0.05) / (ground0 + 0.05)
        #expect(resting >= 4.5, "resting titles \(resting)")
    }
}
