import AppKit
import SwiftUI

// Two fingers sideways over the column of tabs: the next space, or the last.
//
// The page has a sideways swipe of its own (Swipe.swift, back and forward),
// so this one lives only over the sidebar. A local monitor sees every wheel
// event before the list does; once a gesture has committed to sideways it is
// ours until the fingers lift — and its momentum after, so the list never
// jiggles — and up-and-down is left alone entirely.
//
// Arc's swipe is a hand on the column, not a trigger: the column follows the
// fingers point for point with the next space coming in beside it
// (SpaceSlide.drag), and letting go either carries on — past about two
// fifths of the way, or on a flick — or springs back (SpaceSlide.release).
// Which way the column goes for which way the fingers go is Settings › Tabs
// › Swipe between spaces (`SwipeDirection`): with the fingers (Natural),
// against them (Inverted, the way a page turns the other way), or — the
// default — whichever of the two the Mac's own Natural scrolling setting
// says. The choice is applied once, here, to the fingers' travel and speed,
// so everything downstream — the slide, the springs, the rubber band at the
// first and last space, the Reduce Motion trigger — follows it without
// knowing. Reduce Motion keeps the old trigger: 70 points sideways and the
// space changes, with the crossfade and no travel. Three-finger swipes (when
// System Settings hands them to apps) are a trigger too; they come whole.

/// Which way a two-finger swipe over the column moves it.
enum SwipeDirection: String, CaseIterable, Identifiable {
    /// Natural when the Mac's Natural scrolling is on, Inverted when it is off.
    case system
    /// The column follows the fingers: fingers to the left bring in the next space.
    case natural
    /// The column moves against the fingers: fingers to the left bring in the last one.
    case inverted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Like scrolling"
        case .natural: return "Natural"
        case .inverted: return "Inverted"
        }
    }

    /// +1 when the column moves with the fingers, -1 against them.
    var sign: CGFloat {
        switch self {
        case .natural: return 1
        case .inverted: return -1
        case .system: return SwipeDirection.systemNatural ? 1 : -1
        }
    }

    /// System Settings › Trackpad › Natural scrolling, which the Mac keeps
    /// in the global domain; on unless someone turned it off.
    static var systemNatural: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }
}
@MainActor enum SpaceSwipe {
    /// Points of sideways travel before a Reduce Motion swipe changes space.
    nonisolated static let threshold: CGFloat = 70

    /// One gesture, from fingers down to fingers up: which axis it committed
    /// to, how far the fingers have come sideways, and the last few samples
    /// for their speed at the lift. Pure, so the bench can drive it without a
    /// trackpad and the real events and the bench go through the same code.
    struct Track {
        enum Axis { case undecided, sideways, upright }
        enum Say: Equatable {
            case nothing
            /// Fingers have gone `travel` points sideways (negative: left).
            case move(CGFloat)
            /// Fingers up, at `velocity` points a second.
            case release(velocity: CGFloat)
            case cancel
        }
        var axis = Axis.undecided
        var travel: CGFloat = 0
        /// The momentum after a sideways gesture is still ours, until it ends
        /// or new fingers come down.
        var coasting = false
        private var early = CGPoint.zero
        private var samples: [(time: Double, travel: CGFloat)] = []

        /// Feed one wheel event. `inverted` is the event's own
        /// `isDirectionInvertedFromDevice` (natural scrolling): with it the
        /// deltas already run the fingers' way, without it the other.
        mutating func feed(phase: NSEvent.Phase, momentum: NSEvent.Phase, dx: CGFloat, dy: CGFloat,
                           inverted: Bool, time: Double) -> (say: Say, swallow: Bool) {
            if momentum != [] {
                let ours = coasting
                if momentum.contains(.ended) || momentum.contains(.cancelled) { coasting = false }
                return (.nothing, ours)
            }
            switch phase {
            case .mayBegin, .began:
                self = Track()
                return (.nothing, false)
            case .changed:
                // Slow fingers come a point or two an event, so the axis is
                // decided on the movement so far, not on any one event, and
                // the points it took to decide count towards the travel.
                if axis == .undecided {
                    early.x += dx
                    early.y += dy
                    guard abs(early.x) + abs(early.y) > 3 else { return (.nothing, false) }
                    axis = abs(early.x) > abs(early.y) ? .sideways : .upright
                    guard axis == .sideways else { return (.nothing, false) }
                    travel = inverted ? early.x : -early.x
                } else {
                    guard axis == .sideways else { return (.nothing, false) }
                    travel += inverted ? dx : -dx
                }
                samples.append((time, travel))
                samples.removeAll { time - $0.time > 0.1 }
                return (.move(travel), true)
            case .ended, .cancelled:
                let ours = axis == .sideways
                let say: Say = !ours ? .nothing
                    : phase == .cancelled ? .cancel : .release(velocity: speed(at: time))
                self = Track()
                coasting = ours
                return (say, ours)
            default:
                return (.nothing, axis == .sideways)
            }
        }

