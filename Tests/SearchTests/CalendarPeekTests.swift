import Foundation
import SwiftUI
import Testing
@testable import Search

@Suite("Calendar pin card")
struct CalendarPeekTests {
    @Test("Only Google Calendar pins peek")
    func peeks() {
        #expect(CalendarPeek.peeks(URL(string: "https://calendar.google.com/calendar/u/1/r")))
        #expect(CalendarPeek.peeks(URL(string: "https://CALENDAR.google.com/calendar/r?authuser=a@b.com")))
        #expect(!CalendarPeek.peeks(URL(string: "https://mail.google.com/mail/u/0/")))
        #expect(!CalendarPeek.peeks(nil))
    }

    @Test("Join is a video call link: the event's URL first, then the location, then the notes; never a doc link")
    func joinLink() {
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        #expect(CalendarPeek.joinLink(url: meet, location: nil, notes: nil) == meet)
        #expect(CalendarPeek.joinLink(url: URL(string: "https://docs.google.com/doc/1"), location: "Room 4",
                                      notes: "Agenda https://docs.google.com/doc/1\nJoin: https://us02web.zoom.us/j/8812?pwd=x")?
            .absoluteString == "https://us02web.zoom.us/j/8812?pwd=x")
        #expect(CalendarPeek.joinLink(url: nil, location: "https://teams.microsoft.com/l/meetup-join/19%3a", notes: "https://meet.google.com/x")?
            .host() == "teams.microsoft.com")
        #expect(CalendarPeek.joinLink(url: nil, location: "HQ, 2nd floor", notes: "see https://notzoom.us.example.com/j/1") == nil)
        #expect(CalendarPeek.joinLink(url: URL(string: "http://meet.google.com/abc"), location: nil, notes: nil) == nil)
    }

    @Test("The card lists what isn't over yet, soonest first, four at most")
    func next() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(_ id: String, _ start: Double, _ end: Double) -> CalendarPeek.Meeting {
            .init(id: id, title: id, start: now + start * 60, end: now + end * 60, color: .blue, join: nil)
        }
        let list = [meeting("later", 90, 120), meeting("over", -60, -1), meeting("now", -10, 20), meeting("soon", 15, 45),
                    meeting("tonight", 300, 330), meeting("evening", 200, 230), meeting("ends now", -30, 0)]
        #expect(CalendarPeek.next(list, now: now).map(\.id) == ["now", "soon", "later", "evening"])
    }
}
