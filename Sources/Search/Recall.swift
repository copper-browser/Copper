import SwiftUI

/// Everywhere you have been, and everything you have kept. Two lists in the
/// same white-and-hairline panel as the rest, and in both cases the point is
/// as much being able to remove a line as to read one.

enum When {
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date) -> String {
        ago.localizedString(for: date, relativeTo: Date())
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The time of day. Once a list is grouped by day, that is all a row needs.
    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

struct HistoryPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var hunting: Bool
    @State private var traces: [History.Trace] = []
    @State private var clearing = false

    var body: some View {
        // Fork (ui-system): empty is a state (symbol, line, one way to fill
        // it) with no search, count or Clear; the list is as tall as it is.
        let none = traces.isEmpty && browser.recallHunt.isEmpty
        Plate("History", width: 600, footed: !traces.isEmpty || clearing, close: { browser.recalling = false }) {
            VStack(alignment: .leading, spacing: 14) {
                if none && !clearing {
                    EmptyState("clock", "No history yet", "Pages you visit show up here, by day.") {
                        Pill("Move in from another browser…") {
                            browser.recalling = false
                            Flow.shared.present(from: browser, via: .menu)
                        }
                    }
                } else {
                    Hunt(text: $browser.recallHunt, prompt: "Search everywhere you have been", focus: $hunting)
                }

                if traces.isEmpty {
                    if !none { EmptyState("magnifyingglass", "No matches", "Nothing you have visited matches “\(browser.recallHunt)”.") }
                } else {
                    Fitted {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(days, id: \.0) { day, rows in
                                VStack(alignment: .leading, spacing: 6) {
                                    Caption(day)
                                    Card {
                                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, trace in
                                            if index > 0 { Rule() }
                                            Row(
                                                trace: trace,
                                                go: {
                                                    browser.recalling = false
                                                    browser.active?.go(to: trace.url)
                                                },
                                                forget: {
                                                    browser.history.forget(trace.key)
                                                    CloudSync.shared.historyForgot(trace.key) // Fork (cloud-history-delete): its rows on Copper Cloud too
                                                    refresh()
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
            }
        } foot: {
            if clearing {
                sweeps
            } else {
                HStack {
                    Text(traces.count == 1 ? "1 page" : "\(traces.count) pages")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Pill("Clear…") { withAnimation(Motion.settle) { clearing = true } }
                }
            }
        }
        .animation(Motion.settle, value: clearing)
        .onAppear {
            hunting = true
            refresh()
        }
        .onChange(of: browser.recallHunt) { _, _ in refresh() }
    }

    /// Three separate things, worded so nobody has to guess which one signs
    /// them out of their bank.
    private var sweeps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                Line("History", "Everywhere you have been") {
                    Pill("Clear") {
                        browser.clearHistory()
                        refresh()
                        withAnimation(Motion.settle) { clearing = false }
                    }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
            HStack {
                Spacer()
                Pill("Back") { withAnimation(Motion.settle) { clearing = false } }
            }
        }
        .transition(.opacity)
    }

    private var days: [(String, [History.Trace])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: traces) { calendar.startOfDay(for: $0.last) }
        return grouped.keys.sorted(by: >).map { day in
            (When.day(day), grouped[day]!.sorted { $0.last > $1.last })
        }
    }

    private func refresh() {
        traces = browser.history.everything(matching: browser.recallHunt)
    }

    /// One line. A title, where it came from, and when — the three things you
    /// scan for, in the order you scan them.
    private struct Row: View {
        let trace: History.Trace
        let go: () -> Void
        let forget: () -> Void

        @State private var hovering = false
        @Environment(\.colorScheme) private var scheme // Fork (ui-flows)

        var body: some View {
            HStack(spacing: 12) {
                // Fork (ui-flows): in the panel's own look's ink — a one-colour
                // mark (GitHub's) inked for the app's look vanished on a panel
                // drawn in the other one.
                Mark(icon: Favicons.shared.cached(trace.url.host()?.lowercased() ?? "").map { IconInk.legible($0, dark: scheme == .dark) },
                     letter: trace.key.first.map { String($0).uppercased() } ?? "•", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.title.isEmpty ? trace.key : trace.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(trace.key)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: .red.opacity(0.75), act: forget)
                } else {
                    Text(When.clock(trace.last))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: go)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var loot: Loot
    @ObservedObject var downloads: Downloads

    private var session: [Downloads.Item] {
        downloads.shown
    }

    private var older: [Keep] {
        let paths = Set(session.compactMap { $0.file?.path })
        return loot.kept.filter { !paths.contains($0.path) }
    }

    var body: some View {
        let none = session.isEmpty && older.isEmpty
        let folder = browser.prefs.downloads.lastPathComponent
        // Fork (ui-system): empty is a state with one way out (the folder),
        // and no foot; a short list is short.
        Plate("Downloads", width: 600, footed: !none, close: { browser.hoarding = false }) {
            if none {
                EmptyState("arrow.down.circle", "No downloads yet", "Files you download land in \(folder).") {
                    Pill("Open \(folder)") { browser.openDownloadsFolder() }
                }
            } else {
                Fitted {
                    Card {
                        ForEach(session) { item in
                            DownloadRow(item: item, browser: browser, downloads: downloads)
                            if item.id != session.last?.id || !older.isEmpty { Rule() }
                        }
                        ForEach(older) { keep in
                            DownloadRow(keep: keep, browser: browser, downloads: downloads)
                            if keep.id != older.last?.id { Rule() }
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        } foot: {
            HStack {
                Text("Clearing the list leaves the files where they are")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Pill("Open Folder") { browser.openDownloadsFolder() }
                Pill("Clear list") {
                    downloads.clearFinished()
                    loot.forgetAll()
                }
            }
        }
    }
}
