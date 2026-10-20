import AppKit
import Darwin
import QuartzCore

// Where the time goes: the launch, and the main thread while it works.
//
// Two instruments, both cheap enough to leave on in every build:
//
// - Milestones since the process started (the kernel's start time, so the
//   dyld and SwiftUI start-up before our first line counts too): `init`,
//   `window`, `bench`, and the first page's `page.ask`, `page.commit`,
//   `page.paint` and `page.finish`. Each is kept once, the first time.
//
// - A run-loop observer on the main thread that times every pass from waking
//   to sleeping again. Busy time and the longest pass since the last reset
//   say what a space switch or a tab click cost; the passes over 16 ms in the
//   first 20 s say what the launch spent where.
//
// `./bench pace` reads both; `./bench pace reset` starts a new window.
@MainActor
enum Pace {
    /// When the kernel started this process, as a media time.
    private static let born: CFTimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let now = CACurrentMediaTime()
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return now }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return now - (Date().timeIntervalSince1970 - started)
    }()

    private static var marks: [(String, Double)] = []
    private static var observer: CFRunLoopObserver?
    private static var waking: CFTimeInterval = 0

    /// The window `bench pace` reports on.
    private static var since: CFTimeInterval = 0
    private static var busy: CFTimeInterval = 0
    private static var longest: CFTimeInterval = 0
    private static var passes = 0
    private static var slow: [(at: Double, ms: Double)] = []
    /// Passes over 16 ms in the launch's first 20 s.
    private static var launch: [(at: Double, ms: Double)] = []

    static func ms(_ time: CFTimeInterval) -> Double { ((time - born) * 10000).rounded() / 10 }

    /// The first line of the app: the clock is read and the watch goes on.
    static func start() {
        _ = born
        mark("init")
        guard observer == nil else { return }
        since = CACurrentMediaTime()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let watch = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                waking = now
            } else if waking > 0 {
                pass(from: waking, to: now)
                waking = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), watch, .commonModes)
        observer = watch
        // Until the first sleep, the launch is one long pass.
        waking = born
        // EXP: the first run-loop iteration's start and its first beforeWaiting.
        let first = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeTimers.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, -1_000_000) { _, activity in
            mark(activity == .beforeTimers ? "t.loop" : "t.wait")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), first, .commonModes)
    }

    private static func pass(from start: CFTimeInterval, to end: CFTimeInterval) {
        let length = end - start
        if start >= since {
            busy += length
            passes += 1
            longest = max(longest, length)
            if length > 0.016, slow.count < 200 { slow.append((((start - since) * 10000).rounded() / 10, (length * 10000).rounded() / 10)) }
        }
        if length > 0.016, end - born < 20, launch.count < 200 {
            launch.append((ms(start), (length * 10000).rounded() / 10))
        }
    }

    /// A milestone, kept the first time it is reached.
    static func mark(_ name: String) {
        guard !marks.contains(where: { $0.0 == name }) else { return }
        marks.append((name, ms(CACurrentMediaTime())))
    }

    /// The first page this process shows (never a bench tab's).
    static func page(_ step: String, bench: Bool) {
        guard !bench else { return }
        mark("page." + step)
    }

    static func bench(_ request: [String: Any]) -> [String: Any] {
        if request["op"] as? String == "reset" {
            since = CACurrentMediaTime()
            busy = 0
            longest = 0
            passes = 0
            slow = []
            return ["reset": true]
        }
        let now = CACurrentMediaTime()
        return [
            "marks": Dictionary(marks.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a }),
            "order": marks.map(\.0),
            "window": ((now - since) * 10000).rounded() / 10,
            "busy": (busy * 10000).rounded() / 10,
            "longest": (longest * 10000).rounded() / 10,
            "passes": passes,
            "slow": slow.map { [$0.at, $0.ms] },
            "launchSlow": launch.map { [$0.at, $0.ms] },
            "launchBusy": (launch.reduce(0) { $0 + $1.ms } * 10).rounded() / 10,
            "uptime": ms(now),
        ]
    }
}
