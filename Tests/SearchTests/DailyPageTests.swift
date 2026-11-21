import Foundation
import Testing
@testable import Search

// The morning page's day (Fork/DailyPage.swift): it turns over at the hour, in
// wall-clock time, so a launch past midnight still belongs to yesterday and a
// DST night moves nothing.

@Suite("Morning page rollover")
struct DailyPageTests {
    private static let ny: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Self.ny.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func due(now: Date, shown: Date?, hour: Int = 3) -> Bool {
        DailyPage.due(now: now, lastShown: shown, hour: hour, calendar: Self.ny)
    }

    @Test("Never shown: due")
    func neverShown() { #expect(due(now: at(2026, 11, 21, 10), shown: nil)) }

    @Test("Shown yesterday morning: due after 3 AM, not before")
    func beforeAndAfterThree() {
        let yesterday = at(2026, 11, 20, 10)
        #expect(!due(now: at(2026, 11, 21, 2, 59), shown: yesterday))
        #expect(due(now: at(2026, 11, 21, 3, 0), shown: yesterday))
        #expect(due(now: at(2026, 11, 21, 9, 45), shown: yesterday))
    }

    @Test("Shown today: a second window or launch is not due")
    func onceADay() {
        let shown = at(2026, 11, 21, 9, 50)
        #expect(!due(now: at(2026, 11, 21, 9, 51), shown: shown))
        #expect(!due(now: at(2026, 11, 21, 23, 59), shown: shown))
        // Past midnight still belongs to the same day...
        #expect(!due(now: at(2026, 11, 22, 1, 30), shown: shown))
        // ...until the next 3 AM.
        #expect(due(now: at(2026, 11, 22, 3, 0), shown: shown))
    }

    @Test("Shown at 1 AM after a late night: the 3 AM after it is a new day")
    func launchPastMidnight() {
        let late = at(2026, 11, 21, 1, 0) // belongs to the 20th's day
        #expect(DailyPage.dayStart(late, hour: 3, calendar: Self.ny) == at(2026, 11, 20, 3))
        #expect(!due(now: at(2026, 11, 21, 2, 0), shown: late))
        #expect(due(now: at(2026, 11, 21, 3, 5), shown: late))
    }

    @Test("DST: the day still turns at 3 AM wall clock")
    func daylightSaving() {
        // Spring forward, 2027-03-14 (2 AM → 3 AM): a 23-hour day.
        #expect(DailyPage.dayStart(at(2027, 3, 14, 10), hour: 3, calendar: Self.ny) == at(2027, 3, 14, 3))
        #expect(due(now: at(2027, 3, 14, 3, 1), shown: at(2027, 3, 13, 9)))
        #expect(!due(now: at(2027, 3, 14, 1, 59), shown: at(2027, 3, 13, 9)))
        // Fall back, 2026-11-01 (2 AM → 1 AM): a 25-hour day.
        #expect(DailyPage.dayStart(at(2026, 11, 1, 10), hour: 3, calendar: Self.ny) == at(2026, 11, 1, 3))
        #expect(DailyPage.dayStart(at(2026, 11, 1, 2), hour: 3, calendar: Self.ny) == at(2026, 10, 31, 3))
        #expect(due(now: at(2026, 11, 1, 3), shown: at(2026, 10, 31, 22)))
        // An hour that doesn't exist that night (2 AM, spring forward) lands on the next real one.
        #expect(DailyPage.dayStart(at(2027, 3, 14, 10), hour: 2, calendar: Self.ny) == at(2027, 3, 14, 3))
    }

    @Test("Another rollover hour")
    func otherHour() {
        #expect(!due(now: at(2026, 11, 21, 4, 30), shown: at(2026, 11, 20, 12), hour: 5))
        #expect(due(now: at(2026, 11, 21, 5, 0), shown: at(2026, 11, 20, 12), hour: 5))
    }
}
