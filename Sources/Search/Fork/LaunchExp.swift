import AppKit
import WebKit

// EXPERIMENT ONLY (perf/launch-exp): strategies picked by the app bundle's name.
@MainActor
enum LaunchExp {
    static let name = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    static var asked = false

    static func atInit() {
        guard name.contains("Warm") else { return }
        let pool = WKWebViewConfiguration().processPool
        let warm = NSSelectorFromString("_warmInitialProcess")
        if pool.responds(to: warm) { pool.perform(warm); Pace.mark("t.warm") }
    }

    static func atDidFinish() {
        if name.hasSuffix("Drain") {
            spin(max: 0)
        } else if name.hasSuffix("Spin") {
            spin(max: 0)
        } else if name.hasSuffix("Wait") {
            spin(max: 0.25)
        }
    }

    /// Services whatever is ready; with max > 0, keeps the run loop going until
    /// the first page's policy has been asked or max seconds.
    static func spin(max: Double) {
        Pace.mark("t.spin")
        let until = Date().addingTimeInterval(max)
        var n = 0
        repeat {
            let r = CFRunLoopRunInMode(.defaultMode, max > 0 ? 0.002 : 0, true)
            n += 1
            if max == 0, r != .handledSource || n > 50 { break }
        } while max > 0 && !asked && Date() < until
        Pace.mark("t.spun")
    }
}
