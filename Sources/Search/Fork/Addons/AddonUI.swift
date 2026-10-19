import AppKit
import SwiftUI

// Where addons show in the window: the agent sidebar slot, the update pill
// beside Copper's own, Settings › Addons (and a card on Settings ›
// Updates), and ⌘K's rows. Everything here reads AddonSync and the slot's
// AddonSlotHost; nothing here downloads, verifies or decides.

// MARK: - the agent sidebar slot

/// What ⌘E opens (Split.swift): the addon assigned to the Agent sidebar,
/// or — with none, with it turned off on this Mac, or when its page
/// couldn't be shown — Copper's own agent pane.
struct AgentSlot: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sync = AddonSync.shared

    var body: some View {
        if let entry = sync.active(.agentSidebar) {
            AddonSlotFrame(browser: browser, host: AddonSlotHost.host(for: browser, slot: .agentSidebar), entry: entry)
        } else {
            AgentPane(browser: browser)
        }
    }
}

/// The addon's page at the pane's width: the same `agent.paneWidth`, the
/// same 340–620 range and the same drag on the leading edge as AgentPane,
/// so switching between the two never moves the page.
struct AddonSlotFrame: View {
    @ObservedObject var browser: Browser
    @ObservedObject var host: AddonSlotHost
    let entry: AddonInstalled
    @ObservedObject private var agent = Agent.shared
    @AppStorage("agent.paneWidth") private var stored: Double = Double(AgentPane.width)
    @State private var dragFrom: Double?

    private var width: CGFloat { CGFloat(min(max(stored, AgentPane.widths.lowerBound), AgentPane.widths.upperBound)) }

    var body: some View {
        Group {
            if host.failed != nil {
                AgentPane(browser: browser)
            } else {
                AddonWebHolder(host: host)
                    .frame(width: width)
                    .background(Palette.ground)
                    .overlay(alignment: .leading) { grip }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(entry.name)
            }
        }
        .onAppear {
            host.follow(entry)
            host.setVisible(true)
        }
        .onDisappear { host.setVisible(false) }
        .onChange(of: entry.pageKey) { _, _ in host.follow(entry) }
        .onChange(of: agent.focusTick) { _, _ in host.focus() }
    }

    /// The leading edge, a few points wide: drag to make the pane wider.
    private var grip: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = dragFrom ?? Double(width)
                        dragFrom = from
                        stored = min(max(from - Double(drag.translation.width), AgentPane.widths.lowerBound), AgentPane.widths.upperBound)
                    }
                    .onEnded { _ in dragFrom = nil }
            )
    }
}

/// Puts the host's web view in the hierarchy while the slot is shown, and
/// takes it out (not down) when SwiftUI lets the slot go.
struct AddonWebHolder: NSViewRepresentable {
    @ObservedObject var host: AddonSlotHost

    func makeNSView(context: Context) -> AddonHolderView {
        let view = AddonHolderView()
        view.host = host
        view.adopt()
        return view
    }

    func updateNSView(_ view: AddonHolderView, context: Context) {
        view.host = host
        view.adopt()
    }

    static func dismantleNSView(_ view: AddonHolderView, coordinator: ()) {
        view.release()
    }
}

final class AddonHolderView: NSView {
    weak var host: AddonSlotHost?

    @MainActor func adopt() {
        guard let web = host?.web, web.superview !== self else { return }
        web.removeFromSuperview()
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        addSubview(web)
    }

    @MainActor func release() {
        for view in subviews where view is AddonWebView { view.removeFromSuperview() }
    }
}

extension AddonSlotHost {
    /// ⌘E, or the pane asked for focus: the keyboard goes to the page.
    func focus() {
        guard let web, let window = web.window else { return }
        window.makeFirstResponder(web)
    }
}

// MARK: - the update pill

/// "Install <addon>" beside Copper's own update pill, which keeps the first
/// place (contract §6.3): in the column it sits under it, in the toolbar
/// after it. One click installs; no relaunch.
struct AddonPillSlot: View {
    @ObservedObject var browser: Browser
    var compact = false
    @ObservedObject private var sync = AddonSync.shared
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still

    private var shown: AddonInstalled? {
        guard let offered = sync.offered, offered.sha256 != sync.snoozed else { return nil }
        return offered
    }

    var body: some View {
        if compact {
            // Among the toolbar's doors: nothing at all, not even a gap,
            // while nothing waits.
            if let entry = shown {
                AddonPill(browser: browser, entry: entry,
                          tint: SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark).offColumn, compact: true)
            }
        } else {
            VStack(spacing: 0) {
                if let entry = shown {
                    SlideInk(browser: browser) { tint in
                        AddonPill(browser: browser, entry: entry, tint: tint, compact: false)
                    }
                    .padding(.horizontal, SideBar.inset)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .transition(still ? .opacity : .offset(y: 14).combined(with: .opacity))
                }
            }
            .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: shown?.sha256)
        }
    }
}

