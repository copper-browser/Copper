import AppKit
import SwiftUI

// `bench settings perf …`: what the Settings panel costs the main thread.
//
// Two meters, both off until the bench asks:
//  - body evaluations, counted by name (`let _ = SettingsPerf.tick("line")`
//    at the top of a `body`), so a regression that redraws every row on every
//    keystroke or every published tick shows up as a number rather than as
//    "it feels laggy";
//  - main-thread busy time, from two run-loop observers — waking first of
//    all, going back to sleep last of all, after Core Animation's commit
//    (SwiftUI's update, layout and display run in it) — so the sum over a
//    window is what the thread spent and the longest stretch is the worst
//    hitch.
//
// Verbs (see the bench script's help):
//   perf [reset|stop]   the meters since the last reset (reset starts them)
//   perf run            open, every page, a typed query, a scroll, idle
//   perf switch [N]     every page N times, each change pushed through update,
//                       layout and display at once and timed: page latency
//   perf churn SOURCE [N]  an object the panel watches says it changed, timed
//   perf scroll         a two-finger scroll down the open page and back
//   perf layers         the window's view and layer counts
//
// A parked (headless) window is never composited by the window server, so
// these are main-thread numbers; the GPU half of a frame is not measured.

@MainActor
enum SettingsPerf {
    /// Counting on: set by the bench only, so a person's Copper pays one
    /// branch per body.
    private(set) static var on = false
    private(set) static var counts: [String: Int] = [:]

    @inline(__always)
    static func tick(_ name: String) {
        if on { counts[name, default: 0] += 1 }
    }

    // MARK: the meters

    private static var observers: [CFRunLoopObserver] = []
    private static var woke: CFAbsoluteTime = 0
    private static var busy: Double = 0
    private static var stretches = 0
    private static var longest: Double = 0
    private static var since: CFAbsoluteTime = 0
    private static var cpuSince: Double = 0

