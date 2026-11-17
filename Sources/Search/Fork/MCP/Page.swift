import AppKit
import ImageIO
import WebKit

// The page's side of the agent. One script, put into the page when a tool
// first needs it (not at load — a page nobody is driving pays nothing),
// gives the tools a way to name elements and act on them:
//
//   snapshot()  — the accessibility tree as Playwright prints it, each
//                 interactive node with a ref (e1, e2 …) it remembers on the
//                 element, so the next call can say "click e12".
//   find()      — ref:e12 or css:… back to the element.
//   rect()      — where it is, in viewport CSS pixels, after scrolling it in.
//   setValue()  — a value the framework notices (native setter + events).
//   and the rest of what the tools need when there is no window to click in.
//
// Nested in Tools because upstream already has a `Page` — the SwiftUI view in
// Stage.swift — and a second one at the top of the module is the one the
// compiler stops seeing. Inside Tools the short name still reads as `Page`.

extension Tools {
enum Page {
    /// LocalizedError so whoever shows it (MCP.handle, the CLI, the pane)
    /// shows the text, not "Page.Failure error 1".
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    // MARK: - JavaScript

    /// A JSON string literal for a Swift string, for building scripts.
    static func quote(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    static func quote(_ list: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Run in the page, with the helper installed first if it isn't yet.
    /// `script` is an expression. One round trip when the helper is already
    /// in this document, which is every call but the first.
    ///
    /// In Copper's own content world (Frames.swift): `window.__copper` there
    /// is the helper and nothing else — whatever the page calls by that name
    /// is in another world. `frame`: one of the page's frames instead of the
    /// page itself (Frames).
    @MainActor
    static func js(_ web: WKWebView, _ script: String, in frame: WKFrameInfo? = nil) async throws -> Any? {
        let missing = "__copper:missing"
        let result = try await raw(web, "typeof window.__copper === 'object' ? (\(script)) : \(quote(missing))", in: frame)
        guard result as? String == missing else { return result }
        _ = try await raw(web, helper, in: frame)
        // The console recorder wraps the page's own console, so it lives in the page's world.
        if frame == nil { _ = try? await raw(web, consoleShim, world: .page) }
        return try await raw(web, script, in: frame)
    }

    @MainActor
    static func js(_ web: WKWebView, at target: Tools.Locator, _ script: String) async throws -> Any? {
        try await js(web, script, in: target.info(web))
    }

    /// Scripts of Copper's in flight, per web view: a page stopped in an
    /// alert can't finish them, so AgentDialogs never holds one open then.
    @MainActor static var waiting: [ObjectIdentifier: Int] = [:]

    @MainActor
    static func raw(_ web: WKWebView, _ script: String, counted: Bool = true, in frame: WKFrameInfo? = nil, world: WKContentWorld = .copper) async throws -> Any? {
        // Not counted: decoration (Trail) that nothing waits on, so a click's alert stays open for the agent.
        let key = ObjectIdentifier(web)
        if counted { waiting[key, default: 0] += 1 }
        let began = Date()
        defer {
            if counted { let left = (waiting[key] ?? 1) - 1; waiting[key] = left > 0 ? left : nil }
            Tools.phases?.add("js", since: began)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(script, in: frame, in: world) { result in
                switch result {
                // `undefined` comes boxed as an Any holding nil; only real values are objects.
                case .success(let value): continuation.resume(returning: value as? NSObject)
                case .failure(let error): continuation.resume(throwing: Failure(text: "JavaScript: \(detail(error))"))
                }
            }
        }
    }

    /// An async function body run in the page (callAsyncJavaScript), so a
    /// Promise it returns is awaited. `timeout` caps the wait: a Promise that
    /// never settles, or a document torn down mid-call, answers nothing.
    @MainActor
    static func call(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval, late: String, counted: Bool = true, in frame: WKFrameInfo? = nil, world: WKContentWorld = .copper) async throws -> Any? {
        // Counted like `raw`, so an alert inside browser_evaluate is answered at once (AgentDialogs).
        // `frame` isn't: an alert a click raises during settle stays open for browser_handle_dialog.
        let key = ObjectIdentifier(web)
        if counted { waiting[key, default: 0] += 1 }
        let began = Date()
        defer {
            if counted { let left = (waiting[key] ?? 1) - 1; waiting[key] = left > 0 ? left : nil }
            Tools.phases?.add("js", since: began)
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, once.take() else { return }
                continuation.resume(throwing: Failure(text: late))
            }
            web.callAsyncJavaScript(body, arguments: arguments, in: frame, in: world) { result in
                guard once.take() else { return }
                timer.cancel()
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: Failure(text: "JavaScript: \(detail(error))"))
                }
            }
        }
    }

    /// One animation frame of the page, or 50 ms, whichever comes first.
    @MainActor
    static func frame(_ web: WKWebView) async {
        _ = try? await call(web, "return await new Promise(r => { requestAnimationFrame(() => r(true)); setTimeout(() => r(true), 50); });", timeout: 0.1, late: "", counted: false)
    }

    /// Whichever of an answer and a timeout comes first wins.
    private final class Once: @unchecked Sendable {
        private var used = false
        func take() -> Bool {
            if used { return false }
            used = true
            return true
        }
    }

