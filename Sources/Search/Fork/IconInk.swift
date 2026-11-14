import AppKit
import ImageIO

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
//
// Whether an icon is such a glyph (its tone) is never found out on the main
// thread: reading it decodes the icon, and a session coming back asks for
// ~250 icons in the launch's first pass, which navperf had made lazy. It is
// read off the main thread when an icon arrives (`Favicons.square`) or is
// first asked for (`read`), and kept beside the icon's file, so the next
// launch knows it from one attribute read.

@MainActor
enum IconInk {
    /// Glyphs already redrawn, per appearance. Weak keys: an icon nobody
    /// holds any more takes its copy with it.
    private static let light = NSMapTable<NSImage, NSImage>.weakToStrongObjects()
    private static let night = NSMapTable<NSImage, NSImage>.weakToStrongObjects()
    /// What each icon was found to be: 0 not a glyph, 1 a pale glyph, 2 a
    /// dark one (`code`).
    private static let tones = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()
    /// The glyphs and their redrawn copies: the only marks a change of look
    /// has to put right.
    private static let glyphs = NSHashTable<NSImage>.weakObjects()

    /// The icon as it should be worn on chrome of this appearance. Only from
    /// what is already known: an icon whose tone is still being read is worn
    /// as it came until it is (`read` hands over the inked one then).
    static func legible(_ image: NSImage, dark: Bool) -> NSImage {
        let made = dark ? night : light
        if let hit = made.object(forKey: image) { return hit }
        // Not read yet, not a glyph, or one already in a colour that reads here.
        guard let known = tones.object(forKey: image)?.intValue, known != 0, (known == 1) != dark else { return image }
        let out = redrawn(image, in: dark ? .white : NSColor(white: 0.1, alpha: 1))
        made.setObject(out, forKey: image)
        glyphs.add(out)
        return out
    }

    /// What `image` was found to be (`code`).
    static func learn(_ image: NSImage, tone: Int) {
        tones.setObject(NSNumber(value: tone), forKey: image)
        if tone != 0 { glyphs.add(image) }
    }

    /// An icon just read from `file`: its tone from beside the file, or read
    /// off the main thread and kept there. When that finds a glyph this look
    /// has to ink, `inked` gets the inked one to put on.
    static func read(_ image: NSImage, at file: URL, inked: @escaping (NSImage) -> Void) {
        if let tone = kept(at: file) { return learn(image, tone: tone) }
        Task {
            guard let tone = await measure(file) else { return }
            learn(image, tone: tone)
            let worn = legible(image, dark: Favicons.dark)
            if worn !== image { inked(worn) }
        }
    }

    /// The look changed: every row wearing a glyph from the cache puts on
    /// this look's — the asleep and parked ones too, which upstream's relook
    /// leaves alone (it would wake them to ask their pages). Every other row
    /// is passed over on one lookup: its mark is the same in either look.
    static func reink(_ tabs: [Tab]) {
        for tab in tabs {
            guard let icon = tab.icon, glyphs.contains(icon),
                  let host = (tab.pending ?? tab.address)?.host()?.lowercased(),
                  let mark = Favicons.shared.cached(host), mark !== icon else { continue }
            tab.icon = mark
        }
    }

    // MARK: - Kept beside the file

    nonisolated private static let attribute = "dev.copper.icon-tone"

    /// The tone kept on an icon's file, if it has been read. An icon written
    /// again (`Favicons.keep`) is a new file, so a stale tone can't survive it.
    nonisolated static func kept(at file: URL) -> Int? {
        var byte: UInt8 = 0
        let got = file.withUnsafeFileSystemRepresentation { path in path.map { getxattr($0, attribute, &byte, 1, 0, 0) } ?? -1 }
        return got == 1 && (48...50).contains(byte) ? Int(byte) - 48 : nil
    }

    nonisolated static func keep(_ tone: Int, at file: URL) {
        var byte = UInt8(48 + tone)
        _ = file.withUnsafeFileSystemRepresentation { path in path.map { setxattr($0, attribute, &byte, 1, 0, 0) } }
    }

    /// The tone of the icon in `file`, decoded off the main thread and kept
    /// on the file. Nil if it can't be read.
    nonisolated static func measure(_ file: URL) async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            let tone = code(tone(of: image))
            keep(tone, at: file)
            return tone
        }.value
    }

    // MARK: - Reading the pixels

    /// 0 not a glyph, 1 a pale glyph, 2 a dark one.
    nonisolated static func code(_ tone: Bool?) -> Int { tone.map { $0 ? 1 : 2 } ?? 0 }

    nonisolated static func tone(of image: NSImage) -> Bool? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { tone(of: $0) }
    }

    /// Whether this is a one-colour glyph on a clear ground, and if so
    /// whether that colour is light. Nil for anything else.
    nonisolated static func tone(of cg: CGImage) -> Bool? {
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
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
