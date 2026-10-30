import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// Pictures of one shared tab, for the page that is sharing it.
//
// Measured before this was written (docs/screen-sharing.md › Why this way):
// WKWebView.takeSnapshot — public, no Screen Recording grant — pictures a
// 1280×720 page in under a millisecond on macOS 27 (its GPU process does
// the drawing) and a 1920×1080 one in about two; a JPEG of either takes one
// to three milliseconds off the main thread. The page asks for each picture
// over its script message handler and waits for the next one (a long poll),
// so a slow page is never sent pictures it cannot draw: it gets the newest.
// 30 frames a second end to end cost about a third of one core at 720p.
//
// A tick: hang the tab where it can paint if it has nowhere to be
// (TabShareStage), take one snapshot at a time, encode it on a queue of its
// own, and hand it to whoever is waiting — when it differs from the last one,
// or once a second regardless, so a still slide still looks alive.
@MainActor
final class TabShareCapture {
    /// A page's request for the next picture, answered exactly once: WebKit
    /// raises an exception for a reply handler let go without being called,
    /// so one dropped by mistake is answered on its way out.
    final class Reply {
        private var handler: ((Any?, String?) -> Void)?
        init(_ handler: @escaping (Any?, String?) -> Void) { self.handler = handler }
        func callAsFunction(_ value: Any?) {
            guard let handler else { return }
            self.handler = nil
            handler(value, nil)
        }
        deinit { handler?(nil, nil) }
    }

    let share: String
    weak var tab: Tab?
    private(set) var want: TabShareRules.Want
    private(set) var fps: Double
    private(set) var size: (width: Int, height: Int) = (0, 0)
    var label: String

    private var timer: Timer?
    private var inFlight = false
    private(set) var seq = 0
    private var latest: [String: Any]?
    private var lastPicture: Data?
    private var lastPublish: CFTimeInterval = 0
    private var waiting: [(after: Int, reply: Reply, at: CFTimeInterval)] = []
    private(set) var ended: String?
    private(set) var lastAsked = Date()
    /// How many times the page has asked for a picture.
    private(set) var asked = 0
    /// Ticks that took no picture because nobody wanted one.
    private(set) var idleTicks = 0

    // What the bench reports.
    private(set) var snapshots = 0
    private(set) var published = 0
    private(set) var served = 0
    private(set) var failures = 0
    private(set) var snapshotMs = 0.0
    private(set) var encodeMs = 0.0
    private(set) var bytes = 0
    private var window: [CFTimeInterval] = []
    // Where a picture's time goes, for the bench (`timing`): between two
    // ticks of the capture's timer, a page's ask waiting for its picture,
    // and a picture handed over until the page asks again (its decode and
    // draw, and the trip both ways). A late tick is Copper slowed by macOS;
    // a slow page is the page's own process (docs/screen-sharing.md › How
    // it works, step 6).
    private var lastTick: CFTimeInterval = 0
    private var lastServed: CFTimeInterval = 0
    private var tickGaps = TabShareRules.Spread(), waits = TabShareRules.Spread(), turns = TabShareRules.Spread()

    /// Called on every tick before the snapshot: the share keeps its pages
    /// where they can paint (TabShare.keepPainting).
    var beforeTick: (() -> Void)?

    private static let encoder = DispatchQueue(label: "copper.tabshare.encode", qos: .userInitiated)

    init(share: String, tab: Tab, want: TabShareRules.Want) {
        self.share = share
        self.tab = tab
        self.want = want
        fps = TabShareRules.fps(want)
        label = tab.label
        if let web = tab.built { size = TabShareRules.pixels(for: web.bounds.size, want: want) }
    }

    func start() {
        schedule()
        tick()
    }