    private static func detail(_ error: Error) -> String {
        let ns = error as NSError
        return (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
    }

    /// A helper's answer as a result: its failures ("no element for …",
    /// "not editable: DIV", "no option matched …") thrown, so they reach the
    /// agent as errors and never as a quiet success.
    @MainActor
    @discardableResult
    static func act(_ web: WKWebView, at target: Tools.Locator? = nil, _ script: String) async throws -> String {
        let said = render(try await js(web, script, in: target?.info(web)))
        if said.hasPrefix("no ") || said.hasPrefix("not ") {
            throw Failure(text: "\(said). Take a fresh browser_snapshot and use a ref from it.")
        }
        return said
    }

    /// A JavaScript value as text for the agent.
    static func render(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "undefined" }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    // MARK: - what the tools ask

    @MainActor
    static func snapshot(_ web: WKWebView, selector: String?, interactive: Bool, limit: Int, frame: Int? = nil) async throws -> String {
        if let frame {
            // One frame alone, in full: for a frame too big for its share of the page's snapshot.
            let result = try await js(web, "window.__copper.snapshot(\(quote(selector ?? "")), \(interactive), \(limit), 'f\(frame):')", in: Frames.frame(frame, in: web).info) as? [String: Any]
            guard let text = result?["text"] as? String else { throw Failure(text: "snapshot gave nothing") }
            return text
        }
        // The page and its frames at once; each frame's part goes under its iframe line (Frames.stitch).
        // A frame gets a share of the nodes, so a page of embeds stays readable.
        async let frames = Frames.parts(web, interactive: interactive, limit: min(limit, 200))
        let result = try await js(web, "window.__copper.snapshot(\(quote(selector ?? "")), \(interactive), \(limit), '')") as? [String: Any]
        guard let text = result?["text"] as? String else { _ = await frames; throw Failure(text: "snapshot gave nothing") }
        return Frames.stitch(text, result?["frames"] as? [[String: Any]] ?? [], await frames)
    }

    /// Scroll the target into view and answer its rectangle in viewport
    /// CSS pixels — the space clicks are posted in. With `hit` (anything
    /// about to be clicked or typed into), the point at its middle must be
    /// the element's own: a cookie wall or a hidden field is an error naming
    /// it, never a click that lands on something else. A cover that is on its
    /// way out (a fading toast, a closing sheet) gets three tries.
    @MainActor
    static func prepare(_ web: WKWebView, _ target: Tools.Locator, hit: Bool = true) async throws -> CGRect {
        let frame = try target.info(web)
        var result = try await js(web, "window.__copper.rect(\(quote(target.script)), \(hit))", in: frame)
        for _ in 0..<3 where (result as? [String: Any])?["blocked"] as? Bool == true {
            try await Task.sleep(nanoseconds: 100_000_000)
            result = try await js(web, "window.__copper.rect(\(quote(target.script)), \(hit))", in: frame)
        }
        guard let dict = result as? [String: Any],
              var x = (dict["x"] as? NSNumber)?.doubleValue, var y = (dict["y"] as? NSNumber)?.doubleValue,
              let w = (dict["width"] as? NSNumber)?.doubleValue, let h = (dict["height"] as? NSNumber)?.doubleValue
        else {
            let dict = result as? [String: Any]
            let why = dict?["error"] as? String ?? "not found"
            let next = dict?["cover"] != nil
                ? "Close or dismiss what covers it first (find its button with browser_snapshot), then try again."
                : dict?["blocked"] as? Bool == true
                ? "Open or scroll to whatever reveals it first, or pick another ref from a fresh browser_snapshot."
                : "Take a fresh browser_snapshot — refs change when the page does."
            throw Tools.Failure(text: "\(target.label): \(why). \(next)")
        }
        // In a frame: the box is in the frame's own viewport, and the frame is somewhere on the page.
        if frame != nil, let path = (dict["at"] as? [NSNumber])?.map(\.intValue), !path.isEmpty {
            let offset = try await Frames.offset(path, in: web, point: CGPoint(x: x + w / 2, y: y + h / 2), hit: hit)
            x += offset.x; y += offset.y
        }
        // The page's CSS pixels to the view's points: page zoom is the only
        // scale between them.
        let zoom = web.pageZoom
        return CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
    }

    /// A picture and what it came out as. WebKit draws the page again at
    /// any size asked, so a Mac picture is never an enlarged one (the
    /// answer's "Upscaled" note is for ports that can't always).
    struct Picture {
        /// PNG or JPEG, as asked: what a file gets.
        let data: Data
        let size: Tools.Shots.Size
        /// The pictured rectangle's size in CSS pixels (Shots.inline).
        let css: CGSize
        /// What `data` encodes, kept for the answer's smaller image (`drawnDown`).
        let bitmap: CGImage

        init(_ bitmap: CGImage, size: Tools.Shots.Size, css: CGSize, jpeg: Bool) throws {
            self.data = try Page.encode(bitmap, jpeg: jpeg)
            self.size = size
            self.css = css
            self.bitmap = bitmap
        }
    }

    /// The most a view is grown to, in CSS pixels, for a picture of what is
    /// bigger than it (the full page has always stopped here).
    static let tallest: Double = 20000

    /// browser_take_screenshot. The subject is worked out in the page's CSS
    /// pixels — padded and cut to what is there (Shots.area) — and WebKit
    /// draws it at the picture's own size: scale 2 is the page drawn again
    /// with twice the pixels, never a picture blown up. What is bigger than
    /// the view (the page, a tall element, a region low on the page) is drawn
    /// by growing the view to the page for the moment of the picture (`grown`).
    @MainActor
    static func screenshot(_ web: WKWebView, _ ask: Tools.Shots.Ask, target: Tools.Locator?) async throws -> Picture {
        let zoom = max(web.pageZoom, 0.01)
        let viewport = CGRect(x: 0, y: 0, width: web.bounds.width / zoom, height: web.bounds.height / zoom)
        // A tab no window holds (an empty tab with no page yet) has no size to draw.
        guard web.window != nil, viewport.width >= 1, viewport.height >= 1 else {
            throw Tools.Failure(text: "this tab isn't drawn anywhere yet, so there is nothing to picture: open a page in it (browser_navigate), or work in a tab of your own (browser_tabs new)")
        }
        switch ask.subject {
        case .view where !ask.fullPage:
            return try await draw(web, viewport, ask)
        case .region(let region) where !ask.fullPage:
            guard let area = Tools.Shots.area(region, padding: ask.padding, within: viewport) else {
                throw Tools.Failure(text: "the region is outside the viewport")
            }
            return try await draw(web, area, ask)
        case .view, .region:
            // The whole page, as wide as the view. A lazy page draws a section
            // only when it scrolls into view, so it is walked a screen at a
            // time first, and put back where it was.
            var height = (try? await call(web, walk, timeout: 10, late: "")) as? NSNumber
            if height == nil { height = try await raw(web, "Math.min(document.documentElement.scrollHeight, \(Int(tallest)))") as? NSNumber }
            let page = CGRect(x: 0, y: 0, width: viewport.width, height: max(height?.doubleValue ?? 0, viewport.height))
            var area = page
            if case .region(let region) = ask.subject {
                guard let cut = Tools.Shots.area(region, padding: ask.padding, within: page) else {
                    throw Tools.Failure(text: "the region is outside the page")
                }
                area = cut
            }
            guard page.height > viewport.height + 0.5 else { return try await draw(web, area, ask) }
            return try await grown(web, to: page.size) { held in
                // As tall as the page, the view has no room left to scroll
                // and the page's coordinates are the view's. A page past
                // `tallest` still has: it is scrolled to its top, so the
                // picture is the page's first `tallest` pixels whatever
                // its scroll (`grown` puts that back after).
                _ = try? await raw(web, "window.scrollTo({ left: scrollX, top: 0, behavior: 'instant' }); true", counted: false)
                let top = (try? await scroll(web))?.y ?? 0
                return try await draw(web, area.offsetBy(dx: 0, dy: -top), ask, holding: held)
            }
        case .ref, .selector:
            guard let target else { throw Tools.Failure(text: "ref (from browser_snapshot) or selector required") }
            // Only the height is ever grown: a wider view would lay a
            // responsive page out again, so what is wider than the view is
            // cut at its sides.
            let first = try await place(web, target, padding: ask.padding)
            if first.area.minY >= -0.5, first.area.maxY <= viewport.height + 0.5 {
                guard let area = Tools.Shots.area(first.area, padding: 0, within: viewport) else {
                    throw Tools.Failure(text: "\(target.label) is outside the viewport, to the side")
                }
                return try await draw(web, area, ask)
            }
            // Taller than the view (or its padding off it): the view grown to
            // the page, and the element measured again there.
            return try await grown(web, to: CGSize(width: viewport.width, height: min(first.page.height, tallest))) { held in
                var placed = try await place(web, target, padding: ask.padding)
                // A layout pass may have put the view back meanwhile: grown again, measured again.
                for _ in 0..<2 where web.frame.size != held {
                    await resize(web, to: held)
                    placed = try await place(web, target, padding: ask.padding)
                }
                let view = CGRect(x: 0, y: 0, width: held.width / zoom, height: held.height / zoom)
                guard let area = Tools.Shots.area(placed.area, padding: 0, within: view) else {
                    throw Tools.Failure(text: "\(target.label) is outside the page")
                }
                return try await draw(web, area, ask, holding: held)
            }
        }
    }

    /// An element for a picture: its border box scrolled into view
    /// (`prepare`, frames included) in the view's CSS pixels, padded and cut
    /// to the page; and the page's size.
    @MainActor
    private static func place(_ web: WKWebView, _ target: Tools.Locator, padding: Double) async throws -> (area: CGRect, page: CGSize) {
        let zoom = max(web.pageZoom, 0.01)
        let points = try await prepare(web, target, hit: false)
        let box = CGRect(x: points.minX / zoom, y: points.minY / zoom, width: points.width / zoom, height: points.height / zoom)
        guard box.width > 0, box.height > 0 else { throw Tools.Failure(text: "\(target.label) has no size: there is nothing to picture") }
        let said = (try await raw(web, "[scrollX, scrollY, document.documentElement.scrollWidth, document.documentElement.scrollHeight]") as? [NSNumber])?.map(\.doubleValue) ?? []
        guard said.count == 4 else { throw Tools.Failure(text: "couldn't measure the page") }
        // The page in the view's coordinates: where its top-left is scrolled to.
        let page = CGRect(x: -said[0], y: -said[1], width: max(said[2], web.bounds.width / zoom), height: max(said[3], web.bounds.height / zoom))
        guard let area = Tools.Shots.area(box, padding: padding, within: page) else { throw Tools.Failure(text: "\(target.label) is outside the page") }
        return (area, page.size)
    }

    /// `body` run with the view grown to `size` (CSS pixels, never smaller
    /// than it is), then the view put back and scrolled where it was. WebKit
    /// pictures what the view holds, so what is bigger than the view is had
    /// by making the view that big for a moment. Only when asked.
    @MainActor
    private static func grown<T>(_ web: WKWebView, to size: CGSize, _ body: (CGSize) async throws -> T) async throws -> T {
        let zoom = max(web.pageZoom, 0.01)
        let before = web.frame
        let scrolled = try? await scroll(web)
        let wanted = CGSize(width: max(before.width, (size.width * zoom).rounded()), height: max(before.height, (size.height * zoom).rounded()))
        await resize(web, to: wanted)
        let result: Result<T, Error>
        do { result = .success(try await body(wanted)) } catch { result = .failure(error) }
        web.frame = before
        if let scrolled {
            _ = try? await raw(web, "window.scrollTo({ left: \(scrolled.x), top: \(scrolled.y), behavior: 'instant' }); true", counted: false)
        }
        return try result.get()
    }

    /// The view set to `size` (points), and back once the page has been
    /// laid out at it (a second at most): WebKit may hold a new size back
    /// until the last one is through, and a measurement or a picture taken
    /// before then is of the old layout.
    @MainActor
    private static func resize(_ web: WKWebView, to size: CGSize) async {
        let zoom = max(web.pageZoom, 0.01)
        func inner() async -> [Double]? {
            let said = (try? await raw(web, "[innerWidth, innerHeight]", counted: false) as? [NSNumber])?.map(\.doubleValue)
            return said?.count == 2 ? said : nil
        }
        let from = web.frame.size
        let before = await inner()
        web.frame = CGRect(origin: web.frame.origin, size: size)
        guard let before else { return }
        let goal = (before[0] + (size.width - from.width) / zoom, before[1] + (size.height - from.height) / zoom)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let now = await inner(), abs(now[0] - goal.0) < 1.5, abs(now[1] - goal.1) < 1.5 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
            if web.frame.size != size { web.frame = CGRect(origin: web.frame.origin, size: size) }
        }
    }

