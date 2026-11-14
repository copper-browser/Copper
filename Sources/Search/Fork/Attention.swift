import AppKit

// Whether anybody is using Copper right now: a real input event (pointer,
// keys, scroll, gestures) in the last `window` seconds. Things that only move
// to look alive — the animated column — stand still when it lapses and pick
// up again on the next event.
//
// Why: an animated space drew 24 frames a second for as long as the window
// was up, touched or not, and every frame is a layer-tree commit on the main
// thread: ~19 wakes a second, ~1,130 main passes a minute at idle, against
// ~190 with Reduce Motion (hill-climb r4, A6).
//
// Cheap on purpose: the monitor only stamps the time, and one timer, set for
// when the window would lapse and re-set lazily from the last stamp, is all
// that runs — one wake per lapse, not per event, and none once idle.
enum Attention {
    static let window: TimeInterval = 30
    static let changed = Notification.Name("CopperAttentionChanged")
    private(set) static var awake = true
    private static var last = ProcessInfo.processInfo.systemUptime
    private static var monitor: Any?
    private static var timer: Timer?

    /// Starts watching (once); the first caller is whoever needs it first.
    static func start() {
        guard monitor == nil else { return }
        let input: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                            .keyDown, .flagsChanged, .scrollWheel, .magnify, .swipe, .rotate]
        monitor = NSEvent.addLocalMonitorForEvents(matching: input) { event in
            touch()
            return event
        }
        arm(after: window)
    }

    /// Someone did something: stamp it, and wake whatever stood still.
    static func touch() {
        last = ProcessInfo.processInfo.systemUptime
        guard !awake else { return }
        awake = true
        NotificationCenter.default.post(name: changed, object: nil)
        arm(after: window)
    }

    private static func arm(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            // Half a second's slack, so a timer that fires a hair early doesn't set another.
            let left = window - (ProcessInfo.processInfo.systemUptime - last)
            if left > 0.5 { return arm(after: left) }
            awake = false
            NotificationCenter.default.post(name: changed, object: nil)
        }
        timer?.tolerance = 2
    }
}
