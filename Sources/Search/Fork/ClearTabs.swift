import AppKit
import SwiftUI

/// The Arc-style Clear action: remove only the loose, unorganised pages in the
/// current window's current space. Pins, Saved rows, groups, canvases, tabs
/// another window is showing and pages an agent is driving are deliberately
/// left alone.
@MainActor
final class ClearTabs: ObservableObject {
    static let shared = ClearTabs()

    struct Entry {
        let tab: Tab
        let index: Int
    }

    private struct Snapshot {
        let entries: [Entry]
        let active: Tab.ID?
        let space: UUID
        let ghostIDs: Set<UUID>
        let blankID: Tab.ID?
        let expires: Date
    }

    private var snapshots: [ObjectIdentifier: Snapshot] = [:]
    private var expiry: [ObjectIdentifier: DispatchWorkItem] = [:]

    /// A tiny observable tick for the sidebar and the bottom toast. The actual
    /// snapshots stay private because they contain live Tab/WebKit objects.
    @Published private(set) var generation = 0

    /// Bench and the sidebar use this same predicate, so a visible Clear
    /// button always means that clicking it will do useful work.
    func clearable(in browser: Browser) -> [Tab] {
        browser.tabs.filter { tab in
            guard tab.pin == nil,
                  !tab.isBlank,
                  !Sections.shared.isSaved(tab),
                  Groups.shared.group(of: tab) == nil,
                  CanvasTabs.showing(tab) == nil,
                  !Drive.shared.hands(on: tab.id).contains(where: { $0.busy || $0.until != nil }),
                  !Spaces.shared.shown(tab, outside: browser) else { return false }
            return true
        }
    }

    var hasUndo: Bool { snapshots.values.contains { $0.expires > Date() } }

    func undoCount(in browser: Browser) -> Int? {
        let key = ObjectIdentifier(browser)
        guard let snapshot = snapshots[key], snapshot.expires > Date() else { return nil }
        return snapshot.entries.count
    }

    @discardableResult
    func clear(in browser: Browser) -> Int {
        // A second Clear is a new action, not an invisible way to lose the
        // first undo. Put the previous row back before taking the new snapshot.
        if snapshots[ObjectIdentifier(browser)] != nil { undo(in: browser) }

        let tabs = clearable(in: browser)
        guard !tabs.isEmpty else { return 0 }
        let idsBefore = Set(browser.tabs.map(\.id))
        let entries = tabs.compactMap { tab -> Entry? in
            guard let index = browser.tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
            return Entry(tab: tab, index: index)
        }
        let active = browser.activeID
        let space = Spaces.shared.current(in: browser)
        var ghostIDs = Set<UUID>()

        // Inactive pages first keeps the normal close landing path simple; the
        // active page is closed through exactly the same Browser.close method.
        for tab in entries.map(\.tab) {
            if let ghost = browser.closeForClear(tab) { ghostIDs.insert(ghost) }
        }

        // Arc lands on its ordinary empty/new-tab state after the active loose
        // page goes. If close landed on a kept page, make that state explicit.
        if active.map({ activeID in entries.contains { entry in entry.tab.id == activeID } }) == true,
           let landed = browser.active, !landed.isBlank {
            browser.newTab()
        }
        let blankID = browser.active?.isBlank == true && !idsBefore.contains(browser.active!.id)
            ? browser.active?.id : nil
        let key = ObjectIdentifier(browser)
        let snapshot = Snapshot(entries: entries, active: active, space: space,
                                ghostIDs: ghostIDs, blankID: blankID,
                                expires: Date().addingTimeInterval(6))
        snapshots[key] = snapshot
        generation += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.snapshots[key]?.expires ?? .distantPast <= Date() else { return }
            self.snapshots[key] = nil
            self.generation += 1
        }
        expiry[key]?.cancel()
        expiry[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        return entries.count
    }

    @discardableResult
    func undo(in browser: Browser) -> Int {
        let key = ObjectIdentifier(browser)
        guard let snapshot = snapshots[key], snapshot.expires > Date() else { return 0 }
        expiry[key]?.cancel()
        expiry[key] = nil
        snapshots[key] = nil
        if Spaces.shared.current(in: browser) != snapshot.space {
            Spaces.shared.select(snapshot.space, in: browser)
        }
        browser.restoreClearedTabs(snapshot.entries.map { (tab: $0.tab, index: $0.index) },
                                   activeID: snapshot.active, blankID: snapshot.blankID,
                                   ghostIDs: snapshot.ghostIDs)
        generation += 1
        return snapshot.entries.count
    }

    /// The divider's bench hook makes a hover-only affordance screenshotable.
    func forceDividerHover(_ on: Bool) { ClearTabsDividerHover.shared.forced = on }
}

@MainActor
final class ClearTabsDividerHover: ObservableObject {
    static let shared = ClearTabsDividerHover()
    @Published var forced = false
}

/// The slim seam above Today. At rest it is exactly the plain hairline —
/// same height, so a space with loose tabs doesn't push its rows down on a
/// switch. Hovering it shows a small round button at its end, drawn over
/// the seam rather than beside it, so nothing moves.
struct ClearTabsDivider: View {
    @ObservedObject var browser: Browser
    let tint: SpaceTint
    let count: Int
    @ObservedObject private var hover = ClearTabsDividerHover.shared
    @State private var over = false

    var body: some View {
        let shown = over || hover.forced
        Rectangle()
            .fill(tint.hairline)
            .frame(height: 1)
            .padding(.horizontal, SideBar.rowInset)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Button {
                    ClearTabs.shared.clear(in: browser)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(tint.muted)
                        .frame(width: 16, height: 16)
                        .background(tint.hover, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear \(count) tab\(count == 1 ? "" : "s")")
                .padding(.trailing, SideBar.rowInset)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
            }
            .onHover { over = $0 }
            .animation(.easeOut(duration: 0.12), value: shown)
            .accessibilityLabel("Clear \(count) tabs")
            .accessibilityHint("Closes loose tabs in this space")
    }
}

/// The action pill uses the same ground, hairline and motion as Copper's
/// existing announcements, with the one extra affordance Arc requires.
struct ClearTabsToast: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var clearTabs = ClearTabs.shared

    var body: some View {
        if let count = clearTabs.undoCount(in: browser) {
            HStack(spacing: 10) {
                Text("Cleared \(count) tab\(count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                Button("Undo") { clearTabs.undo(in: browser) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DriveStyle.accent)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
