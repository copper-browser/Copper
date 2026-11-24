import CoreGraphics
import Foundation

// browser_take_screenshot's arithmetic, kept apart from WebKit so it can be
// tested: what a call asked for (one subject at most, padding, scale, a
// file), the rectangle that is pictured (padded, then cut to what is there),
// the picture's size in pixels (the CSS size times the scale, the scale
// lowered when that would pass the size cap), the size of the image the
// answer carries (`inline`), the answer's words and where a picture asked to
// be saved in a folder goes. Page.screenshot does the drawing. Copper for Linux and Windows answer the same tool with the same
// words, so a change here is a change there (docs/agents.md › Screenshots).

extension Tools {
enum Shots {
    /// What is pictured.
    enum Subject: Equatable {
        /// The viewport, or with fullPage the whole page.
        case view
        /// An element by its ref, as given (e12, f2:e7).
        case ref(String)
        /// An element by CSS selector, in the page or in `frame` (f2).
        case selector(String, frame: String?)
        /// CSS pixels as given: from the viewport's top-left, or from the
        /// page's with fullPage.
        case region(CGRect)
    }

    /// One call's arguments, checked.
    struct Ask: Equatable {
        var subject: Subject = .view
        var fullPage = false
        var jpeg = false
        /// CSS pixels added on every side of an element or region.
        var padding: Double = 0
        /// Picture pixels per CSS pixel, 1 to 4.
        var scale: Double = 1
        /// Absolute, `~` expanded; a folder ends in `/` (`absolute`). Which
        /// file it becomes is settled when the picture is saved (`save`).
        var filename: String?
        /// The viewport for this picture alone, in CSS pixels (`copper shot
        /// --size`); put back after.
        var viewport: CGSize?
        /// prefers-color-scheme for this picture alone: true dark, false
        /// light (`copper shot --scheme`); put back after.
        var dark: Bool?
    }

    /// No side of a picture above this many pixels…
    static let maxSide = 16384
    /// …and no more pixels than this (64 megapixels).
    static let maxPixels = 64_000_000
    /// No side of the image in the answer above this many pixels: models
    /// refuse a bigger one (the file can be bigger: `inline`).
    static let maxInline = 8000

    /// The arguments as an `Ask`, or the error that names what is wrong.
    /// Checked before the page is touched.
    static func parse(_ args: [String: Any]) throws -> Ask {
        var ask = Ask()
        let ref = text(args["ref"]), selector = text(args["selector"])
        let region = args["region"].flatMap { $0 is NSNull ? nil : $0 }
        guard [ref != nil, selector != nil, region != nil].filter({ $0 }).count <= 1 else {
            throw Failure(text: "give one of ref, selector or region")
        }
        if let ref { ask.subject = .ref(ref) }
        if let selector { ask.subject = .selector(selector, frame: text(args["frame"])) }
        if let region { ask.subject = .region(try rectangle(region)) }
        ask.fullPage = (args["fullPage"] as? Bool) ?? false
        ask.jpeg = (args["type"] as? String) == "jpeg"
        if let raw = present(args["padding"]) {
            guard let padding = numeric(raw), padding >= 0 else { throw Failure(text: "padding must be 0 or more") }
            ask.padding = padding
        }
        if let raw = present(args["scale"]) {
            guard let scale = numeric(raw), scale >= 1, scale <= 4 else { throw Failure(text: "scale must be from 1 to 4") }
            ask.scale = scale
        }
        if let path = text(args["filename"]) { ask.filename = try absolute(path) }
        // The CLI's --size and --scheme: kept out of the listed schema (shared
        // with Linux and Windows, and inside the tools/list budget).
        if let raw = present(args["viewport"]) {
            let fields = raw as? [String: Any]
            guard let width = fields.flatMap({ numeric($0["width"]) }), let height = fields.flatMap({ numeric($0["height"]) }),
                  (100...8000).contains(width), (100...8000).contains(height) else {
                throw Failure(text: "viewport needs width and height: CSS pixels from 100 to 8000")
            }
            ask.viewport = CGSize(width: width.rounded(), height: height.rounded())
        }
        if let raw = present(args["colorScheme"]) {
            guard let scheme = raw as? String, ["light", "dark"].contains(scheme) else { throw Failure(text: "colorScheme must be light or dark") }
            ask.dark = scheme == "dark"
        }
        return ask
    }

    /// `path` with `~` expanded, or an error when it is relative: the app's
    /// working directory is nobody's (the CLI makes a shell's relative path
    /// absolute before it asks). A trailing `/` (a folder) is kept.
    static func absolute(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Failure(text: "filename must be an absolute path or start with ~/") }
        return path.hasSuffix("/") && !expanded.hasSuffix("/") ? expanded + "/" : expanded
    }