    static func start() {
        on = true
        reset()
        guard observers.isEmpty else { return }
        let first = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            woke = CFAbsoluteTimeGetCurrent()
        }
        let last = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard woke > 0 else { return }
            let spent = CFAbsoluteTimeGetCurrent() - woke
            busy += spent
            stretches += 1
            longest = max(longest, spent)
            woke = 0
        }
        for made in [first, last].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
            observers.append(made)
        }
    }

    static func stop() {
        on = false
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
    }

    static func reset() {
        counts = [:]
        busy = 0
        stretches = 0
        longest = 0
        woke = 0
        since = CFAbsoluteTimeGetCurrent()
        cpuSince = processCPU()
    }

    /// User + system CPU of the whole process, in seconds.
    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func ms(_ seconds: Double) -> Double { (seconds * 10_000).rounded() / 10 }
    private static func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func report() -> [String: Any] {
        let elapsed = CFAbsoluteTimeGetCurrent() - since
        let cpu = processCPU() - cpuSince
        return [
            "elapsedMs": ms(elapsed),
            "mainBusyMs": ms(busy),
            "mainBusyPct": elapsed > 0 ? tenth(busy / elapsed * 100) : 0,
            "longestMs": ms(longest),
            "wakes": stretches,
            "cpuMs": ms(cpu),
            "cpuPct": elapsed > 0 ? tenth(cpu / elapsed * 100) : 0,
            "bodies": counts,
            "bodiesTotal": counts.values.reduce(0, +),
        ]
    }

    // MARK: the bench

    /// Objects the panel (or a card in it) watches, for `churn`. Settings search's
    /// finder and 1Password are added by `SettingsBench`.
    static var publishers: [String: (Browser) -> () -> Void] = [
        "browser": { b in { b.objectWillChange.send() } },
        "prefs": { b in { b.prefs.objectWillChange.send() } },
        "bitwarden": { _ in { Bitwarden.shared.objectWillChange.send() } },
        "updater": { _ in { Updater.shared.objectWillChange.send() } },
        "shield": { _ in { Shield.shared.objectWillChange.send() } },
    ]

    /// `type` and `clear` drive search (a query typed a letter at a time).
    static func handle(_ arg: String, in browser: Browser, type: ((String) -> Void)? = nil, clear: (() -> Void)? = nil,
                       answer: @escaping ([String: Any]) -> Void) {
        let words = arg.split(separator: " ").map(String.init)
        switch words.first ?? "" {
        case "reset", "start":
            start()
            answer(["counting": true])
        case "stop":
            let out = report()
            stop()
            answer(out)
        case "run":
            start()
            run(in: browser, type: type, clear: clear) { out in
                stop()
                answer(out)
            }
        case "switch":
            start()
            switchPages(words.count > 1 ? max(1, Int(words[1]) ?? 3) : 3, in: browser) { out in
                stop()
                answer(out)
            }
        case "churn":
            start()
            let source = words.count > 1 ? words[1] : "browser"
            let n = words.count > 2 ? max(1, Int(words[2]) ?? 20) : 20
            let out = churn(source, n, in: browser)
            stop()
            answer(out)
        case "scroll":
            start()
            scroll { moved in
                var out = report()
                out["scrolledPx"] = moved
                stop()
                answer(out)
            }
        case "layers":
            answer(layers())
        default:
            if observers.isEmpty { start() }
            answer(report())
        }
    }

    /// Runs `step`, waits `settle` seconds, and hands over the meters for
    /// that window.
    private static func measure(_ settle: Double, _ step: () -> Void, then: @escaping ([String: Any]) -> Void) {
        reset()
        step()
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { MainActor.assumeIsolated { then(report()) } }
    }

    private static func summary(_ r: [String: Any]) -> [String: Any] {
        ["busyMs": r["mainBusyMs"] ?? 0, "longestMs": r["longestMs"] ?? 0, "cpuMs": r["cpuMs"] ?? 0, "bodies": r["bodiesTotal"] ?? 0]
    }

    private static func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    /// The scripted session: open on General, sit, every page, type a
    /// query, scroll Passwords, sit on Passwords. Each step's numbers are its
    /// own window of the run loop, so a quiet page reads near the idle floor.
    private static func run(in browser: Browser, type: ((String) -> Void)?, clear: (() -> Void)?,
                            answer: @escaping ([String: Any]) -> Void) {
        let pages = SettingsPanel.Page.allCases
        var out: [String: Any] = [:]
        browser.tuning = false
        clear?()
        browser.settingsPage = .general

        func idle(_ key: String, _ next: @escaping @MainActor () -> Void) {
            measure(3.0, {}) { r in
                out[key] = ["busyMs": r["mainBusyMs"] ?? 0, "cpuPct": r["cpuPct"] ?? 0, "bodies": r["bodiesTotal"] ?? 0]
                next()
            }
        }

        func switching(_ i: Int, _ rows: [[String: Any]], _ next: @escaping @MainActor () -> Void) {
            guard i < pages.count else {
                out["pages"] = rows
                let busy = rows.compactMap { $0["busyMs"] as? Double }
                out["pageSwitchMeanBusyMs"] = busy.isEmpty ? 0 : tenth(busy.reduce(0, +) / Double(busy.count))
                out["pageSwitchLongestMs"] = rows.compactMap { $0["longestMs"] as? Double }.max() ?? 0
                return next()
            }
            let page = pages[i]
            measure(0.6, { browser.settingsPage = page }) { r in
                var row = summary(r)
                row["page"] = page.rawValue
                switching(i + 1, rows + [row], next)
            }
        }

        func typing(_ i: Int, _ rows: [[String: Any]], _ next: @escaping @MainActor () -> Void) {
            let letters = Array("password")
            guard let type, i < letters.count else {
                if !rows.isEmpty {
                    let busy = rows.compactMap { $0["busyMs"] as? Double }
                    out["typing"] = ["perKeyBusyMs": busy, "meanBusyMs": tenth(busy.reduce(0, +) / Double(max(1, busy.count))),
                                     "perKeyBodies": rows.compactMap { $0["bodies"] }]
                }
                clear?()
                return later(0.4, next)
            }
            measure(0.25, { type(String(letters[i])) }) { r in typing(i + 1, rows + [summary(r)], next) }
        }

        func scrolling(_ next: @escaping @MainActor () -> Void) {
            browser.settingsPage = .passwords
            later(0.6) {
                reset()
                scroll { moved in
                    let r = report()
                    out["scrollPasswords"] = ["busyMs": r["mainBusyMs"] ?? 0, "longestMs": r["longestMs"] ?? 0,
                                              "bodies": r["bodiesTotal"] ?? 0, "scrolledPx": moved]
                    next()
                }
            }
        }

        later(0.5) {
            measure(0.8, { browser.tuning = true }) { r in
                out["open"] = summary(r)
                idle("idleOpen3s") {
                    switching(0, []) {
                        typing(0, []) {
                            scrolling {
                                idle("idlePasswords3s") { answer(out) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Pushes whatever changed through SwiftUI's update, layout and display now.
    private static func flushFrame(_ window: NSWindow) {
        CATransaction.flush()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Opens Settings from closed, then every page in turn, ROUNDS times;
    /// each change is pushed through to the screen at once and timed.
    private static func switchPages(_ rounds: Int, in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard let window = Links.window else { return answer(["error": "no window"]) }
        let pages = SettingsPanel.Page.allCases
        var times: [String: [Double]] = [:]
        var bodies: [String: Int] = [:]
        var opens: [Double] = []

        func finish() {
            var rows: [String: Any] = [:]
            var all: [Double] = []
            var mins = 0.0
            for (page, list) in times {
                let sorted = list.sorted()
                rows[page] = ["medianMs": tenth(sorted[sorted.count / 2]),
                              "minMs": tenth(sorted[0]), "bodies": (bodies[page] ?? 0) / rounds]
                all += list
                mins += sorted[0]
            }
            let sorted = all.sorted()
            let opened = opens.sorted()
            answer(["pages": rows, "medianMs": tenth(sorted[sorted.count / 2]), "meanMs": tenth(all.reduce(0, +) / Double(all.count)),
                    "maxMs": tenth(sorted.last ?? 0), "sumOfMinsMs": tenth(mins),
                    "openMedianMs": opened.isEmpty ? 0 : tenth(opened[opened.count / 2])])
        }

        func page(_ r: Int, _ i: Int) {
            guard i < pages.count else { return round(r + 1) }
            counts = [:]
            let started = CFAbsoluteTimeGetCurrent()
            browser.settingsPage = pages[i]
            flushFrame(window)
            times[pages[i].rawValue, default: []].append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            bodies[pages[i].rawValue, default: 0] += counts.values.reduce(0, +)
            // Let the run loop breathe: onAppear tasks, preferences.
            later(0.25) { page(r, i + 1) }
        }

        func round(_ r: Int) {
            guard r < rounds else { return finish() }
            browser.tuning = false
            browser.settingsPage = .general
            flushFrame(window)
            later(0.4) {
                let started = CFAbsoluteTimeGetCurrent()
                browser.tuning = true
                flushFrame(window)
                opens.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                later(0.5) { page(r, 0) }
            }
        }
        round(0)
    }

    /// Someone the panel watches says it changed, N times; each time the
    /// window is updated, laid out and drawn at once, timed.
    private static func churn(_ source: String, _ n: Int, in browser: Browser) -> [String: Any] {
        guard let make = publishers[source] else {
            return ["error": "churn \(publishers.keys.sorted().joined(separator: "|")) [N]"]
        }
        guard let window = Links.window else { return ["error": "no window"] }
        let send = make(browser)
        var times: [Double] = []
        var bodies: [String: Int] = [:]
        flushFrame(window)
        for _ in 0..<n {
            counts = [:]
            let started = CFAbsoluteTimeGetCurrent()
            send()
            flushFrame(window)
            times.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            for (k, v) in counts { bodies[k, default: 0] += v }
        }
        let sorted = times.sorted()
        return [
            "source": source, "n": n, "page": browser.settingsPage.rawValue, "open": browser.tuning,
            "medianMs": tenth(sorted[sorted.count / 2]), "maxMs": tenth(sorted.last ?? 0),
            "bodiesPerChange": bodies.mapValues { $0 / n }, "bodiesPerChangeTotal": bodies.values.reduce(0, +) / n,
        ]
    }

    /// How many views and layers the window holds: what AppKit walks on
    /// every display cycle, whatever changed.
    private static func layers() -> [String: Any] {
        guard let root = Links.window?.contentView else { return ["error": "no window"] }
        var views = 0
        var layers = 0
        func walk(_ view: NSView) {
            views += 1
            for sub in view.subviews { walk(sub) }
        }
        func walk(_ layer: CALayer) {
            layers += 1
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        walk(root)
        if let layer = root.layer { walk(layer) }
        return ["views": views, "layers": layers]
    }

    // MARK: a scroll, synthesised

    /// The open page's scroll view: the widest in the window whose content
    /// is taller than it.
    private static func pageScroller(_ window: NSWindow?) -> NSScrollView? {
        guard let root = window?.contentView else { return nil }
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let doc = scroll.documentView,
               doc.frame.height > scroll.contentView.bounds.height + 40,
               scroll.frame.width > (best?.frame.width ?? 300) {
                best = scroll
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return best
    }

    /// Down the page 840 pt and back, 14 pt every 8 ms, as a trackpad sends
    /// it. A parked window's scroll view does not take a made wheel event,
    /// so the clip view is moved the way the wheel would move it.
    private static func scroll(done: @escaping (Double) -> Void) {
        guard let scroller = pageScroller(Links.window) else { return done(-1) }
        let start = scroller.contentView.bounds.origin.y
        let steps: [CGFloat] = Array(repeating: 14, count: 60) + Array(repeating: -14, count: 60)
        var furthest: CGFloat = 0
        func tick(_ i: Int) {
            guard i < steps.count else { return done(furthest.rounded()) }
            let clip = scroller.contentView
            let most = max(0, (scroller.documentView?.frame.height ?? 0) - clip.bounds.height)
            let y = min(most, max(0, clip.bounds.origin.y + steps[i]))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroller.reflectScrolledClipView(clip)
            furthest = max(furthest, abs(clip.bounds.origin.y - start))
            later(0.008) { tick(i + 1) }
        }
        tick(0)
    }
}
