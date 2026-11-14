import AppKit
import QuartzCore

// Measuring hooks for the bench (docs: `./bench help`): a title-bar
// double-click, a trackpad scroll replayed one event per display refresh, and
// a key press timed to the frame that shows it. Each is real input handed to
// AppKit, so the app's own handling runs as it would for a hand; each posts
// into a window, so only in a probe world (like `resize`), and each answers
// once it is done.
@MainActor
enum BenchHooks {
    static func handle(_ verb: String, _ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else {
            answer(["error": "\(verb) only works on a --test run — it posts input to your window"])
            return
        }
        // `mouse double` carries its words in `arg`, as `mouse` always has.
        let words = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
        let nth = request["window"] as? Int
            ?? words.firstIndex(of: "--window").flatMap { words.indices.contains($0 + 1) ? Int(words[$0 + 1]) : nil }
        var browser = browser
        if let nth {
            guard Windows.all.indices.contains(nth) else { answer(["error": "no window \(nth)"]); return }
            browser = Windows.all[nth]
        }
        guard let window = Windows.window(of: browser) ?? Links.window else { answer(["error": "no window"]); return }
        switch verb {
        case "wheel": wheel(request, browser: browser, window: window, answer: answer)
        case "keylat": keylat(request, browser: browser, window: window, answer: answer)
        default: double(words, window: window, answer: answer)
        }
    }

    // MARK: - mouse double X Y