    @MainActor
    private static func scroll(_ web: WKWebView) async throws -> CGPoint {
        let said = (try await raw(web, "[scrollX, scrollY]", counted: false) as? [NSNumber])?.map(\.doubleValue) ?? []
        guard said.count == 2 else { throw Tools.Failure(text: "couldn't read where the page is scrolled") }
        return CGPoint(x: said[0], y: said[1])
    }

    /// `area` (CSS pixels, in the view as it is now) drawn by WebKit at the
    /// picture's size (Shots.size). `holding`: the grown size the view must
    /// have when the picture is taken.
    @MainActor
    private static func draw(_ web: WKWebView, _ area: CGRect, _ ask: Tools.Shots.Ask, holding: CGSize? = nil) async throws -> Picture {
        let size = Tools.Shots.size(css: area.size, scale: ask.scale)
        let zoom = max(web.pageZoom, 0.01)
        let rect = Tools.Shots.snapped(CGRect(x: area.minX * zoom, y: area.minY * zoom, width: area.width * zoom, height: area.height * zoom))
        // WebKit draws the page into snapshotWidth × its device scale pixels,
        // so asking for the picture's width over that scale has the page
        // drawn at the picture's own size, whatever the screen. Its sizes are
        // whole points, so the rectangle is first grown a point or two to one
        // whose picture is whole pixels (Shots.whole), and the picture is its
        // top-left corner. When no such rectangle is near (an odd scale), the
        // picture is drawn at the nearest size and scaled the last pixel.
        let ratio = await deviceScale(web)
        let perPoint = size.scale / zoom
        if ratio == ratio.rounded(), let whole = Tools.Shots.whole(rect, k: perPoint / ratio) {
            let drawn = CGSize(width: (whole.width * perPoint).rounded(), height: (whole.height * perPoint).rounded())
            if drawn.width >= Double(size.width), drawn.height >= Double(size.height) {
                let picture = try await snapshot(web, whole, width: whole.width * perPoint / ratio, holding: holding)
                let bitmap = try flatten(picture, into: size, at: CGRect(x: 0, y: Double(size.height) - drawn.height, width: drawn.width, height: drawn.height), opaque: ask.jpeg)
                return try Picture(bitmap, size: size, css: area.size, jpeg: ask.jpeg)
            }
        }
        let picture = try await snapshot(web, rect.intersection(web.bounds), width: Double(size.width) / ratio, holding: holding)
        let bitmap = try flatten(picture, into: size, at: CGRect(x: 0, y: 0, width: size.width, height: size.height), opaque: ask.jpeg)
        return try Picture(bitmap, size: size, css: area.size, jpeg: ask.jpeg)
    }