        /// Points a second over the last tenth of a second of samples; nought
        /// if the fingers had already stopped.
        private func speed(at time: Double) -> CGFloat {
            let recent = samples.filter { time - $0.time <= 0.1 }
            guard let first = recent.first, let last = recent.last, last.time - first.time > 0.012 else { return 0 }
            return (last.travel - first.travel) / CGFloat(last.time - first.time)
        }
    }

    private static var track = Track()
    /// A Reduce Motion gesture that has already changed space.
    private static var fired = false
    private static var monitor: Any?
    /// Where the fingers came down: a gesture is the column's only if it
    /// started over the column. One that started on the page — a canvas's
    /// pan, a map — stays the page's wherever the pointer ends up, so the
    /// column never starts sliding out of the middle of somebody's pan.
    private static var startedOverSidebar = false
    /// Gestures this monitor turned down because they started on the page,
    /// for the bench (`canvas scroll --app` checks a board's pan is one).
    private(set) static var leftToPage = 0

    static func watch(_ browser: Browser) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { event in
            MainActor.assumeIsolated { handle(event, in: browser) }
        }
    }

    /// The window a gesture began on. Every event of it, and its momentum,
    /// goes to that window's column, wherever the pointer wanders — and only
    /// that column moves. (Fork: windows)
    private static weak var gripped: Browser?

    private static func handle(_ event: NSEvent, in _: Browser) -> NSEvent? {
        // Each browser window's column switches that window's space; a
        // panel's or a sheet's events are not ours. (Fork: windows)
        guard let window = event.window, let owner = Windows.owner(of: window) else { return event }
        // Where a trackpad gesture began decides whose it is: one that began
        // on the page — a board's two-finger pan above all — is never the
        // column's, wherever the fingers then wander. (Fork: canvas)
        if event.type == .scrollWheel, event.momentumPhase == [], event.phase == .began || event.phase == .mayBegin {
            startedOverSidebar = overSidebar(event.locationInWindow, in: owner)
            if !startedOverSidebar, event.phase == .began { leftToPage += 1 }
        }
        // Once a gesture is ours it stays ours, in the window it began in.
        let going = track.axis == .sideways || track.coasting
        let browser = going ? (gripped ?? owner) : owner
        guard going || (event.type == .swipe || startedOverSidebar) && overSidebar(event.locationInWindow, in: owner) else { return event }
        if event.type == .swipe {
            guard event.deltaX != 0 else { return event }
            go(event.deltaX * browser.prefs.swipeDirection.sign < 0 ? 1 : -1, in: browser)
            return nil
        }
        // A wheel with no phase is a mouse wheel; those scroll.
        guard event.phase != [] || event.momentumPhase != [] else { return event }
        if !going { gripped = owner }
        let swallow = apply(phase: event.phase, momentum: event.momentumPhase,
                            dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                            inverted: event.isDirectionInvertedFromDevice, time: event.timestamp, in: browser)
        return swallow ? nil : event
    }

    /// One event, real or scripted, through the track and on to the slide.
    @discardableResult
    private static func apply(phase: NSEvent.Phase, momentum: NSEvent.Phase, dx: CGFloat, dy: CGFloat,
                              inverted: Bool, time: Double, in browser: Browser) -> Bool {
        var (say, swallow) = track.feed(phase: phase, momentum: momentum, dx: dx, dy: dy, inverted: inverted, time: time)
        // The fingers' way becomes the column's way here, and only here.
        let sign = browser.prefs.swipeDirection.sign
        switch say {
        case .move(let travel): say = .move(travel * sign)
        case .release(let velocity): say = .release(velocity: velocity * sign)
        default: break
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch say {
        case .nothing: break
        case .move(let travel):
            if still {
                if !fired, abs(travel) > threshold {
                    fired = true
                    clamped(travel < 0 ? 1 : -1, in: browser)
                }
            } else {
                SpaceSlide.shared.drag(travel, in: browser)
            }
        case .release(let velocity):
            fired = false
            SpaceSlide.shared.release(velocity: velocity, cancelled: false, in: browser)
        case .cancel:
            fired = false
            SpaceSlide.shared.release(velocity: 0, cancelled: true, in: browser)
        }
        return swallow
    }

    // MARK: - the bench

    private static var scripted: Timer?
    private static var held = false
    private static var ticks: [CFTimeInterval] = []

    /// `spaces swipe DX,DX,…[ end|cancel] [--hold] [--window N]`: a two-finger
    /// gesture as the trackpad would send it — fingers down, one `changed` per
    /// DX (in points the fingers move, negative to the left) every 1/120 s,
    /// then the lift (`end`, the default), a cancel, or with `--hold` nothing:
    /// the fingers stay down for a picture, and the next `spaces swipe`
    /// carries on from there (`spaces swipe end` alone lets go). Answers at
    /// once; the events play out over the next DX × 8 ms — `spaces slide`
    /// says where it got to. Reduce Motion is the system's, as for real
    /// fingers. `--shot PATH@MS` (any number) pictures the window MS
    /// milliseconds after the last event, from inside the app, so a frame of
    /// the settle can be caught without a round trip through the shell.
    /// `--window N` puts the fingers on that browser window's column (as
    /// `windows` lists them) rather than the first's. (Fork: windows)
    static func script(_ arg: String, in browser: Browser) -> [String: Any] {
        var words = arg.split(separator: " ").map(String.init)
        var browser = browser
        if let at = words.firstIndex(of: "--window"), at + 1 < words.count, let n = Int(words[at + 1]) {
            guard Windows.all.indices.contains(n) else { return ["error": "no window \(n)"] }
            browser = Windows.all[n]
            words.removeSubrange(at...(at + 1))
        }
        if words.first == "direction" {
            // `spaces swipe direction [system|natural|inverted]`: the setting,
            // as Settings › Tabs sets it.
            if words.count > 1 {
                guard let way = SwipeDirection(rawValue: words[1]) else { return ["error": "spaces swipe direction system|natural|inverted"] }
                browser.prefs.swipeDirection = way
            }
            return ["direction": browser.prefs.swipeDirection.rawValue, "sign": Double(browser.prefs.swipeDirection.sign),
                    "systemNatural": SwipeDirection.systemNatural]
        }
        if words.first == "stats" {
            // How evenly the scripted events got through: each is due 8.3 ms
            // after the last, so a longer gap is the main thread busy
            // drawing — the closest thing to dropped frames a covered window
            // (whose display link is stopped) can report.
            let gaps = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
            let sorted = gaps.sorted()
            return ["events": ticks.count, "longest": ((sorted.last ?? 0) * 10).rounded() / 10,
                    "median": ((sorted.isEmpty ? 0 : sorted[sorted.count / 2]) * 10).rounded() / 10,
                    "over12": gaps.filter { $0 > 12 }.count, "over17": gaps.filter { $0 > 17 }.count]
        }
        ticks = []
        var shots: [(String, Double)] = []
        for (i, word) in words.enumerated() where word == "--shot" && i + 1 < words.count {
            let parts = words[i + 1].split(separator: "@").map(String.init)
            if parts.count == 2, let ms = Double(parts[1]) { shots.append((parts[0], ms)) }
        }
        // The window forward, as for the bench's own pictures: one behind
        // another window is not drawing, and its display link is stopped.
        let window = Windows.window(of: browser)
        if let window {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        let hold = words.contains("--hold")
        let lift = words.contains("cancel") ? NSEvent.Phase.cancelled : hold ? [] : .ended
        let deltas = (words.first { $0.contains(",") || Double($0) != nil } ?? "")
            .split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
        scripted?.invalidate()
        var queue: [(NSEvent.Phase, CGFloat)] = []
        if !held { queue.append((.began, 0)) }
        queue += deltas.map { (.changed, $0) }
        if lift != [] { queue.append((lift, 0)) }
        held = lift == []
        let count = queue.count
        // The scripted fingers are on this window, as real ones would be.
        gripped = browser
        scripted = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !queue.isEmpty else {
                    timer.invalidate()
                    for (path, ms) in shots {
                        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { picture(of: window, to: path) }
                    }
                    return
                }
                let (phase, dx) = queue.removeFirst()
                ticks.append(CACurrentMediaTime())
                apply(phase: phase, momentum: [], dx: dx, dy: 0, inverted: true, time: CACurrentMediaTime(), in: browser)
            }
        }
        return ["events": count, "milliseconds": Double(count) * 1000 / 120, "held": held,
                "travel": Double(deltas.reduce(0, +)), "space": Spaces.shared.space(in: browser).name,
                "window": Windows.all.firstIndex { $0 === browser } ?? -1]
    }

    /// The window's pixels are taken on the main thread (a few
    /// milliseconds); the PNG is made and written off it, so a dense run of
    /// shots does not itself stall the slide it is picturing.
    private static func picture(of window: NSWindow?, to path: String) {
        guard let window,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// `bench swipe left|right|down [--window N]`: a quick whole gesture,
    /// scripted. `down` must scroll, not switch.
    static func bench(_ arg: String, in browser: Browser) -> [String: Any] {
        var words = arg.split(separator: " ").map(String.init)
        var browser = browser
        if let at = words.firstIndex(of: "--window"), at + 1 < words.count, let n = Int(words[at + 1]) {
            guard Windows.all.indices.contains(n) else { return ["error": "no window \(n)"] }
            browser = Windows.all[n]
            words.removeSubrange(at...(at + 1))
        }
        let direction = words.first ?? "left"
        let dx = direction == "left" ? "-12" : direction == "right" ? "12" : "0"
        if direction == "down" {
            var probe = Track()
            _ = probe.feed(phase: .began, momentum: [], dx: 0, dy: 0, inverted: true, time: 0)
            let (_, swallow) = probe.feed(phase: .changed, momentum: [], dx: 0, dy: 12, inverted: true, time: 0.01)
            return ["swallowed": swallow ? 1 : 0, "space": Spaces.shared.space(in: browser).name]
        }
        return script(Array(repeating: dx, count: 10).joined(separator: ",") + " end", in: browser)
    }

    /// One space along, with the slide a click gives (Spaces.select →
    /// SpaceSlide.begin), wrapping at the ends as a three-finger swipe does.
    /// Mouse buttons (MouseButtons.swift) use this helper too, so the ways of
    /// stepping a space cannot drift into different motions.
    static func go(_ by: Int, in browser: Browser) {
        withAnimation(Motion.glide) { Spaces.shared.step(by, in: browser) }
    }

    /// One space along, stopping at the ends — a two-finger swipe does not
    /// wrap round.
    private static func clamped(_ by: Int, in browser: Browser) {
        let spaces = Spaces.shared
        guard let here = spaces.all.firstIndex(where: { $0.id == spaces.current(in: browser) }),
              spaces.all.indices.contains(here + by) else { return }
        spaces.select(index: here + by, in: browser)
    }

    /// Whether a point is over the column of tabs — down the left, shown, or
    /// briefly peeking out while folded (the same test Fold.swift uses to lay
    /// it out).
    static func overSidebar(_ location: CGPoint, in browser: Browser) -> Bool {
        guard browser.prefs.sidebar, browser.active?.immersed != true,
              !browser.folded || browser.peeking else { return false }
        // Fork (ardia layout): a right column, from the window's right edge in.
        if browser.prefs.sideRight, let width = Windows.window(of: browser)?.contentView?.bounds.width {
            return location.x >= width - browser.prefs.sideWidth
        }
        return location.x <= browser.prefs.sideWidth
    }
}