    /// A left double-click at window point X Y (top-left origin). Posted to
    /// the app's queue rather than handed to a view, so it goes the whole way
    /// a click does (NSApp → window.sendEvent → whatever is under it, the
    /// title bar's own double-click included) and a view that tracks the
    /// mouse finds its mouse-up waiting.
    private static func double(_ words: [String], window: NSWindow, answer: @escaping ([String: Any]) -> Void) {
        guard words.count >= 3, let x = Double(words[1]), let y = Double(words[2]) else {
            answer(["error": "mouse double X Y [--window N]"])
            return
        }
        let at = NSPoint(x: x, y: window.frame.height - y)
        let before = window.frame
        // The frame view, title bar and all; its hit test takes window points.
        let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(at)
        let stamp = ProcessInfo.processInfo.systemUptime
        let clicks: [(NSEvent.EventType, Int)] = [(.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)]
        for (n, (type, count)) in clicks.enumerated() {
            guard let event = NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [], timestamp: stamp + Double(n) * 0.05,
                windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: count,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { answer(["error": "no event"]); return }
            NSApp.postEvent(event, atStart: false)
        }
        // A zoom animates for a fraction of a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            func box(_ r: NSRect) -> [Int] { [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }
            answer(["frameBefore": box(before), "frameAfter": box(window.frame), "zoomed": window.isZoomed,
                    "miniaturized": window.isMiniaturized, "hit": hit.map { "\(type(of: $0))" } ?? "",
                    "action": UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"])
        }
    }

    // MARK: - wheel DY

    /// A trackpad scroll of DY points (+ is down the page) in `steps` events,
    /// one per tick of the display link at `hz`: began, changed…, ended with
    /// no delta, the way a finger lifts. Answers how evenly the ticks came and
    /// what each event cost the main thread; the page's own frame times are
    /// the harness's (a rAF recorder in the page).
    private static func wheel(_ request: [String: Any], browser: Browser, window: NSWindow, answer: @escaping ([String: Any]) -> Void) {
        guard let dy = request["dy"] as? Double else { answer(["error": "wheel needs DY"]); return }
        // At most 600, so even at 30 Hz it is over before the bench's 25 s.
        let steps = min(600, max(2, request["steps"] as? Int ?? 60))
        let hz = max(1, request["hz"] as? Double ?? 120)
        let at: NSPoint
        if let xy = request["at"] as? [Double], xy.count == 2 {
            at = NSPoint(x: xy[0], y: window.frame.height - xy[1])
        } else if let web = browser.active?.web, web.window === window {
            at = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        } else {
            at = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        }
        // An event made from a CGEvent has no window: its locationInWindow is
        // its location flipped against the main display (as in MouseButtons).
        let top = CGDisplayBounds(CGMainDisplayID()).height
        var ticks: [Double] = []
        var sends: [Double] = []
        var sent = 0
        var period = 1 / hz
        let started = CACurrentMediaTime()
        // Screen's link, not the view's: a parked (headless) window is on no screen.
        guard let screen = window.screen ?? NSScreen.main else { answer(["error": "no screen"]); return }
        let ticker = Ticker { link in
            ticks.append(CACurrentMediaTime())
            period = link.targetTimestamp - link.timestamp
            let last = sent == steps - 1
            // Whole points that add up to DY over the events before the last.
            let share = last ? 0 : Int32((dy * Double(sent + 1) / Double(steps - 1)).rounded() - (dy * Double(sent) / Double(steps - 1)).rounded())
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -share, wheel2: 0, wheel3: 0) {
                cg.location = CGPoint(x: at.x, y: top - at.y)
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                // CGScrollPhase: began 1, changed 2, ended 4.
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: sent == 0 ? 1 : last ? 4 : 2)
                if let event = NSEvent(cgEvent: cg) {
                    let t = CACurrentMediaTime()
                    window.sendEvent(event)
                    sends.append((CACurrentMediaTime() - t) * 1000)
                }
            }
            sent += 1
            guard sent >= steps else { return }
            link.invalidate()
            let gaps = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
            let nominal = 1000 * max(period, 1 / hz)
            answer(["events": sent, "hz": Int((1000 / nominal).rounded()), "asked_hz": hz, "screen_hz": screen.maximumFramesPerSecond,
                    "tick_ms": spread(gaps), "missed_ticks": gaps.filter { $0 > nominal * 1.5 }.count,
                    "send_ms": spread(sends), "duration_ms": (CACurrentMediaTime() - started) * 1000,
                    "at": [Int(at.x), Int(window.frame.height - at.y)]])
        }
        let link = screen.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Swift.Float(hz), maximum: Swift.Float(hz), preferred: Swift.Float(hz))
        link.add(to: .main, forMode: .common)
        // A display that is asleep never ticks: say so, and never let the link
        // post a scroll long after the answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) / 30 + 1) {
            guard sent < steps else { return }
            link.invalidate()
            answer(["error": "the display link ticked \(ticks.count) of \(steps) times — is the display asleep?"])
        }
    }

    // MARK: - keylat KEY

    /// One key (⌘t, ⌘k, ⎋ or a letter) in at NSApp.sendEvent, as a press
    /// arrives, and three times from just before it: when sendEvent returned
    /// (handled), the end of the next Core Animation commit after that — a
    /// run-loop observer ordered after CA's own (commit), and the display
    /// link's next tick after the commit, the frame that can show it (frame).
    private static func keylat(_ request: [String: Any], browser: Browser, window: NSWindow, answer: @escaping ([String: Any]) -> Void) {
        let raw = request["key"] as? String ?? ""
        let command = raw.hasPrefix("\u{2318}")
        let name = command ? String(raw.dropFirst()) : raw
        guard name.count == 1, let character = name.first else { answer(["error": "keylat ⌘t|⌘k|⎋|LETTER"]); return }
        let escape = character == "\u{238B}"
        let chars = escape ? "\u{1B}" : name.lowercased()
        func key(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: command ? [.command] : [],
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: escape ? 53 : Bench.keyCode(for: character))
        }
        guard let down = key(.keyDown), let up = key(.keyUp), let screen = window.screen ?? NSScreen.main else {
            answer(["error": "no event"])
            return
        }
        // What a key here can change: the ⌘K bar, the ⌘T card, the field, its text, its highlight.
        let state = { "\(browser.summoning) \(browser.launching) \(browser.editing) \(browser.picked ?? -1) \(browser.typed)" }
        let was = state()
        var start = 0.0, handled = 0.0
        var commit: Double?
        var done = false
        // The link runs from before the press, so its first tick after the
        // commit comes no later than any other would.
        let ticker = Ticker { link in
            guard let commit, !done else { return }
            let frame = CACurrentMediaTime()
            done = true
            link.invalidate()
            NSApp.sendEvent(up)
            func ms(_ t: Double) -> Double { (t - start) * 1000 }
            answer(["key": raw, "handled_ms": ms(handled), "commit_ms": ms(commit), "frame_ms": ms(frame),
                    "changed": state() != was, "summoning": browser.summoning, "launching": browser.launching])
        }
        let link = screen.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        start = CACurrentMediaTime()
        NSApp.sendEvent(down)
        handled = CACurrentMediaTime()
        // CA commits in a before-waiting observer of its own (order 2,000,000);
        // one at the last order there is runs after it. Once, then gone.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            commit = CACurrentMediaTime()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !done else { return }
            done = true
            link.invalidate()
            NSApp.sendEvent(up)
            answer(["error": "no display-link tick within 2 s — is the display asleep?"])
        }
    }

    // MARK: - helpers

    /// p50, p90 and the worst of a list of milliseconds.
    static func spread(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["p50": 0, "p90": 0, "max": 0] }
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
        return ["p50": at(0.5), "p90": at(0.9), "max": sorted[sorted.count - 1]]
    }

    /// A display link's target: CADisplayLink wants an object and a selector.
    private final class Ticker: NSObject {
        let body: (CADisplayLink) -> Void
        init(_ body: @escaping (CADisplayLink) -> Void) { self.body = body }
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { body(link) } }
    }
}
