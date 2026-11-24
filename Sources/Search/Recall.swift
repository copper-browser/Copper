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
    @Bindable var browser: Browser

    @FocusState private var hunting: Bool
    // Fork (history-panel-perf): found off the main thread, drawn a page at
    // a time — every place at once (20,000 after a move from Arc) hung ⌘Y.
    @StateObject private var finder = HistoryFinder()
    @State private var clearing = false
    /// Fork (polish r5): a site's mark asked for (`Marks.want`) lands here.
    @ObservedObject private var marks = Marks.ticker

    var body: some View {
        // Fork (ui-system): empty is a state (symbol, line, one way to fill
        // it) with no search, count or Clear; the list is as tall as it is.
        let none = finder.ready && finder.total == 0 && browser.recallHunt.isEmpty
        Plate("History", width: 600, footed: !finder.rows.isEmpty || clearing, close: { browser.recalling = false }) {
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

                if finder.rows.isEmpty {
                    if finder.ready && !none { EmptyState("magnifyingglass", "No matches", "Nothing you have visited matches “\(browser.recallHunt)”.") }
                } else {
                    Fitted {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(finder.days) { day in
                                VStack(alignment: .leading, spacing: 6) {
                                    Caption(day.title)
                                    Card {
                                        ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, trace in
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
                                                    refresh(keep: true)
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                            // The next page, as the list is scrolled to its end.
                            if finder.more {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .id(finder.rows.count) // a new one per page, so each page's end asks again
                                    .onAppear { finder.next() }
                            }
                        }
                        .padding(.bottom, 2)
                        .id(finder.answer)
                    }
                }
            }
        } foot: {
            if clearing {
                sweeps
            } else {
                HStack {
                    Text(finder.total == 1 ? "1 page" : "\(finder.total.formatted()) pages")
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
        // Fork (polish r5): a site's real icon, not a globe, wherever it can
        // be had — for the lines drawn, not for all of history.
        .onReceive(finder.$rows) { rows in Marks.want(rows.map(\.url)) }
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

    private func refresh(keep: Bool = false) {
        finder.find(browser.recallHunt, in: browser.history, keep: keep)
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
                     size: 16)
                // Fork (uiflows r4): the title said once, as ⌘K says it, and
                // both lines fade out at the end instead of ending in "…".
                VStack(alignment: .leading, spacing: 2) {
                    FadingTitle(text: Text(trace.title.isEmpty ? trace.key : CommandPalette.tidy(trace.title))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink))
                    FadingTitle(text: Text(trace.key)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted))
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: Palette.danger, act: forget)
                } else {
                    Text(When.clock(trace.last))
                        .font(.system(size: 12))
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
    let browser: Browser
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