    /// WebKit's picture drawn at `place` (pixels, y up) in a bitmap of `size`.
    /// Drawn, not read back: NSImage hands out a 1× copy of a picture whose
    /// size in points isn't whole.
    @MainActor
    private static func flatten(_ picture: NSImage, into size: Tools.Shots.Size, at place: CGRect, opaque: Bool) throws -> CGImage {
        picture.cacheMode = .never
        return try bitmap(width: size.width, height: size.height, opaque: opaque) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            picture.draw(in: place, from: .zero, operation: .copy, fraction: 1, respectFlipped: false,
                         hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The page's device scale: devicePixelRatio, read in Copper's own
    /// world (where the page can't redefine it); 2 on a Retina screen, often
    /// 1 headless, and Safari's zoom leaves it alone. Else the window's.
    @MainActor
    private static func deviceScale(_ web: WKWebView) async -> Double {
        if let ratio = (try? await raw(web, "devicePixelRatio", counted: false)) as? NSNumber, ratio.doubleValue >= 0.5, ratio.doubleValue <= 8 {
            return ratio.doubleValue
        }
        return Double(web.window?.backingScaleFactor ?? 1)
    }

    /// One WKWebView snapshot of `rect` (view points), `width` points wide.
    @MainActor
    private static func snapshot(_ web: WKWebView, _ rect: CGRect, width: Double, holding: CGSize?) async throws -> NSImage {
        if let holding, web.frame.size != holding { await resize(web, to: holding) }
        let cut = rect.intersection(web.bounds)
        guard !cut.isNull, cut.width >= 1, cut.height >= 1 else { throw Tools.Failure(text: "nothing of it is in the view to picture") }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        // May pass the view's edge by the point or two Shots.whole added; that strip is cut off.
        config.rect = rect
        config.snapshotWidth = NSNumber(value: max(width.rounded(.up), 1))
        let picture: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: Failure(text: error?.localizedDescription ?? "no picture")) }
            }
        }
        return picture
    }

    /// The answer's image when it isn't the picture (Shots.inline): the
    /// picture drawn down to `size`, from its bitmap so a JPEG isn't
    /// compressed twice. Same format as the picture.
    static func drawnDown(_ picture: Picture, to size: Tools.Shots.Size, jpeg: Bool) throws -> Data {
        try encode(picture.bitmap, width: size.width, height: size.height, jpeg: jpeg)
    }

    /// `image` scaled to exactly `width`×`height` and encoded (see `bitmap`).
    /// Core Graphics' high-quality pass averages all the pixels each new
    /// one covers, however far it is made smaller, so fine text drawn down
    /// comes out smooth, not jagged (ShotsTests).
    static func encode(_ image: CGImage, width: Int, height: Int, jpeg: Bool) throws -> Data {
        try encode(bitmap(width: width, height: height, opaque: jpeg) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }, jpeg: jpeg)
    }

    /// What `paint` draws into a plain 8-bit sRGB bitmap of exactly
    /// `width`×`height` (`opaque` for a JPEG). Drawn at that size, WebKit's
    /// picture comes out right when it is a pixel or two off (it sizes
    /// pictures in whole points).
    static func bitmap(width: Int, height: Int, opaque: Bool, _ paint: (CGContext) -> Void) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        else { throw Failure(text: "couldn't encode the picture") }
        paint(context)
        guard let flat = context.makeImage() else { throw Failure(text: "couldn't encode the picture") }
        return flat
    }

    /// `bitmap` as PNG, or JPEG at quality 0.8.
    static func encode(_ bitmap: CGImage, jpeg: Bool) throws -> Data {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil)
        else { throw Failure(text: "couldn't encode the picture") }
        CGImageDestinationAddImage(out, bitmap, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil)
        guard CGImageDestinationFinalize(out) else { throw Failure(text: "couldn't encode the picture") }
        return data as Data
    }

    /// The full-page walk: a screen at a time to the bottom (a frame and
    /// 40 ms on each), then back. Answers the height to draw.
    static let walk = """
    const tall = () => Math.min(document.documentElement.scrollHeight, \(Int(tallest)));
    const x = scrollX, y = scrollY, step = Math.max(innerHeight * 0.9, 200);
    const beat = () => new Promise(r => { requestAnimationFrame(() => setTimeout(r, 40)); setTimeout(r, 120); });
    for (let top = step; top < tall(); top += step) { scrollTo({ left: x, top, behavior: 'instant' }); await beat(); }
    scrollTo({ left: x, top: y, behavior: 'instant' });
    await beat();
    return tall();
    """

    // MARK: - the helper

    /// The console, kept for browser_console_messages. Put in at document
    /// start for a tab an agent opened (Tab.arm → `arm`), so what a page logs
    /// while it loads is there; in any other tab, when the helper first goes in.
    /// In the page's world — it is the page's `console` being wrapped — so
    /// what it holds is the page's word, read as such (`console`, below).
    static let consoleShim = #"""
    (function () {
      if (window.__copperLogs) return;
      var logs = window.__copperLogs = [];
      ['log', 'warn', 'error', 'info'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try { logs.push({ level: level, text: Array.prototype.map.call(arguments, function (a) { try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }).join(' ') }); if (logs.length > 200) logs.shift(); } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (e) { logs.push({ level: 'error', text: String(e.message) }); });
      // Fork (C8, r4): short timers, so a click's settle can wait for the
      // navigation one of them sets off (Tools.settle → late).
      var timers = [], start = window.setTimeout;
      window.setTimeout = function (f, d) {
        try { d = Number(d) || 0; if (d <= 1000) { timers.push([performance.now(), d]); if (timers.length > 50) timers.shift(); } } catch (e) {}
        return start.apply(window, arguments);
      };
      // How long until the last of the short timers started in the last `ms` fires.
      window.__copperDue = function (ms) {
        var now = performance.now(), due = 0;
        timers.forEach(function (t) { if (now - t[0] <= ms) due = Math.max(due, t[0] + t[1] - now); });
        return due;
      };
    })();
    """#

    /// Part of `Tab.arm`'s inputs (navperf), so a tab an agent opens after its first arm is armed again.
    @MainActor
    static func armsConsole(_ tab: UUID) -> Bool { AgentTabs.opened.contains(tab) }

    /// Tab.arm(hiding:): the console shim for the next document of a tab an
    /// agent opened. Tabs the user opened are left alone.
    @MainActor
    static func arm(_ controller: WKUserContentController, tab: UUID) {
        guard armsConsole(tab) else { return }
        controller.addUserScript(WKUserScript(source: consoleShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// What the recorder holds, as JSON text. Read defensively: the list
    /// sits in the page's world, where the page can put anything in it.
    @MainActor
    static func console(_ web: WKWebView) async throws -> String {
        let read = """
        (function () { try {
          var logs = window.__copperLogs; if (!Array.isArray(logs)) return '[]';
          return JSON.stringify(Array.prototype.slice.call(logs, -200).map(function (l) {
            return { level: String(l && l.level).slice(0, 10), text: String(l && l.text).slice(0, 4000) }; }));
        } catch (e) { return '[]'; } })()
        """
        return try await raw(web, read, world: .page) as? String ?? "[]"
    }

    static let helper = #"""
    (function () {
      if (window.__copper) return true;
      var refs = new Map(), byRef = new Map(), next = 1;

      function ref(el) {
        var r = refs.get(el);
        if (!r) { r = 'e' + (next++); refs.set(el, r); byRef.set(r, el); }
        return r;
      }
      function find(spec) {
        if (!spec) return null;
        // An element in hand (a field inside a label, the focused one): itself, shadow root or not.
        if (typeof spec !== 'string') return spec instanceof Element && spec.isConnected ? spec : null;
        if (spec.indexOf('ref:') === 0) {
          var el = byRef.get(spec.slice(4));
          return el && el.isConnected ? el : null;
        }
        if (spec.indexOf('css:') === 0) spec = spec.slice(4);
        try { return document.querySelector(spec); } catch (e) { return null; }
      }
      function visible(el) {
        if (!(el instanceof Element)) return false;
        var s = getComputedStyle(el);
        if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
        var r = el.getBoundingClientRect();
        return r.width > 0 || r.height > 0 || el.tagName === 'OPTION';
      }
      var interactiveTags = { A: 1, BUTTON: 1, INPUT: 1, SELECT: 1, TEXTAREA: 1, SUMMARY: 1, OPTION: 1, LABEL: 1 };
      function role(el) {
        var explicit = el.getAttribute('role');
        if (explicit) return explicit;
        var t = el.tagName, type = (el.getAttribute('type') || '').toLowerCase();
        switch (t) {
          case 'A': return el.hasAttribute('href') ? 'link' : 'generic';
          case 'BUTTON': return 'button';
          case 'INPUT':
            if (type === 'checkbox') return 'checkbox';
            if (type === 'radio') return 'radio';
            if (type === 'range') return 'slider';
            if (type === 'submit' || type === 'button' || type === 'reset' || type === 'image') return 'button';
            if (type === 'search') return 'searchbox';
            if (type === 'hidden') return '';
            return 'textbox';
          case 'SELECT': return el.multiple ? 'listbox' : 'combobox';
          case 'TEXTAREA': return 'textbox';
          case 'OPTION': return 'option';
          case 'IMG': return el.alt === '' ? 'presentation' : 'img';
          case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
          case 'NAV': return 'navigation';
          case 'MAIN': return 'main';
          case 'HEADER': return 'banner';
          case 'FOOTER': return 'contentinfo';
          case 'ASIDE': return 'complementary';
          case 'FORM': return 'form';
          case 'UL': case 'OL': return 'list';
          case 'LI': return 'listitem';
          case 'TABLE': return 'table';
          case 'TR': return 'row';
          case 'TD': case 'TH': return 'cell';
          case 'DIALOG': return 'dialog';
          case 'ARTICLE': return 'article';
          case 'SECTION': return 'region';
          case 'SUMMARY': return 'button';
          case 'DETAILS': return 'group';
          case 'LABEL': return 'label';
          case 'P': case 'SPAN': case 'DIV': case 'STRONG': case 'EM': case 'B': case 'I': case 'SMALL': case 'CODE': case 'PRE': case 'BLOCKQUOTE': return 'text';
          default: return 'generic';
        }
      }
      function isInteractive(el) {
        if (el.hasAttribute('contenteditable') && el.getAttribute('contenteditable') !== 'false') return true;
        if (el.tagName in interactiveTags && role(el) !== '') return true;
        var r = el.getAttribute('role');
        if (r && /button|link|checkbox|radio|tab|menuitem|option|switch|slider|textbox|combobox|searchbox|treeitem/.test(r)) return true;
        if (el.hasAttribute('onclick') || (el.tabIndex >= 0 && el.tagName !== 'BODY' && el.tagName !== 'HTML')) return true;
        return getComputedStyle(el).cursor === 'pointer' && el.children.length < 4;
      }
      function name(el) {
        var aria = el.getAttribute('aria-label'); if (aria) return aria.trim();
        var by = el.getAttribute('aria-labelledby');
        if (by) { var parts = by.split(/\s+/).map(function (id) { var n = document.getElementById(id); return n ? n.textContent.trim() : ''; }).filter(Boolean); if (parts.length) return parts.join(' '); }
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
          if (el.labels && el.labels.length) return Array.prototype.map.call(el.labels, function (l) { return l.textContent.trim(); }).join(' ');
          if (el.placeholder) return el.placeholder;
          if (el.title) return el.title;
          if (el.name) return el.name;
          if (el.value && el.type === 'submit') return el.value;
          return '';
        }
        if (el.tagName === 'IMG') return el.alt || el.title || '';
        var text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
        if (!text && el.title) text = el.title;
        return text.length > 120 ? text.slice(0, 117) + '…' : text;
      }
      // Fork (secret-redact): a box whose value is a secret — a password box
      // (or one that was, before a "show password" turned it to text), one
      // whose autocomplete promises a password, a one-time code or a card's
      // number or code, or one Copper filled with a secret (Forms.script keeps
      // those in __copperSecretFields, in this same world, out of the page's
      // reach). Its value is never read out: it says SECRET (AgentSecrets).
      var SECRET = \#(Tools.Page.quote(AgentSecrets.placeholder));
      function secretField(el) {
        if (!el || el.nodeType !== 1) return false;
        try {
          var w = el.ownerDocument && el.ownerDocument.defaultView, kept = w && w.__copperSecretFields;
          if (kept && kept.has(el)) return true;
        } catch (e) {}
        if (el.tagName === 'INPUT' && (String(el.type).toLowerCase() === 'password' || String(el.getAttribute('type') || '').toLowerCase() === 'password')) return true;
        return /(^|\s)(current-password|new-password|one-time-code|cc-number|cc-csc)(\s|$)/i.test(el.getAttribute('autocomplete') || '');
      }
      function attrs(el) {
        var out = [];
        var r = role(el);
        if (el.tagName === 'A' && el.href) out.push('/url: ' + el.getAttribute('href'));
        if (r === 'heading') out.push('[level=' + (el.getAttribute('aria-level') || el.tagName.slice(1)) + ']');
        if (r === 'checkbox' || r === 'radio' || r === 'switch') out.push('[checked=' + (el.checked || el.getAttribute('aria-checked') === 'true') + ']');
        if ((r === 'textbox' || r === 'searchbox' || r === 'combobox') && el.value) out.push('[value=' + JSON.stringify(secretField(el) ? SECRET : String(el.value).slice(0, 80)) + ']');
        else if (el.value && secretField(el)) out.push('[value=' + JSON.stringify(SECRET) + ']');
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') out.push('[disabled]');
        if (el.getAttribute('aria-expanded')) out.push('[expanded=' + el.getAttribute('aria-expanded') + ']');
        if (el.getAttribute('aria-selected') === 'true') out.push('[selected]');
        if (document.activeElement === el) out.push('[active]');
        return out.join(' ');
      }
      // `prefix`: the frame's name on every ref (f2:e7), '' in the page itself.
      // Answers the text and which of its lines are frames (`at`: the place
      // among this document's frames), so each frame's own snapshot can go
      // under its line (Frames.stitch).
      function snapshot(selector, interactiveOnly, limit, prefix) {
        var root = selector ? find(selector.indexOf(':') > 0 ? selector : 'css:' + selector) : document.body;
        if (!root) return { text: 'nothing matches ' + selector, frames: [] };
        var lines = [], count = 0, frames = [], named = [];
        function walk(el, depth) {
          if (count >= limit) return;
          if (!(el instanceof Element)) return;
          var tag = el.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE' || tag === 'SVG' || tag === 'PATH') return;
          if (el.getAttribute('aria-hidden') === 'true') return;
          var r = role(el);
          var shown = visible(el);
          var inter = shown && isInteractive(el);
          var nm = shown ? name(el) : '';
          var ownText = '';
          for (var i = 0; i < el.childNodes.length; i++) { var n = el.childNodes[i]; if (n.nodeType === 3) ownText += n.textContent; }
          ownText = ownText.replace(/\s+/g, ' ').trim();
          var landmark = /navigation|main|banner|contentinfo|complementary|form|dialog|region|article|list|table|heading/.test(r);
          var framed = shown && (tag === 'IFRAME' || tag === 'FRAME') ? frameIndex(el) : -1;
          // A frame too small to show anything is a tracker or a bridge, not part of the page.
          if (framed >= 0) { var box = el.getBoundingClientRect(); if (box.width < 8 || box.height < 8) return; }
          if (framed >= 0) {
            var title = el.getAttribute('title') || el.getAttribute('aria-label') || el.getAttribute('name') || '';
            frames.push({ line: lines.length, at: framed });
            lines.push('  '.repeat(Math.min(depth, 12)) + '- iframe' + (title ? ' ' + JSON.stringify(title.slice(0, 120)) : ''));
            count++;
            return;
          }
          var emit = inter || (!interactiveOnly && shown && (landmark || (ownText && r === 'text') || (r === 'img' && nm)));
          if (emit) {
            var line = '  '.repeat(Math.min(depth, 12)) + '- ' + (r || 'generic');
            var label = inter || r === 'heading' || r === 'img' ? nm : landmark ? (el.getAttribute('aria-label') || '') : ownText;
            if (label) line += ' ' + JSON.stringify(label.length > 120 ? label.slice(0, 117) + '…' : label);
            if (inter) line += ' [ref=' + (prefix || '') + ref(el) + ']';
            if (inter && interactiveOnly && label) named.push({ i: lines.length, el: el, r: r, nm: nm, quoted: JSON.stringify(label.length > 120 ? label.slice(0, 117) + '…' : label) });
            var a = attrs(el); if (a) line += ' ' + a;
            if (!inter && r === 'text' && !landmark && lines.length && lines[lines.length - 1].endsWith(line.trim())) { /* skip duplicate */ } else { lines.push(line); count++; }
          }
          // Fork (secret-redact): a box's own inner tree (WebKit shows it here) is its
          // value drawn as text; a secret box's is never walked.
          var kids = el.shadowRoot && !secretField(el) ? Array.prototype.slice.call(el.shadowRoot.children) : [];
          kids = kids.concat(Array.prototype.slice.call(el.children));
          for (var k = 0; k < kids.length; k++) walk(kids[k], emit ? depth + 1 : depth);
        }
        walk(root, 0);
        if (interactiveOnly) rowNames(lines, named);
        if (count >= limit) lines.push('… (truncated at ' + limit + ' nodes; pass a selector or interactive: true for less)');
        return { text: lines.join('\n'), frames: frames };
      }
      // interactive: true leaves the rows' text out, so a table of "Approve"
      // buttons read as eight alike. Controls by one name that go to
      // different places each say their row (Jev's table does the same).
      function rowNames(lines, named) {
        var groups = {}, told = 0;
        named.forEach(function (n) { var k = n.r + '|' + n.nm.toLowerCase(); (groups[k] = groups[k] || []).push(n); });
        Object.keys(groups).forEach(function (k) {
          var g = groups[k], places = {};
          g.forEach(function (n) { places[n.el.href || n.i] = 1; });
          if (g.length < 2 || Object.keys(places).length < 2) return;
          g.forEach(function (n) {
            var row = n.el.closest('tr,li,[role="row"],[role="listitem"],article,[role="article"]');
            if (!row || told >= 40) return;
            var said = (row.innerText || '').replace(/\s+/g, ' ').replace(n.nm, '').trim().slice(0, 60);
            if (!said) return;
            lines[n.i] = lines[n.i].replace(n.quoted, JSON.stringify(n.nm.slice(0, 117) + ' · ' + said));
            told++;
          });
        });
      }
      // Frames. Windows compare across origins, so a frame can say where it
      // is and its parent which element holds it without reading each other.
      function frameIndex(el) {
        try { for (var i = 0; i < window.length; i++) if (window[i] === el.contentWindow) return i; } catch (e) {}
        return -1;
      }
      // This document's place: its index among its parent's frames, at each level from the top. [] for the page.
      function where() {
        var path = [];
        try {
          for (var w = window; w !== w.parent; w = w.parent) {
            var at = -1;
            for (var i = 0; i < w.parent.length; i++) if (w.parent[i] === w) { at = i; break; }
            if (at < 0) return [];
            path.unshift(at);
          }
        } catch (e) { return []; }
        return path;
      }
      // Where frame `at`'s viewport starts in this one's, after bringing the
      // point (x, y of the frame's viewport) into view; with `hitTest`, the
      // frame must be what is at that point here.
      function frameBox(at, x, y, hitTest) {
        var el = null;
        // Through open shadow roots too: a component can hold the frame.
        (function look(root) {
          var all = root.querySelectorAll('iframe, frame');
          for (var i = 0; i < all.length && !el; i++) if (frameIndex(all[i]) === at) el = all[i];
          if (el) return;
          var every = root.querySelectorAll('*');
          for (var j = 0; j < every.length && !el; j++) if (every[j].shadowRoot) look(every[j].shadowRoot);
        })(document);
        if (!el) return { error: 'its frame is not on the page any more' };
        function box() {
          var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
          return { x: r.left + el.clientLeft + (parseFloat(cs.paddingLeft) || 0), y: r.top + el.clientTop + (parseFloat(cs.paddingTop) || 0) };
        }
        var b = box(), px = b.x + x, py = b.y + y;
        if (px < 0 || py < 0 || px >= innerWidth || py >= innerHeight) {
          el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          b = box(); px = b.x + x; py = b.y + y;
          if (px < 0 || py < 0 || px >= innerWidth || py >= innerHeight) { window.scrollBy(px - innerWidth / 2, py - innerHeight / 2); b = box(); px = b.x + x; py = b.y + y; }
        }
        if (!hitTest) return b;
        var hit = px >= 0 && py >= 0 && px < innerWidth && py < innerHeight ? deepAt(px, py) : null;
        if (hit === el) return b;
        if (!hit) return { error: 'its frame is outside the visible page', blocked: true };
        return { error: 'covered by ' + describe(hit) + ' (it is on top of the frame, and would get the click)', blocked: true, cover: describe(hit) };
      }
      // browser_evaluate runs in the page's world, which has no refs: the
      // element is handed over by an attribute the function's wrapper takes
      // off again.
      function mark(spec, token) {
        var el = find(spec);
        if (!el) return false;
        el.setAttribute('data-copper-eval', token);
        return true;
      }
      // The element at a point, through open shadow roots.
      function deepAt(x, y) {
        var hit = document.elementFromPoint(x, y);
        while (hit && hit.shadowRoot) { var inner = hit.shadowRoot.elementFromPoint(x, y); if (!inner || inner === hit) break; hit = inner; }
        return hit;
      }
      function inside(node, el) {
        for (var n = node; n; n = n.parentNode || (n instanceof ShadowRoot ? n.host : null)) if (n === el) return true;
        return false;
      }
      function describe(el) {
        var s = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '');
        if (!el.id && typeof el.className === 'string' && el.className.trim()) s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
        var t = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
        return t ? s + ' ' + JSON.stringify(t.length > 60 ? t.slice(0, 57) + '…' : t) : s;
      }
      function hidden(el) {
        var s = getComputedStyle(el);
        if (s.display === 'none') return 'display: none';
        if (s.visibility === 'hidden') return 'visibility: hidden';
        if (s.opacity === '0') return 'opacity: 0';
        var r = el.getBoundingClientRect();
        return r.width === 0 && r.height === 0 ? 'no size' : '';
      }
      function rect(spec, hitTest) {
        var el = find(spec);
        if (!el) return { error: 'no element for ' + spec };
        if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'center' });
        var r = el.getBoundingClientRect();
        // A tiny or offscreen box means a wrapper; the first sized child is the thing.
        if ((r.width < 2 || r.height < 2) && el.firstElementChild) r = el.firstElementChild.getBoundingClientRect();
        var out = { x: r.left, y: r.top, width: r.width, height: r.height, at: where() };
        if (!hitTest || el.tagName === 'OPTION') return out;
        var x = r.left + r.width / 2, y = r.top + r.height / 2;
        var hit = x >= 0 && y >= 0 && x < innerWidth && y < innerHeight ? deepAt(x, y) : null;
        // Its own, or its label's (a styled checkbox is often only its label).
        if (hit && (inside(hit, el) || Array.prototype.some.call(el.labels || [], function (l) { return inside(hit, l); }))) return out;
        var why = hidden(el);
        if (why) return { error: 'not visible (' + why + ')', blocked: true };
        if (!hit) return { error: 'outside the visible page, at ' + Math.round(x) + ',' + Math.round(y), blocked: true };
        return { error: 'covered by ' + describe(hit) + ' (it is on top, and would get the click)', blocked: true, cover: describe(hit) };
      }
      function fire(el, type, init) { el.dispatchEvent(new (type.indexOf('key') === 0 ? KeyboardEvent : type.indexOf('mouse') === 0 || type === 'click' || type === 'dblclick' || type === 'contextmenu' ? MouseEvent : Event)(type, Object.assign({ bubbles: true, cancelable: true, composed: true }, init || {}))); }
      // A field the user can't change either: an error, never a quiet write.
      function locked(el) {
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') return 'not editable: ' + el.tagName + ' is disabled';
        if (el.readOnly && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) return 'not editable: ' + el.tagName + ' is read-only (a picker may open when you click it)';
        return '';
      }
      function setValue(spec, value) {
        var el = find(spec);
        if (!el) return 'no element for ' + spec;
        if (locked(el)) return locked(el);
        el.focus && el.focus();
        if (el.isContentEditable) {
          el.textContent = value;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
          return 'ok';
        }
        if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') {
          var inner = el.querySelector('input, textarea, [contenteditable]');
          if (inner) return setValue(inner, value);
          return 'not editable: ' + el.tagName;
        }
        var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) d.set.call(el, value); else el.value = value;
        fire(el, 'input'); fire(el, 'change');
        return 'ok';
      }
      function select(spec, values) {
        var el = find(spec);
        if (!el) return 'no element for ' + spec;
        if (el.tagName !== 'SELECT') { el = el.querySelector('select') || el; }
        if (el.tagName !== 'SELECT') return 'not a select';
        if (locked(el)) return locked(el);
        var hit = 0;
        for (var i = 0; i < el.options.length; i++) {
          var o = el.options[i];
          var on = values.indexOf(o.value) >= 0 || values.indexOf(o.label) >= 0 || values.indexOf(o.textContent.trim()) >= 0;
          if (el.multiple) o.selected = on; else if (on) { el.selectedIndex = i; hit++; break; }
          if (on) hit++;
        }
        fire(el, 'input'); fire(el, 'change');
        return hit ? 'selected ' + hit : 'no option matched ' + JSON.stringify(values);
      }
      function fill(spec, kind, value) {
        var el = find(spec);
        if (!el) return 'no element for ' + spec;
        if (locked(el)) return locked(el);
        if (kind === 'checkbox' || kind === 'radio') {
          var want = value === 'true' || value === 'on' || value === '1' || value === 'checked';
          if (el.checked !== want) el.click();
          return 'ok';
        }
        if (kind === 'combobox' && el.tagName === 'SELECT') return select(spec, [value]);
        if (kind === 'slider') { var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value'); d.set.call(el, value); fire(el, 'input'); fire(el, 'change'); return 'ok'; }
        return setValue(spec, value);
      }
      function click(spec, dbl, button) {
        var el = find(spec);
        if (!el) return 'no element for ' + spec;
        el.scrollIntoView && el.scrollIntoView({ block: 'center' });
        el.focus && el.focus();
        var b = button === 'right' ? 2 : button === 'middle' ? 1 : 0;
        var r = el.getBoundingClientRect(), init = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: b, buttons: 1 << b };
        fire(el, 'pointerdown', init); fire(el, 'mousedown', init); fire(el, 'pointerup', init); fire(el, 'mouseup', init);
        if (b === 2) { fire(el, 'contextmenu', init); return 'ok'; }
        if (b === 0) { el.click(); if (dbl) fire(el, 'dblclick', init); }
        return 'ok';
      }
      function hover(spec) { var el = find(spec); if (!el) return 'no element for ' + spec; var r = el.getBoundingClientRect(); var init = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }; fire(el, 'pointerover', init); fire(el, 'mouseover', init); fire(el, 'mouseenter', init); fire(el, 'mousemove', init); return 'ok'; }
      function focus(spec) { var el = find(spec); if (!el) return 'no element for ' + spec; if (locked(el)) return locked(el); if (el.focus) el.focus(); return 'ok'; }
      function submit(spec) { var el = find(spec); if (!el) return 'no element'; var f = el.tagName === 'FORM' ? el : el.form || el.closest('form'); if (!f) { fire(el, 'keydown', { key: 'Enter', code: 'Enter', keyCode: 13 }); fire(el, 'keyup', { key: 'Enter', code: 'Enter', keyCode: 13 }); return 'enter'; } if (f.requestSubmit) f.requestSubmit(); else f.submit(); return 'ok'; }
      // Without a window to press keys in: a keydown of the same shape, the
      // modifiers on it, and when the page leaves a ⌘/⌃ shortcut alone, the
      // editing command it stands for — as the Edit and Format menus would.
      function key(k, mods) {
        mods = mods || {};
        var el = document.activeElement || document.body;
        while (el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; // the box inside a widget, not its host
        var init = { key: k, code: k.length === 1 ? 'Key' + k.toUpperCase() : k, keyCode: k === 'Enter' ? 13 : k === 'Escape' ? 27 : k === 'Tab' ? 9 : k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0,
                     metaKey: !!mods.meta, ctrlKey: !!mods.ctrl, altKey: !!mods.alt, shiftKey: !!mods.shift };
        var down = new KeyboardEvent('keydown', Object.assign({ bubbles: true, cancelable: true, composed: true }, init));
        var used = !el.dispatchEvent(down);
        var shortcut = mods.meta || mods.ctrl;
        if (!used && shortcut) {
          var c = { a: 'selectAll', b: 'bold', i: 'italic', u: 'underline', c: 'copy', x: 'cut', z: mods.shift ? 'redo' : 'undo' }[k.toLowerCase()];
          if (c) document.execCommand(c);
        } else if (!used && k.length === 1 && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) {
          setValue(el, el.value + k);
        }
        fire(el, 'keyup', init);
        if (!used && !shortcut && k === 'Enter') submit(el);
        return 'ok';
      }
      // An HTML5 drag (a draggable="true" source) the way WebKit runs one,
      // in the page: one DataTransfer from dragstart to drop. A real press on
      // such a source would start a system drag session, which a page off
      // screen can't have. Says whether the target took the drop.
      function drag(a, b) {
        var from = find(a), to = find(b);
        if (!from) return { error: 'no element for ' + a };
        if (!to) return { error: 'no element for ' + b };
        var src = from.closest('[draggable="true"]') || from;
        var dt = new DataTransfer();
        function send(el, type) {
          var r = el.getBoundingClientRect();
          var ev = new DragEvent(type, { bubbles: true, cancelable: type !== 'dragleave' && type !== 'dragend' && type !== 'drag', composed: true, dataTransfer: dt,
                                         clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 });
          el.dispatchEvent(ev);
          return ev;
        }
        if (send(src, 'dragstart').defaultPrevented) return { refused: 'the page cancelled the dragstart' };
        send(src, 'drag');
        var tr = to.getBoundingClientRect();
        var hit = document.elementFromPoint(tr.left + tr.width / 2, tr.top + tr.height / 2);
        var over = hit && to.contains(hit) ? hit : to;
        send(over, 'dragenter');
        // Per the spec the drop only fires on a target whose dragover was cancelled.
        var accepted = send(over, 'dragover').defaultPrevented;
        if (accepted) { send(over, 'drop'); } else { send(over, 'dragleave'); }
        send(src, 'dragend');
        return { accepted: accepted };
      }
      // Files dropped as from Finder (browser_file_upload ref): real File
      // objects in one DataTransfer, dragenter → dragover → drop.
      function drop(spec, files) {
        var el = find(spec);
        if (!el) return { error: 'no element for ' + spec };
        if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'center' });
        var dt = new DataTransfer();
        files.forEach(function (f) {
          var bin = atob(f.data), bytes = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          dt.items.add(new File([bytes], f.name, { type: f.type }));
        });
        var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
        var hit = document.elementFromPoint(x, y), over = hit && el.contains(hit) ? hit : el;
        function send(type) {
          var ev = new DragEvent(type, { bubbles: true, cancelable: type !== 'dragleave', composed: true, dataTransfer: dt, clientX: x, clientY: y });
          over.dispatchEvent(ev);
          return ev;
        }
        send('dragenter');
        var accepted = send('dragover').defaultPrevented;
        send(accepted ? 'drop' : 'dragleave');
        return { accepted: accepted };
      }
      function draggable(spec) { var el = find(spec); return !!(el && el.closest('[draggable="true"]')); }
      // What a pointer at the centre of spec would be over, and whether the
      // page now says it is hovered.
      function hovered(spec) {
        var el = find(spec);
        if (!el) return { error: 'no element for ' + spec };
        var r = el.getBoundingClientRect();
        var top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        var tops = top ? top.tagName.toLowerCase() + (top.id ? '#' + top.id : '') + (top.className && typeof top.className === 'string' ? '.' + top.className.trim().split(/\s+/).join('.') : '') : 'nothing';
        return { hover: el.matches(':hover'), covered: !!top && top !== el && !el.contains(top), top: tops };
      }
      // Changes to the page while an action runs, Copper's own trail left out.
      var watching = null, changed = 0;
      function watch() {
        if (watching) watching.disconnect();
        changed = 0;
        watching = new MutationObserver(function (list) { count(list); });
        watching.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
        return true;
      }
      function count(list) {
        for (var i = 0; i < list.length; i++) {
          var n = list[i].target; var el = n.nodeType === 1 ? n : n.parentElement;
          if (el && el.closest && el.closest('#__jev-trail')) continue;
          if (list[i].addedNodes && list[i].addedNodes.length === 1 && list[i].addedNodes[0].id === '__jev-trail') continue;
          changed++;
        }
      }
      function changes() {
        if (!watching) return -1;
        count(watching.takeRecords()); watching.disconnect(); watching = null;
        return changed;
      }
      // The nearest box around el that scrolls the way asked; null for the page.
      function scroller(el, dx, dy) {
        for (var n = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement || (n.getRootNode().host || null)) {
          var s = getComputedStyle(n);
          if (dy && /auto|scroll|overlay/.test(s.overflowY) && n.scrollHeight > n.clientHeight) return n;
          if (dx && /auto|scroll|overlay/.test(s.overflowX) && n.scrollWidth > n.clientWidth) return n;
        }
        return null;
      }
      function scroll(spec, dx, dy) {
        var el = spec ? find(spec) : null;
        if (spec && !el) return 'no element for ' + spec;
        (el && scroller(el, dx, dy) || window).scrollBy({ left: dx, top: dy, behavior: 'instant' });
        return 'ok';
      }
      function text(spec) {
        var el = spec ? find(spec) : (document.querySelector('main, article, [role=main]') || document.body);
        if (!el) return 'no element for ' + spec;
        if (secretField(el)) return el.value ? SECRET : ''; // Fork (secret-redact)
        var t = (el.innerText || el.textContent || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
        return t.length > 60000 ? t.slice(0, 60000) + '\n… (truncated)' : t;
      }
      function findText(needle) {
        var n = needle.toLowerCase(), out = [];
        var all = document.body.querySelectorAll('*');
        for (var i = 0; i < all.length && out.length < 40; i++) {
          var el = all[i];
          if (!visible(el)) continue;
          var own = '';
          for (var j = 0; j < el.childNodes.length; j++) if (el.childNodes[j].nodeType === 3) own += el.childNodes[j].textContent;
          if (own.toLowerCase().indexOf(n) < 0) continue;
          var target = el.closest('a, button, [role=button], [role=link], input, label, [tabindex]') || el;
          out.push('- ' + role(target) + ' ' + JSON.stringify(own.replace(/\s+/g, ' ').trim().slice(0, 100)) + ' [ref=' + ref(target) + ']');
        }
        return out.length ? out.join('\n') : 'no visible text matches ' + JSON.stringify(needle);
      }
      window.__copper = { doc: function () { return (window.__officeForms || window.__officeFormsStub || { doc: '' }).doc; }, where: where, frameBox: frameBox, mark: mark,
        snapshot: snapshot, find: find, rect: rect, setValue: setValue, select: select, fill: fill, click: click, hover: hover, focus: focus, submit: submit, key: key, drag: drag, drop: drop, draggable: draggable, hovered: hovered, watch: watch, changes: changes, scroll: scroll, text: text, findText: findText };
      return true;
    })();
    """#
}
}
