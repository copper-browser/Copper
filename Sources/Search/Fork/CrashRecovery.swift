import Foundation

/// A one-off process death (memory pressure) should recover without a click.
/// A page that keeps killing its process must not turn that into a reload
/// loop. A successful load alone is not a reset: crashers often finish
/// loading immediately before they die.
struct CrashRecovery {
    private var deaths: [Date] = []
    private(set) var halted = false

    mutating func permitsRecovery(at now: Date = Date()) -> Bool {
        guard !halted else { return false }
        deaths = deaths.filter { now.timeIntervalSince($0) < 60 }
        deaths.append(now)
        halted = deaths.count >= 3
        return !halted
    }

    /// Explicit navigation starts a new visit. Manual Reload/Try again does
    /// not reset the budget: it grants one load, not another automatic loop.
    mutating func reset() {
        deaths = []
        halted = false
    }
}