struct AddonPill: View {
    @ObservedObject var browser: Browser
    let entry: AddonInstalled
    let tint: SpaceTint
    let compact: Bool
    @State private var hovering = false

    private var ink: UpdateInk { UpdateInk(tint) }
    private var height: CGFloat { compact ? 24 : 34 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? height / 2 : 10, style: .continuous) }
    /// An addon already in the slot is updated; a new one is installed.
    private var verb: String { AddonSync.shared.state.installed[entry.slot]?.id == entry.id ? "Update" : "Install" }
    private var title: String { compact ? verb : "\(verb) \(entry.name)" }
    private var help: String {
        "\(AddonSync.offer(entry)) is downloaded and verified — click to \(verb.lowercased()) it. No restart."
    }

    var body: some View {
        Button(action: install) {
            HStack(spacing: compact ? 5 : 7) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(ink.label)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minWidth: height, maxWidth: compact ? nil : .infinity)
            .frame(height: height)
            .fixedSize(horizontal: compact, vertical: false)
            .background {
                ZStack {
                    shape.fill(ink.fill)
                    shape.fill(LinearGradient(colors: [.white.opacity(hovering ? 0.22 : 0.14), .clear], startPoint: .top, endPoint: .bottom))
                    shape.strokeBorder(Color.white.opacity(ink.light ? 0.35 : 0.18), lineWidth: 0.75)
                }
                .shadow(color: ink.fill.opacity(0.32), radius: hovering ? 7 : 5, y: 2)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(verb) \(entry.name) \(entry.version)")
        .accessibilityHint(help)
        .contextMenu {
            Button("\(verb) \(AddonSync.offer(entry))") { install() }
            Divider()
            Button("Remind Me Later") { AddonSync.shared.snoozed = entry.sha256 }
            Divider()
            Button("Settings…") { browser.openSettings(.addons) }
        }
        .animation(Motion.quick, value: hovering)
    }

    private func install() {
        let slot = AddonSlot(rawValue: entry.slot)
        if let problem = AddonSync.shared.install(slot) {
            browser.announce(problem)
        } else {
            browser.announce("\(entry.name) \(entry.version) is in the \(slot?.name ?? "slot") now")
        }
    }
}

// MARK: - ⌘K

@MainActor
enum AddonCommands {
    /// An install row right after Copper's own update row, when there is
    /// one waiting; the check and the page always.
    static func add(to list: inout [CommandBar.Command]) {
        let sync = AddonSync.shared
        if let offered = sync.offered {
            let at = list.first?.id == "update" ? 1 : 0
            list.insert(.init(id: "addon-install", name: "Install \(AddonSync.offer(offered))", glyph: "puzzlepiece.extension") { browser in
                if let problem = sync.install(AddonSlot(rawValue: offered.slot)) { browser.announce(problem) }
            }, at: at)
        }
        if Cloud.shared.isLinked {
            list.append(.init(id: "addon-check", name: "Check for addon updates", glyph: "arrow.triangle.2.circlepath") { _ in
                Task { await AddonSync.shared.check() }
            })
        }
        list.append(.init(id: "addons", name: "Addons…", glyph: "puzzlepiece.extension") { $0.openSettings(.addons) })
    }
}

// MARK: - Settings

