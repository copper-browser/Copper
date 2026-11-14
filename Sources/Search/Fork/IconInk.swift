import AppKit

// Fork (icon-ink): a site's mark that would vanish on the chrome it sits on.
//
// Some sites hand over a one-colour glyph meant for the other appearance —
// GitHub's octocat comes back white (its SVG picks its colour with a media
// query that is not asked when it is drawn here), and on the light column,
// ⌘K's white card or a pale favourite square it is not there at all. A
// one-colour glyph on a clear ground has no colours of its own to keep, so it
// is redrawn in the ink of the appearance on screen: black in the light,
// white in the dark. Anything with colour, or with a ground of its own (a
// white square with a black W), is left exactly as it came.

@MainActor
enum IconInk {
    /// Glyphs already redrawn, per appearance. Weak keys: an icon nobody
    /// holds any more takes its copy with it.
    private static let light = NSMapTable<NSImage, NSImage>.weakToStrongObjects()
    private static let night = NSMapTable<NSImage, NSImage>.weakToStrongObjects()
    /// What each icon was found to be (`tone`), so each is only read once:
    /// 0 not a glyph, 1 a pale glyph, 2 a dark one.
    private static let tones = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()

    /// The icon as it should be worn on chrome of this appearance.
    static func legible(_ image: NSImage, dark: Bool) -> NSImage {
        let made = dark ? night : light
        if let hit = made.object(forKey: image) { return hit }
        let known = tones.object(forKey: image)?.intValue ?? {
            let found = tone(of: image).map { $0 ? 1 : 2 } ?? 0
            tones.setObject(NSNumber(value: found), forKey: image)
            return found
        }()
        // Not a glyph, or one already in a colour that reads here.
        guard known != 0, (known == 1) != dark else { return image }
        let out = redrawn(image, in: dark ? .white : NSColor(white: 0.1, alpha: 1))
        made.setObject(out, forKey: image)
        return out
    }

    /// The look changed: every row with a mark from the cache puts on this
    /// look's — the asleep and parked ones too, which upstream's relook
    /// leaves alone (it would wake them to ask their pages).
    static func reink(_ tabs: [Tab]) {
        for tab in tabs where tab.icon != nil {
            guard let host = (tab.pending ?? tab.address)?.host()?.lowercased(),
                  let mark = Favicons.shared.cached(host), mark !== tab.icon else { continue }
            tab.icon = mark
        }
    }

    /// Whether this is a one-colour glyph on a clear ground, and if so
    /// whether that colour is light. Nil for anything else.
    nonisolated static func tone(of image: NSImage) -> Bool? {
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var solid = 0, pale = 0, deep = 0, clear = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3])
            if a < 26 { clear += 1; continue }
            guard a > 200 else { continue }
            // Premultiplied, but opaque enough that it barely matters.
            let r = Double(px[i]) / a, g = Double(px[i + 1]) / a, b = Double(px[i + 2]) / a
            solid += 1
            let spread = max(r, g, b) - min(r, g, b)
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if spread < 0.12, lum > 0.86 { pale += 1 }
            if spread < 0.12, lum < 0.14 { deep += 1 }
        }
        // A glyph: a good part of the square clear, the rest one grey.
        guard solid > 20, clear * 4 >= side * side else { return nil }
        if pale * 100 >= solid * 95 { return true }
        if deep * 100 >= solid * 95 { return false }
        return nil
    }

    /// The glyph's shape, filled with one colour.
    private static func redrawn(_ image: NSImage, in color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}
