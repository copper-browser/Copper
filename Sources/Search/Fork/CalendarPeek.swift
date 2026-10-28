import AppKit
import EventKit
import SwiftUI

/// Arc's calendar peek: rest the pointer on a Google Calendar pin and the
/// next meetings show beside it, with a Join button for a video call. They
/// come from the calendars macOS keeps (System Settings › Internet Accounts —
/// what Calendar.app shows), read with EventKit: Copper signs in to nothing
/// of its own, and nothing leaves the Mac.
@MainActor
final class CalendarPeek: ObservableObject {
    static let shared = CalendarPeek()

    struct Meeting: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: Color
        let join: URL?
    }

    enum State: Equatable {
        /// Never asked: the card offers to.
        case asking
        /// Said no (or a profile forbids it): the card says where to change it.
        case refused
        /// Allowed, but macOS has no calendar of events to read.
        case noCalendars
        case meetings([Meeting])
    }

    /// How far ahead the card looks, and how many meetings it lists.
    static let ahead: TimeInterval = 12 * 60 * 60
    static let limit = 4

    @Published fileprivate(set) var state: State = .asking
    private let store = EKEventStore()
    private var watching: NSObjectProtocol?

    /// Pins that peek: Google Calendar's.
    nonisolated static func peeks(_ url: URL?) -> Bool {
        url?.host()?.lowercased() == "calendar.google.com"
    }

    private static var access: Bool? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return nil
        default: return false // denied, restricted, or write-only: nothing to read
        }
    }

    func ask() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if granted { refresh() } else { state = .refused }
        }
    }

    /// Read the next meetings again: each time the card opens, and when
    /// Calendar's data changes while it is open.
    func refresh(now: Date = Date()) {
        switch Self.access {
        case nil: state = .asking; return
        case false?: state = .refused; return
        case true?: break
        }
        if watching == nil {
            watching = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarPeek.shared.refresh() }
            }
        }
        // Birthdays and subscribed calendars (holidays, sports) are not meetings.
        let calendars = store.calendars(for: .event).filter { $0.type != .birthday && $0.type != .subscription }
        guard !calendars.isEmpty else { state = .noCalendars; return }
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now + Self.ahead, calendars: calendars))
        state = .meetings(Self.next(events.compactMap(Self.meeting), now: now))
    }

    /// A meeting worth listing, or nil: no all-day events, nothing cancelled,
    /// nothing you declined.
    private static func meeting(_ event: EKEvent) -> Meeting? {
        guard !event.isAllDay, event.status != .canceled,
              event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined else { return nil }
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Meeting(id: event.calendarItemIdentifier + "@\(event.startDate.timeIntervalSince1970)",
                       title: title.isEmpty ? "Busy" : title, start: event.startDate, end: event.endDate,
                       color: Color(cgColor: event.calendar.cgColor),
                       join: joinLink(url: event.url, location: event.location, notes: event.notes))
    }

    /// The ones not over yet, soonest first, at most `limit`.
    nonisolated static func next(_ meetings: [Meeting], now: Date) -> [Meeting] {
        Array(meetings.filter { $0.end > now }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }.prefix(limit))
    }

    /// Video-call hosts a Join button is for. Any other link in an invite (a
    /// doc, an agenda) is not a way into the meeting.
    nonisolated static let callHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]

    /// The meeting's call link: the event's own URL if it is one, else the
    /// first call link in its location, then its notes.
    nonisolated static func joinLink(url: URL?, location: String?, notes: String?) -> URL? {
        func isCall(_ url: URL) -> Bool {
            guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
            return callHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if let url, isCall(url) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [location, notes].compactMap({ $0 }) {
            let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            if let call = links.first(where: isCall) { return call }
        }
        return nil
    }
}

/// The card beside the pin.
struct CalendarPeekCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var peek = CalendarPeek.shared
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Coming up")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            switch peek.state {
            case .asking:
                note("See your next meetings here, from the calendars on this Mac.",
                     action: "Allow Calendar Access") { peek.ask() }
            case .refused:
                note("Copper isn't allowed to read your calendars.", action: "Open Privacy Settings") {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                }
            case .noCalendars:
                note("Add your Google account in Internet Accounts, with Calendars on, to see your meetings here.",
                     action: "Open Internet Accounts") {
                    open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                }
            case .meetings(let list) where list.isEmpty:
                Text("Nothing in the next 12 hours.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            case .meetings(let list):
                ForEach(list) { meeting in
                    row(meeting)
                    if meeting.id != list.last?.id {
                        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 31)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(width: 290, alignment: .leading)
        .background(Palette.ground)
    }

    private func row(_ meeting: CalendarPeek.Meeting) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(meeting.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(when(meeting))
                    .font(.system(size: 11.5))
                    .foregroundStyle(meeting.start <= now ? Color.accentColor : Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let join = meeting.join {
                Button("Join") { browser.open(join, foreground: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .focusable(false)
                    .help(join.host() ?? "Join")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    /// "Now · until 10:30 AM", "In 12 min · 11:00 – 11:30 AM", "2:00 – 3:00 PM".
    private func when(_ meeting: CalendarPeek.Meeting) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if meeting.start <= now { return "Now · until \(meeting.end.formatted(time))" }
        let span = "\(meeting.start.formatted(time)) – \(meeting.end.formatted(time))"
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 60 ? "In \(minutes) min · \(span)" : span
    }

    private func note(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform)
                .controlSize(.small)
                .focusable(false)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - bench

extension CalendarPeek {
    /// `./bench calendar [state|stage|key|picture PATH]`: what the card would
    /// list; (test worlds) a staged list of meetings, since a probe can't be
    /// granted calendar access; which window is key while the card is open
    /// (it must never take the page's keyboard); the card's window to a PNG.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let peek = CalendarPeek.shared
        switch request["op"] as? String ?? "state" {
        case "stage":
            guard Store.testing else { return ["error": "test worlds only"] }
            let now = Date()
            let at = { (minutes: Double) in now + minutes * 60 }
            peek.state = .meetings([
                Meeting(id: "a", title: "Daily standup", start: at(-5), end: at(10), color: .blue,
                        join: URL(string: "https://meet.google.com/abc-defg-hij")),
                Meeting(id: "b", title: "Thermal storage design review with the whole controls team", start: at(25), end: at(55),
                        color: .green, join: URL(string: "https://zoom.us/j/123")),
                Meeting(id: "c", title: "Lunch", start: at(150), end: at(210), color: .orange, join: nil),
            ])
            return ["staged": 3]
        case "key":
            let key = NSApp.keyWindow
            return ["key": key.map { String(describing: type(of: $0)) } ?? "none",
                    "card": NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }]
        case "picture":
            guard let path = request["arg"] as? String, !path.isEmpty else { return ["error": "calendar picture PATH"] }
            guard let card = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(card.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return ["error": "no card open"] }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
            return ["path": path, "size": [image.width, image.height]]
        default:
            switch peek.state {
            case .asking: return ["state": "asking"]
            case .refused: return ["state": "refused"]
            case .noCalendars: return ["state": "noCalendars"]
            case .meetings(let list):
                return ["state": "meetings", "meetings": list.map {
                    ["title": $0.title, "start": $0.start.timeIntervalSince1970, "end": $0.end.timeIntervalSince1970,
                     "join": $0.join?.absoluteString ?? ""]
                }]
            }
        }
    }
}
