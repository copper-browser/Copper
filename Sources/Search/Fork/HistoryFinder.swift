import Foundation

/// Fork (history-panel-perf): ⌘Y's list, found off the main thread and drawn
/// a page at a time.
///
/// The History panel used to put every place in history — 20,000 after a move
/// from Arc — into one eager stack of rows, each measuring two fading titles,
/// and to ask for every one of their icons. Opening it held the main thread
/// for as long as it took to lay out twenty thousand rows, and the app was
/// killed before it got there. Now the matching and the newest-first sort run
/// on a queue of their own, the panel draws the newest `page` lines, and the
/// next page is drawn when the list is scrolled to its end.
@MainActor
final class HistoryFinder: ObservableObject {
    /// Lines drawn at a time: more than a tall window shows, few enough that
    /// laying them out is a moment's work. A test world may ask for fewer
    /// (`SEARCH_HISTORY_PAGE`), so a short page shows the next one coming.
    static let page: Int = {
        guard Store.testing, let asked = ProcessInfo.processInfo.environment["SEARCH_HISTORY_PAGE"].flatMap(Int.init), asked > 0 else { return 120 }
        return asked
    }()

    /// One day's lines, newest first.
    struct Day: Identifiable {
        let id: Date
        let title: String
        let rows: [History.Trace]
    }

    /// What the list draws: the newest `shown` matches, by day.
    @Published private(set) var days: [Day] = []
    /// The places drawn, flat, newest first (for their icons).
    @Published private(set) var rows: [History.Trace] = []
    /// How many places match in all — drawn or not.
    @Published private(set) var total = 0
    /// False until the first answer is in, so a list still being found is
    /// never mistaken for an empty history.
    @Published private(set) var ready = false
    /// Which answer the list is drawing. A lazy stack keeps the height it
    /// guessed for a longer list, so the panel draws a fresh one for each
    /// new question — and for a list short enough to draw whole.
    @Published private(set) var answer = 0

    var more: Bool { rows.count < matches.count }

    private var matches: [History.Place] = []
    private var shown = HistoryFinder.page
    private var asked = 0

    /// Shared between panels: the flattened, sorted history stays good for
    /// as long as history does not change, so opening ⌘Y twice sorts once.
    private nonisolated static let queue = DispatchQueue(label: "copper.history.panel", qos: .userInitiated)
    private nonisolated static let worker = Worker()

    /// The newest page of what matches `typed`. `keep` holds on to how far
    /// the list was scrolled out (after removing a line, say).
    func find(_ typed: String, in history: History, keep: Bool = false) {
        asked &+= 1
        let ask = asked
        if !keep { shown = Self.page }
        let snapshot = history.snapshot
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        Self.queue.async { [weak self] in
            let found = Self.worker.find(snapshot, needle: needle)
            DispatchQueue.main.async {
                // An answer to an older question is no use to this one.
                guard let self, self.asked == ask else { return }
                self.matches = found
                self.total = found.count
                self.ready = true
                self.draw()
                if !keep || !self.more { self.answer &+= 1 }
            }
        }
    }

    /// The next page, when the list has been scrolled to its end.
    func next() {
        guard more else { return }
        shown += Self.page
        draw()
    }

    private func draw() {
        let traces = matches.prefix(shown).compactMap { place in
            URL(string: place.url).map {
                History.Trace(key: place.key, title: place.title, url: $0, last: place.last, count: place.count)
            }
        }
        rows = traces
        days = Self.byDay(traces)
    }

    /// Newest first already, so a day is a run of lines: one pass, no sort.
    nonisolated static func byDay(_ traces: [History.Trace]) -> [Day] {
        let calendar = Calendar.current
        var out: [Day] = []
        var start: Date?
        var run: [History.Trace] = []
        for trace in traces {
            let day = calendar.startOfDay(for: trace.last)
            if day != start {
                if let start, !run.isEmpty { out.append(Day(id: start, title: When.day(start), rows: run)) }
                start = day
                run = []
            }
            run.append(trace)
        }
        if let start, !run.isEmpty { out.append(Day(id: start, title: When.day(start), rows: run)) }
        return out
    }

    /// The queue's own state: history flattened and sorted once per change
    /// to it, not once per keystroke. Only ever touched on `queue`.
    final class Worker: @unchecked Sendable {
        private var generation = -1
        private var places: [History.Place] = []

        func find(_ history: History.Snapshot, needle: String) -> [History.Place] {
            if history.generation != generation {
                places = HistoryFinder.listed(history.places())
                generation = history.generation
            }
            return HistoryFinder.matching(places, needle: needle)
        }
    }

    /// Everywhere you have been, newest first. Every visit to a page also
    /// credits its domain, so the address field can offer the front door;
    /// those credits have no title of their own, and in a list of where you
    /// have been they are a second copy of every line.
    nonisolated static func listed(_ places: [History.Place]) -> [History.Place] {
        places
            .filter { !($0.title.isEmpty && !$0.key.contains("/")) }
            .sorted { $0.last == $1.last ? $0.key < $1.key : $0.last > $1.last }
    }

    /// The places that answer to what was typed, in the order given. Words
    /// first, as ⌘K matches them (each word in the address or the title);
    /// when no place has them all, the letters in order anywhere in an
    /// address or title ("ghpr" finds github.com/…/pull/…).
    nonisolated static func matching(_ places: [History.Place], needle: String) -> [History.Place] {
        let needle = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return places }
        if let probe = Launcher.Needle(needle) {
            let hits = places.filter { probe.score(key: $0.key, title: $0.lowered) != nil }
            if !hits.isEmpty { return hits }
        }
        let letters = Array(Launcher.strip(needle).utf8.filter { $0 != UInt8(ascii: " ") })
        guard letters.count >= 3 else { return [] }
        return places.filter { inOrder(letters, $0.key) || inOrder(letters, $0.lowered) }
    }

    /// Every letter of `letters`, in order, somewhere in `text`.
    nonisolated static func inOrder(_ letters: [UInt8], _ text: String) -> Bool {
        var text = text
        return text.withUTF8 { hay in
            var at = 0
            for byte in hay where byte == letters[at] {
                at += 1
                if at == letters.count { return true }
            }
            return false
        }
    }
}