    /// The page asked for another size or pace (applyConstraints).
    func tune(_ fresh: TabShareRules.Want) {
        want = fresh
        let pace = TabShareRules.fps(fresh)
        if pace != fps {
            fps = pace
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        // Common modes: a menu held open or a window being resized must not
        // freeze the call's picture.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard ended == nil else { return }
        let now = CACurrentMediaTime()
        if lastTick > 0 { tickGaps.add((now - lastTick) * 1000) }
        lastTick = now
        beforeTick?()
        // Back-pressure: no snapshot, no JPEG, for a page that is not asking.
        guard TabShareRules.pictures(waiting: waiting.count, sinceAsked: Date().timeIntervalSince(lastAsked)) else {
            idleTicks += 1
            return
        }
        guard !inFlight, let tab, let web = tab.built else { return }
        let bounds = web.bounds
        guard bounds.width >= 2, bounds.height >= 2 else { return }
        let pixels = TabShareRules.pixels(for: bounds.size, want: want)
        size = pixels
        // WebKit multiplies the width asked for by the page's own scale — 2
        // on a Retina stage, whatever the parked window's screen says off
        // it — and gives no public way to read that scale. So it is learnt:
        // the first picture says how wide it came back, and the next asks
        // for exactly the pixels wanted. Asked this way the page is painted
        // once, at the picture's size, and never scaled again.
        let scale = pageScale ?? max(web.window?.backingScaleFactor ?? 1, 1)
        let points = Double(pixels.width) / Double(scale)
        let configuration = WKSnapshotConfiguration()
        // Exactly the picture's size, even both ways as video encoders like,
        // not a pixel short (TabShareRules.snapshotRect).
        configuration.rect = TabShareRules.snapshotRect(bounds: bounds.size, pixels: pixels)
        configuration.snapshotWidth = NSNumber(value: points)
        inFlight = true
        let started = CACurrentMediaTime()
        web.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshotMs = self.average(self.snapshotMs, (CACurrentMediaTime() - started) * 1000)
                guard self.ended == nil, let picture = image.flatMap(TabShareCapture.bitmap) else {
                    self.inFlight = false
                    self.failures += 1
                    return
                }
                self.pageScale = max(0.25, CGFloat(picture.width) / CGFloat(points))
                self.snapshots += 1
                self.encode(picture)
            }
        }
    }

    /// The scale the page paints its pictures at, once one has come back.
    private var pageScale: CGFloat?

    /// The picture WebKit made, as it made it. NSImage's own
    /// `cgImage(forProposedRect:)` decides for itself what size and colours
    /// the main screen would want and draws a new picture to match — a
    /// fifth of a core at 30 a second, for nothing. The representation
    /// hands back the one WebKit made.
    nonisolated static func bitmap(_ image: NSImage) -> CGImage? {
        if let rep = image.representations.first, let picture = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return picture
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func encode(_ picture: CGImage) {
        let previous = lastPicture
        Self.encoder.async { [weak self] in
            let started = CACurrentMediaTime()
            let data = TabShareCapture.jpeg(picture)
            let took = (CACurrentMediaTime() - started) * 1000
            let changed = data != previous
            let text = changed ? data?.base64EncodedString() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.encoded(data, text: text, changed: changed, took: took, width: picture.width, height: picture.height) }
            }
        }
    }

    private func encoded(_ data: Data?, text: String?, changed: Bool, took: Double, width: Int, height: Int) {
        inFlight = false
        encodeMs = average(encodeMs, took)
        guard ended == nil, let data else { return }
        let now = CACurrentMediaTime()
        guard TabShareRules.publishes(changed: changed, sinceLast: now - lastPublish) else { return }
        lastPicture = data
        lastPublish = now
        seq += 1
        published += 1
        bytes = data.count
        window.append(now)
        window.removeAll { now - $0 > 2 }
        // No title rides along: the track's label is the tab's title as it
        // was when you chose it, as a track's label never changes — the
        // page is not told the title of every page you then open in the tab.
        if let text {
            latest = ["seq": seq, "data": text, "width": width, "height": height]
        } else {
            latest?["seq"] = seq
        }
        let ready = waiting
        waiting = []
        for each in ready {
            if let latest, seq > each.after {
                served += 1
                waits.add((now - each.at) * 1000)
                lastServed = now
                each.reply(latest)
            } else {
                waiting.append(each)
            }
        }
    }

    /// The page's long poll: the newest picture after `after`, at once if
    /// there is one, else as soon as there is.
    func next(after: Int, reply: Reply) {
        lastAsked = Date()
        asked += 1
        let now = CACurrentMediaTime()
        if lastServed > 0 { turns.add((now - lastServed) * 1000); lastServed = 0 }
        if let ended {
            reply(["ended": true, "reason": ended])
            return
        }
        if let latest, seq > after {
            served += 1
            waits.add(0)
            lastServed = now
            reply(latest)
            return
        }
        // A page asking over and over without waiting for its answers would
        // pile up replies, and every picture would go out once per ask. The
        // oldest are told "nothing new" (seq 0), which the page's script
        // reads as "ask again".
        while waiting.count >= TabShareRules.maxWaiting {
            waiting.removeFirst().reply(["seq": 0])
        }
        waiting.append((after, reply, now))
    }

    /// Over: every page waiting hears it, and no more pictures are taken.
    func stop(_ reason: String) {
        guard ended == nil else { return }
        ended = reason
        timer?.invalidate()
        timer = nil
        latest = nil
        lastPicture = nil
        let ready = waiting
        waiting = []
        for each in ready { each.reply(["ended": true, "reason": reason]) }
    }

    /// Pictures published in the last two seconds, per second.
    var rate: Double {
        let now = CACurrentMediaTime()
        let recent = window.filter { now - $0 <= 2 }
        return Double(recent.count) / 2
    }

    private func average(_ old: Double, _ new: Double) -> Double { old == 0 ? new : old * 0.9 + new * 0.1 }

    /// JPEG at 0.7: a 1280×720 page is about 50 KB, a picture the page's own
    /// image decoder turns back into pixels in two or three milliseconds.
    nonisolated static func jpeg(_ picture: CGImage, quality: Double = 0.7) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    var report: [String: Any] {
        ["seq": seq, "snapshots": snapshots, "published": published, "served": served, "failures": failures,
         "fps": fps, "rate": rate, "width": size.width, "height": size.height, "snapshotMs": (snapshotMs * 100).rounded() / 100,
         "encodeMs": (encodeMs * 100).rounded() / 100, "jpegBytes": bytes, "waiting": waiting.count, "asked": asked, "idleTicks": idleTicks,
         "lastAskedAgo": (Date().timeIntervalSince(lastAsked) * 100).rounded() / 100, "ended": ended ?? NSNull(),
         "timing": ["tickMs": tickGaps.report, "waitMs": waits.report, "pageMs": turns.report]]
    }
}