/// Settings › Addons: what the cloud assigned, what waits to be installed,
/// the per-addon "Use in Agent sidebar" switch, Remove, and the check.
struct AddonsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sync = AddonSync.shared
    @ObservedObject private var cloud = Cloud.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection("Addons", note: "Addons are small web apps a Copper Cloud admin assigns. Each runs on its own, away from your browsing, and asks Copper for only what its manifest lists.") {
                if !cloud.isLinked && sync.installedList.isEmpty && sync.pendingList.isEmpty && sync.development == nil {
                    Line("Addons come from your Copper Cloud", "Link one in Settings › Cloud.") {
                        Pill("Open Cloud") { browser.openSettings(.cloud) }
                    }
                } else if sync.installedList.isEmpty && sync.pendingList.isEmpty && sync.development == nil {
                    Line("No addons", cloud.isSignedIn ? "Your Copper Cloud hasn't assigned you any." : "Sign in to your Copper Cloud to get the addons assigned to you.") {
                        EmptyView()
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                    if index > 0 { Rule() }
                    row.view
                }
            }
            .settingsAnchor("addons.installed")
            SettingsSection("Updates") {
                Line("Check for addon updates", checkedLine) {
                    Pill(sync.checking ? "Checking…" : "Check now") { Task { await sync.check() } }
                        .disabled(sync.checking || (!cloud.isSignedIn && sync.fake == nil))
                }
                .settingsAnchor("addons.check")
            }
            if let problem = sync.lastError {
                SettingsNote(problem)
            }
        }
    }

    private struct Row {
        let key: String
        let view: AnyView
    }

    private var rows: [Row] {
        var out: [Row] = []
        if let dev = sync.development {
            out.append(Row(key: "dev", view: AnyView(
                Line("\(dev.name) \(dev.version) · development", "From \(dev.dir) (COPPER_ADDONS_DEV_DIR), ahead of anything installed") {
                    Pill("Reload") { AddonSync.shared.useDevelopment(URL(fileURLWithPath: dev.dir, isDirectory: true)) }
                })))
        }
        for (index, entry) in sync.installedList.enumerated() {
            let first = index == 0
            out.append(Row(key: "i-\(entry.id)", view: AnyView(VStack(spacing: 0) {
                Line("\(entry.name) \(entry.version)", installedLine(entry)) {
                    Pill("Remove") { AddonSync.shared.remove(entry.id) }
                }
                .settingsAnchor(first ? "addons.remove" : "addons.remove.\(entry.id)")
                Rule()
                Line("Use in \(AddonSlot(rawValue: entry.slot)?.name ?? entry.slot)", "Off shows Copper's own view there instead; the addon stays installed") {
                    Switch(on: Binding(get: { AddonSync.shared.isEnabled(entry.id) },
                                       set: { AddonSync.shared.setEnabled(entry.id, $0) }))
                }
                .settingsAnchor(first ? "addons.use" : "addons.use.\(entry.id)")
            })))
        }
        for entry in sync.pendingList {
            out.append(Row(key: "p-\(entry.id)-\(entry.sha256)", view: AnyView(
                Line("\(AddonSync.offer(entry))", "Downloaded and verified · from \(entry.source). Installing takes effect at once; no restart.") {
                    Pill("Install", filled: true) {
                        if let problem = AddonSync.shared.install(AddonSlot(rawValue: entry.slot)) { browser.announce(problem) }
                    }
                })))
        }
        return out
    }

    private func installedLine(_ entry: AddonInstalled) -> String {
        var parts = [AddonSlot(rawValue: entry.slot)?.name ?? entry.slot, "from \(entry.source.isEmpty ? "your cloud" : entry.source)"]
        if let at = AddonTime.date(entry.installedAt) { parts.append("installed \(at.formatted(.relative(presentation: .named)))") }
        if !sync.isEnabled(entry.id) { parts.append("off on this Mac") }
        if let host = AddonSlotHost.front(AddonSlot(rawValue: entry.slot) ?? .agentSidebar), host.entry?.id == entry.id, let failed = host.failed {
            parts.append("couldn't show: \(failed)")
        }
        return parts.joined(separator: " · ")
    }

    private var checkedLine: String {
        if sync.checking { return "Checking…" }
        guard let at = AddonTime.date(sync.state.lastCheck) else {
            return cloud.isSignedIn ? "Copper looks at launch, every six hours and with every update check" : "Not signed in to a cloud"
        }
        return "Last checked \(at.formatted(.relative(presentation: .named)))"
    }
}

/// On Settings › Updates, under Copper's own: an addon that waits for its
/// Install, said the same way the pill says it.
struct AddonUpdatesSection: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sync = AddonSync.shared

    var body: some View {
        if !sync.pendingList.isEmpty {
            SettingsSection("Addons") {
                ForEach(Array(sync.pendingList.enumerated()), id: \.element.sha256) { index, entry in
                    if index > 0 { Rule() }
                    Line(AddonSync.offer(entry), "Downloaded and verified · Install puts it in place at once, no restart") {
                        Pill("Install", filled: true) {
                            if let problem = AddonSync.shared.install(AddonSlot(rawValue: entry.slot)) { browser.announce(problem) }
                        }
                    }
                }
            }
        }
    }
}

/// Settings › Addons, as search finds it (SettingsIndex.rows).
enum AddonSettingsIndex {
    static let entries: [SettingsEntry] = [
        SettingsEntry(page: .addons, section: "Addons", title: "Installed addons",
                      subtitle: "What your Copper Cloud assigned you, and where each shows",
                      keywords: ["addon", "add-on", "agent sidebar", "web app", "cloud addons"], anchor: "addons.installed"),
        SettingsEntry(page: .addons, section: "Addons", title: "Use in Agent sidebar",
                      subtitle: "Show the addon, or Copper's own agent pane, in the sidebar ⌘E opens",
                      keywords: ["disable addon", "turn off addon", "agent pane", "sidebar"], anchor: "addons.use",
                      fallback: "addons.installed"),
        SettingsEntry(page: .addons, section: "Addons", title: "Remove an addon",
                      subtitle: "On this Mac, until your cloud next changes what you're assigned",
                      keywords: ["uninstall addon", "delete addon"], anchor: "addons.remove", fallback: "addons.installed"),
        SettingsEntry(page: .addons, section: "Updates", title: "Check for addon updates",
                      subtitle: "Ask your Copper Cloud now; new versions install with one click, no restart",
                      keywords: ["addon update", "refresh addons"], anchor: "addons.check"),
    ]
}