    /// The region argument: `{x, y, width, height}` in CSS pixels.
    static func rectangle(_ raw: Any) throws -> CGRect {
        let fields = raw as? [String: Any]
        guard let x = fields.flatMap({ numeric($0["x"]) }), let y = fields.flatMap({ numeric($0["y"]) }),
              let width = fields.flatMap({ numeric($0["width"]) }), let height = fields.flatMap({ numeric($0["height"]) }) else {
            throw Failure(text: "region needs x, y, width and height: numbers in CSS pixels")
        }
        guard width > 0, height > 0 else { throw Failure(text: "region width and height must be more than 0") }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - rectangles and sizes

    /// `rect` grown by `padding` on every side, then cut to `bounds` (the
    /// viewport, or the page); nil when nothing of it is left.
    static func area(_ rect: CGRect, padding: Double, within bounds: CGRect) -> CGRect? {
        let cut = rect.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        return cut.isNull || cut.width <= 0 || cut.height <= 0 ? nil : cut
    }

    /// `rect` (view points) on whole points, its edges rounded: WebKit draws
    /// the whole points around the rectangle it is given into the picture,
    /// so a fractional one would come out squeezed by a pixel.
    static func snapped(_ rect: CGRect) -> CGRect {
        let x = rect.minX.rounded(), y = rect.minY.rounded()
        return CGRect(x: x, y: y, width: max(rect.maxX.rounded() - x, 1), height: max(rect.maxY.rounded() - y, 1))
    }

    /// `rect` (view points) grown right and down, by under `limit` points,
    /// until both sides are whole numbers of snapshot points at `k` snapshot
    /// points per view point; nil when no size that close is. WebKit's
    /// picture of it is then whole pixels, and the asked part of it is its
    /// top-left corner, pixel for pixel — nothing scaled after the drawing.
    static func whole(_ rect: CGRect, k: Double, limit: Int = 8) -> CGRect? {
        func grown(_ side: Double) -> Double? {
            (0..<limit).lazy.map { side + Double($0) }.first { abs(($0 * k).rounded() - $0 * k) < 1e-6 }
        }
        guard k > 0, let width = grown(rect.width), let height = grown(rect.height) else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: width, height: height)
    }

    /// Which cap made the scale come down.
    enum Cap: Equatable { case side, pixels }

    /// A picture's size in pixels and the scale that gives it.
    struct Size: Equatable {
        var width: Int
        var height: Int
        var scale: Double
        /// Set when the asked scale was lowered to fit.
        var cap: Cap?
    }

    /// round(CSS size × scale), each side at least one pixel.
    static func pixels(_ css: CGSize, scale: Double) -> (width: Int, height: Int) {
        func side(_ v: Double) -> Int { max(1, Int(min(v * scale, 1e9).rounded())) }
        return (side(css.width), side(css.height))
    }

    static func fits(_ size: (width: Int, height: Int)) -> Bool {
        size.width <= maxSide && size.height <= maxSide && size.width * size.height <= maxPixels
    }

    /// The picture's size for `css` (the pictured rectangle's CSS size) at
    /// `scale`; when that passes the cap, the largest scale in hundredths
    /// that fits, and which cap it was.
    static func size(css: CGSize, scale: Double) -> Size {
        let asked = pixels(css, scale: scale)
        if fits(asked) { return Size(width: asked.width, height: asked.height, scale: scale, cap: nil) }
        let bySide = Double(maxSide) / max(css.width, css.height)
        let byPixels = (Double(maxPixels) / (css.width * css.height)).squareRoot()
        var hundredths = (min(bySide, byPixels, scale) * 100).rounded(.down)
        // Rounding each side up can still pass the cap by a pixel.
        while hundredths > 1, !fits(pixels(css, scale: hundredths / 100)) { hundredths -= 1 }
        let lowered = max(hundredths, 1) / 100
        let got = pixels(css, scale: lowered)
        return Size(width: got.width, height: got.height, scale: lowered, cap: bySide <= byPixels ? .side : .pixels)
    }

    /// The image the answer carries, when it isn't the picture itself; nil
    /// when it is. The answer's image is for the model to look at, the file
    /// is the HD picture: a picture saved above scale 1 comes as the same
    /// area at scale 1 (small, and its pixels are CSS pixels again, so they
    /// can be clicked); and no answer image passes `maxInline` on its longest
    /// side — the scale is lowered to the largest hundredth that fits, the
    /// aspect kept. Unsaved (or a save that failed), the picture goes as it
    /// is when it is small enough, so the CLI can still write it itself.
    /// `css`: the pictured rectangle's CSS size, as given to `size`.
    static func inline(css: CGSize, picture: Size, saved: Bool) -> Size? {
        let drawnDown = saved && picture.scale > 1
        guard drawnDown || max(picture.width, picture.height) > maxInline else { return nil }
        var scale = drawnDown ? 1 : picture.scale
        func longest(_ scale: Double) -> Int { let got = pixels(css, scale: scale); return max(got.width, got.height) }
        if longest(scale) > maxInline {
            // A side under maxInline + 0.5 rounds to at most maxInline; the
            // loop takes off the hundredth that lands on it exactly.
            var hundredths = (min(scale, (Double(maxInline) + 0.5) / max(css.width, css.height)) * 100).rounded(.down)
            while hundredths > 1, longest(hundredths / 100) > maxInline { hundredths -= 1 }
            scale = max(hundredths, 1) / 100
        }
        let got = pixels(css, scale: scale)
        guard got.width != picture.width || got.height != picture.height else { return nil }
        return Size(width: got.width, height: got.height, scale: scale, cap: nil)
    }

