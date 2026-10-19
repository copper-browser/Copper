import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// Posters: what a live web frame shows while its <iframe> is unloaded. A board
// with forty live sites can't keep forty pages running, so the page keeps only
// the few on screen live and draws the rest from a picture of how each looked
// (canvas-app src/canvas/frames.ts). The page can't take that picture — a
// cross-site frame's pixels are not its to read — so it asks Copper:
//
//   page → host  {type: 'framePoster', name, id, url, rect: {x, y, w, h}, maxWidth}
//                (name: the iframe's window.name; rect: its content box in CSS px
//                of the board's viewport — fully on screen when asked)
//   host → page  window.copperCanvas.framePoster(name, dataUrl | null)
//                (a data:image/jpeg URL at most maxWidth px wide, aspect kept;
//                null: no picture could be taken)
//
// The board's WKWebView is snapshotted at that rect (WebKit composites the
// frame's process into it, so the site is in the picture as you saw it). The
// encoding — scaling, JPEG, base64 — is done off the main thread; the main
// thread only asks WebKit and hands back the answer. Asked again for the same
// frame within `interval`, or while its last picture is still being made, the
// host says nothing: the page already has, or is about to get, a fresh one. An
// older page never asks; an older host never answers, and the page keeps its
// card. Contract: reports/2026-10-16-copper-canvas-perf/CONTRACT.md §A.3.

@MainActor
final class CanvasPosters {
    static let shared = CanvasPosters()

    /// At most one picture per frame this often (the page asks every 30 s at
    /// most, and once more right before it unloads a frame).
    static let interval: TimeInterval = 5
    /// Never wider than this, whatever the page asks for.
    static let widest = 1280
    nonisolated static let quality = 0.7
    /// A snapshot WebKit hasn't answered in this long is answered with null.
    static let patience: TimeInterval = 4

    private var last: [String: Date] = [:]
    /// Frames whose picture is being made, each with its ticket (an answer for an older one is dropped).
    private var making: [String: Int] = [:]
    private var tickets = 0
    private let encoder = DispatchQueue(label: "copper.canvas.posters", qos: .utility)

    /// For the bench and QA: how many were asked for, sent, failed and skipped.
    private(set) var counts: [String: Int] = ["asked": 0, "sent": 0, "failed": 0, "skipped": 0]
    /// The last one sent: frame name, shape id, size in bytes and pixels, milliseconds from ask to answer.
    private(set) var lastSent: [String: Any] = [:]

    var report: [String: Any] { ["counts": counts, "last": lastSent] }

    /// A `framePoster` message from the board in `web`.
    func take(_ body: [String: Any], from web: WKWebView, host: CanvasHost) {
        guard let name = body["name"] as? String, !name.isEmpty, name.count <= 256 else { return }
        counts["asked", default: 0] += 1
        let key = "\(ObjectIdentifier(web).hashValue)/\(name)"
        let now = Date()
        if making[key] != nil || last[key].map({ now.timeIntervalSince($0) < CanvasPosters.interval }) == true {
            counts["skipped", default: 0] += 1
            return
        }
        guard let rect = CanvasPosters.rect(body["rect"], in: web) else {
            fail(name, host: host, web: web)
            return
        }
        let asked = (body["maxWidth"] as? NSNumber)?.intValue ?? 640
        let width = max(16, min(CanvasPosters.widest, asked))
        last[key] = now
        tickets += 1
        let ticket = tickets
        making[key] = ticket
        if last.count > 400 { last = last.filter { now.timeIntervalSince($0.value) < 60 } }

        let config = WKSnapshotConfiguration()
        config.rect = rect
        // The frame has been on screen and settled for seconds: its last
        // painted frame is the picture, without asking WebKit for another.
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: min(Double(width), Double(rect.width)))
        let finish: (String?, Int, Int) -> Void = { [weak self, weak host, weak web] dataUrl, w, h in
            guard let self, self.making[key] == ticket else { return }
            self.making[key] = nil
            guard let host, let web else { return }
            if let dataUrl {
                self.counts["sent", default: 0] += 1
                self.lastSent = ["name": name, "id": body["id"] as? String ?? "", "bytes": dataUrl.utf8.count, "width": w, "height": h,
                                 "ms": Int(Date().timeIntervalSince(now) * 1000), "at": ISO8601DateFormatter().string(from: Date())]
                self.send(name, dataUrl, host: host, web: web)
            } else {
                self.fail(name, host: host, web: web)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasPosters.patience) { MainActor.assumeIsolated { finish(nil, 0, 0) } }
        web.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, self.making[key] == ticket, let image, let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    finish(nil, 0, 0)
                    return
                }
                self.encoder.async {
                    let encoded = CanvasPosters.jpeg(picture, width: width).map { ("data:image/jpeg;base64," + $0.0.base64EncodedString(), $0.1, $0.2) }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let (dataUrl, w, h) = encoded {
                                finish(dataUrl, w, h)
                            } else {
                                finish(nil, 0, 0)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fail(_ name: String, host: CanvasHost, web: WKWebView) {
        counts["failed", default: 0] += 1
        send(name, nil, host: host, web: web)
    }

    private func send(_ name: String, _ dataUrl: String?, host: CanvasHost, web: WKWebView) {
        // Only to the page that asked: not one loaded into the view since.
        guard host.tab?.built === web else { return }
        Task { @MainActor in
            _ = try? await host.call("const c = window.copperCanvas; if (c && typeof c.framePoster === 'function') c.framePoster(n, d);",
                                     ["n": name, "d": dataUrl as Any? ?? NSNull()])
        }
    }

    /// The page's rect (CSS px in the board's viewport) in the view's points,
    /// when most of it is on the view: nil for a rect that is nonsense, tiny or off it.
    static func rect(_ value: Any?, in web: WKWebView) -> CGRect? {
        guard let r = value as? [String: Any] else { return nil }
        func n(_ key: String) -> CGFloat? {
            guard let v = (r[key] as? NSNumber)?.doubleValue, v.isFinite else { return nil }
            return CGFloat(v)
        }
        guard let x = n("x"), let y = n("y"), let w = n("w"), let h = n("h"), w >= 8, h >= 8 else { return nil }
        let zoom = web.pageZoom > 0 ? web.pageZoom : 1
        let asked = CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
        let shown = asked.intersection(web.bounds)
        guard !shown.isNull, shown.width * shown.height >= asked.width * asked.height * 0.9 else { return nil }
        return shown.integral.intersection(web.bounds)
    }

    /// `picture` at most `width` px wide (aspect kept) as a JPEG. Off the main thread.
    nonisolated static func jpeg(_ picture: CGImage, width: Int) -> (Data, Int, Int)? {
        var image = picture
        if picture.width > width {
            let height = max(1, Int((Double(picture.height) * Double(width) / Double(picture.width)).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            image = scaled
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, image.width, image.height)
    }
}
