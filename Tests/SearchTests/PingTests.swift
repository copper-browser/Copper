import Foundation
import Testing
@testable import Search

// The anonymous daily ping's flags (Fork/Ping.swift): once a day, and w/m
// only on the first ping of an ISO week / calendar month, all in UTC.

@Suite("Daily ping")
struct PingTests {
    /// Noon UTC on that day, or `hour` o'clock.
    func at(_ day: String, _ hour: Int = 12) -> Date {
        let n = day.split(separator: "-").map { Int($0)! }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: n[0], month: n[1], day: n[2], hour: hour))!
    }

    @Test("First ping ever carries every flag")
    func first() {
        #expect(Ping.flags(now: at("2026-11-25"), last: nil) == ["d", "w", "m", "new"])
    }

    @Test("Nothing twice in one UTC day")
    func sameDay() {
        #expect(Ping.flags(now: at("2026-11-25", 23), last: "2026-11-25") == nil)
        #expect(Ping.flags(now: at("2026-11-25", 0), last: "2026-11-25") == nil)
    }

    @Test("Day keys are UTC")
    func utcDay() {
        #expect(Ping.day(at("2026-11-25", 0)) == "2026-11-25")
        #expect(Ping.day(at("2026-11-25", 23)) == "2026-11-25")
        #expect(Ping.day(at("2027-01-01", 0)) == "2027-01-01")
    }

    @Test("Flags across week, month and year lines", arguments: [
        // Wed → Thu, same week and month
        ("2026-11-25", "2026-11-26", ["d"]),
        // Sun → Mon: a new ISO week, same month
        ("2026-11-22", "2026-11-23", ["d", "w"]),
        // Mon → Sun of the same ISO week
        ("2026-11-23", "2026-11-29", ["d"]),
        // Mon Nov 30 → Tue Dec 1: same ISO week, new month
        ("2026-11-30", "2026-12-01", ["d", "m"]),
        // Sat Oct 31 → Sun Nov 1: same week (Mon Oct 26–Sun Nov 1), new month
        ("2026-10-31", "2026-11-01", ["d", "m"]),
        // Thu Dec 31 2026 → Fri Jan 1 2027: ISO week 53 of 2026 both days, new month and year
        ("2026-12-31", "2027-01-01", ["d", "m"]),
        // Sun Jan 3 2027 (still 2026-W53) → Mon Jan 4 2027 (2027-W01)
        ("2027-01-03", "2027-01-04", ["d", "w"]),
        // Mon Dec 29 2025 (2026-W01) → Thu Jan 1 2026 (2026-W01): same week, new month and year
        ("2025-12-29", "2026-01-01", ["d", "m"]),
        // Same week number a year apart is not the same week
        ("2025-11-25", "2026-11-25", ["d", "w", "m"]),
        // Same month a year apart is not the same month
        ("2025-11-30", "2026-11-01", ["d", "w", "m"]),
        // Leap day → next day: new month
        ("2028-02-29", "2028-03-01", ["d", "m"]),
        // A clock set back still counts the day, never twice
        ("2026-11-26", "2026-11-25", ["d"]),
    ])
    func lines(last: String, now: String, expected: [String]) {
        #expect(Ping.flags(now: at(now), last: last) == expected)
    }

    @Test("An unreadable last day is not a new install")
    func garbage() {
        #expect(Ping.flags(now: at("2026-11-25"), last: "junk") == ["d", "w", "m"])
    }
}