    // MARK: - the answer

    /// A number as the answers print it: at most two decimals, no trailing
    /// zeros (1, 1.5, 2.37).
    static func number(_ value: Double) -> String {
        var out = String(format: "%.2f", value)
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out == "-0" ? "0" : out
    }

    /// What the answer says was pictured.
    static func subject(_ ask: Ask) -> String {
        switch ask.subject {
        case .view: return ask.fullPage ? "the whole page" : "the viewport"
        case .ref(let ref): return ref
        case .selector(let css, _): return css
        case .region(let r): return "the region \(number(r.minX)),\(number(r.minY)) \(number(r.width))×\(number(r.height))"
        }
    }

    /// The answer's text: what the picture is, where it was saved (or why
    /// not), the image the answer carries when it isn't the picture
    /// (`inline`), the notes, then the page (`page`, Tools.pageLine).
    /// `upscaled`: the most a port could draw the page at, when it had to
    /// enlarge the picture instead (never on the Mac, where WebKit draws at
    /// any size).
    static func answer(_ ask: Ask, size: Size, saved: String? = nil, failed: (path: String, reason: String)? = nil,
                       inline: Size? = nil, upscaled: Double? = nil, page: String) -> String {
        var parts = ["Screenshot \(size.width)×\(size.height) \(ask.jpeg ? "JPEG" : "PNG") at scale \(number(size.scale)) of \(subject(ask))."]
        if let saved { parts.append("Saved to \(saved).") }
        if let failed {
            let reason = failed.reason.hasSuffix(".") ? String(failed.reason.dropLast()) : failed.reason
            parts.append("Couldn't save to \(failed.path): \(reason).")
        }
        if let inline {
            let full = saved == nil ? "pass filename to keep the full picture" : "the file has the full picture"
            parts.append("The image here is \(inline.width)×\(inline.height) at scale \(number(inline.scale)); \(full).")
        }
        if let cap = size.cap {
            parts.append("Scale lowered from \(number(ask.scale)) to \(number(size.scale)) to stay under \(cap == .side ? "\(maxSide) px" : "64 megapixels").")
        }
        if let upscaled { parts.append("Upscaled: this page renders at most at scale \(number(upscaled)) here.") }
        parts.append(page)
        return parts.joined(separator: " ")
    }

    // MARK: - the file

    /// A new picture's name in a folder: copper-YYYYMMDD-HHMMSS.png (.jpg
    /// for JPEG), in local time, as the Mac names its own screenshots.
    static func name(jpeg: Bool, at date: Date, in zone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyyMMdd-HHmmss"
        return "copper-\(format.string(from: date)).\(jpeg ? "jpg" : "png")"
    }

    /// Where a picture asked for at `path` goes: `path` itself, or for a
    /// folder (`folder`: an existing directory; or a path ending in `/`) a
    /// new name inside it. `taken` says whether a file is already there, so
    /// two pictures in the same second don't overwrite each other (-2, -3…).
    static func destination(_ path: String, folder: Bool, jpeg: Bool, at date: Date,
                            in zone: TimeZone = .current, taken: (String) -> Bool = { _ in false }) -> String {
        guard folder || path.hasSuffix("/") else { return path }
        let first = (path as NSString).appendingPathComponent(name(jpeg: jpeg, at: date, in: zone))
        var candidate = first, n = 1
        while taken(candidate), n < 1000 {
            n += 1
            candidate = (first as NSString).deletingPathExtension + "-\(n)." + (first as NSString).pathExtension
        }
        return candidate
    }

    /// Writes the picture where `path` says (see `destination`), making the
    /// folders on the way, and answers the file's path. Called off the main
    /// thread (OffMainWrite.run): a guarded folder can hold any of these
    /// steps on a privacy prompt.
    static func save(_ data: Data, to path: String, jpeg: Bool, at date: Date = Date()) throws -> String {
        let files = FileManager.default
        var directory: ObjCBool = false
        let folder = files.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        let file = destination(path, folder: folder, jpeg: jpeg, at: date) { files.fileExists(atPath: $0) }
        let url = URL(fileURLWithPath: file)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return file
    }

    // MARK: - argument values

    private static func present(_ raw: Any?) -> Any? { raw is NSNull ? nil : raw }

    /// A non-empty string argument.
    private static func text(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s
    }

    /// A finite JSON number (never a boolean).
    private static func numeric(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}
}
