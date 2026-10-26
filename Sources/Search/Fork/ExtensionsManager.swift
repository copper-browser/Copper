import AppKit
import SwiftUI
import WebKit

// Settings › Extensions: every extension, and everything about each — what
// chrome://extensions is in Chrome.
//
// The only way in used to be Settings › Extensions: a row per extension, a
// switch, a line of small print, and the actions only under the pointer.
// Nothing said what an extension could read, which sites it ran on, what it
// had complained about or where an unpacked one lived, and the only door to
// it was a puzzle piece that comes out of the address pill under the pointer.
// So there is a door at the column's foot that is always there, and for a
// while a card of its own over the window behind it. Collin wanted it back
// where the rest of the settings are, so the manager is that Settings page
// now, and every door — the foot's, the pill's puzzle piece, every "Manage
// Extensions…" — opens Settings on it (`Browser.openSettings(.extensions)`).
//
// Everything reads `Extensions.shared` as it is, so a switch here moves the
// pill, and a pin from the pill's menu moves the switch here.

/// Which extension is opened out, and the filter, on Settings › Extensions.
@MainActor
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()
    @Published var expanded: String?
    @Published var query = ""
    /// Bumped when WebKit changes what an extension may do or has said —
    /// a grant from a prompt, a revoke here, a new error — none of which
    /// `Extensions` publishes.
    @Published private(set) var changed = 0

    /// Whether the page is up: Settings open on Extensions in the window in front.
    var showing: Bool {
        let browser = Windows.current
        return browser.tuning && browser.settingsPage == .extensions
    }

    private var watchers: [NSObjectProtocol] = []

    private init() {
        guard #available(macOS 15.4, *) else { return }
        let names: [Notification.Name] = [
            WKWebExtensionContext.errorsDidUpdateNotification,
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
        watchers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed += 1 }
            }
        }
    }

    func noteChange() { changed += 1 }

    /// Settings on Extensions, with one extension opened out if asked.
    func open(_ id: String? = nil, in browser: Browser? = nil) {
        let browser: Browser = if #available(macOS 15.4, *) { browser ?? Extensions.shared.browser ?? Windows.current } else { browser ?? Windows.current }
        if let id { expanded = id }
        browser.openSettings(.extensions)
    }

    /// Settings put away, if it is on Extensions.
    func close() {
        if showing { Windows.current.tuning = false }
    }
}

// MARK: - site choices that outlast a launch

@available(macOS 15.4, *)
extension Extensions {
    private static func deniedKey(_ id: String) -> String { "extensions.denied.\(id)" }

    /// The sites taken away from an extension on its page, by pattern.
    static func deniedSites(_ id: String) -> Set<String> {
        Set(Store.settings.stringArray(forKey: deniedKey(id)) ?? [])
    }

    static func forgetSites(_ id: String) {
        Store.settings.removeObject(forKey: deniedKey(id))
    }

    /// Loading grants everything the extension was installed with; this then
    /// takes back what the person took back, so a revoke lasts past the
    /// next launch. Called from `load`, before the context is loaded.
    func applySiteChoices(_ context: WKWebExtensionContext) {
        for string in Extensions.deniedSites(context.uniqueIdentifier) {
            guard let pattern = try? WKWebExtension.MatchPattern(string: string) else { continue }
            context.setPermissionStatus(.deniedExplicitly, for: pattern)
        }
    }

    /// One of the sites it asked for, allowed or taken away — now, and at
    /// every launch after.
    func setSite(_ pattern: WKWebExtension.MatchPattern, allowed: Bool, for id: String) {
        var denied = Extensions.deniedSites(id)
        if allowed { denied.remove(pattern.string) } else { denied.insert(pattern.string) }
        if denied.isEmpty { Extensions.forgetSites(id) } else { Store.settings.set(denied.sorted(), forKey: Extensions.deniedKey(id)) }
        contexts[id]?.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: pattern)
        ExtensionManager.shared.noteChange()
    }
}

// MARK: - what an extension is, loaded or not

/// A switched-off extension has no context, and so nothing to read its name,
/// icon or description from. Its folder is read once instead, without
/// loading it, so the page can say what it is.
@available(macOS 15.4, *)
@MainActor
final class ExtensionFacts: ObservableObject {
    static let shared = ExtensionFacts()
    @Published private(set) var read: [String: WKWebExtension] = [:]
    private var reading: Set<String> = []

    func of(_ item: Installed, in extensions: Extensions) -> WKWebExtension? {
        if let context = extensions.contexts[item.id] { return context.webExtension }
        let key = item.id + "@" + item.version
        if let known = read[key] { return known }
        if !reading.contains(key) {
            reading.insert(key)
            Task {
                if let found = try? await WKWebExtension(resourceBaseURL: Extensions.folder(for: item.id)) { read[key] = found }
            }
        }
        return nil
    }

    /// Every switched-off one read ahead, so the first look — or the
    /// bench's picture — doesn't come before its icon.
    func warm(_ extensions: Extensions) {
        for item in extensions.installed where extensions.contexts[item.id] == nil { _ = of(item, in: extensions) }
    }
}

// MARK: - the page

/// Settings › Extensions drawn off screen at the page's width, laid out
/// whole — for the bench, which gets every row this way rather than the top
/// of a scroll.
enum ExtensionsPicture {
    @MainActor
    static func draw(of browser: Browser, dark: Bool? = nil) -> NSBitmapImageRep? {
        guard #available(macOS 15.4, *) else { return nil }
        let dark = dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        return SettingsPicture.draw(ExtensionsSettings(browser: browser, extensions: .shared), dark: dark)
    }
}

/// The page itself, inside Settings' own scroll.
@available(macOS 15.4, *)
struct ExtensionsSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var extensions: Extensions

    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var facts = ExtensionFacts.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var hunting: Bool
    @State private var link = ""

    /// The column's own colour on the header's tile, as Settings › Spaces wears it.
    private var tint: SpaceTint { SpaceTint(space: Spaces.shared.space, dark: scheme == .dark).offColumn }

    /// Installed ones matching the filter — by name, id or what they say
    /// they do — in the order they were added, the pill's order.
    private var shown: [Installed] {
        let words = manager.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return extensions.installed }
        return extensions.installed.filter { item in
            let about = facts.of(item, in: extensions)?.displayDescription ?? ""
            return [item.name, item.id, about].contains { $0.lowercased().contains(words) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tools
                .settingsAnchor("extensions.tools") // Fork (settings-revamp): search anchors
            list
                .settingsAnchor("extensions.list")
            adder
                .settingsAnchor("extensions.adder", card: true)
        }
        .onAppear { facts.warm(extensions) }
    }

    /// What is installed, in a line, beside the puzzle piece.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint.mark)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.ground))
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        let all = extensions.installed
        guard !all.isEmpty else { return "None installed yet" }
        let on = all.filter(\.enabled).count
        let pinned = all.filter { $0.pinned == true }.count
        var parts = ["\(all.count) installed", "\(on) on"]
        if pinned > 0 { parts.append("\(pinned) in the address bar") }
        return parts.joined(separator: " · ")
    }

    /// The filter, and the two ways to get more. The filter only once
    /// there is something to filter; beside the two ways in when the page
    /// has the width, over them when it hasn't — squeezed, its prompt broke
    /// onto three lines.
    @ViewBuilder
    private var tools: some View {
        if extensions.installed.isEmpty {
            HStack(spacing: 8) { ways }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Hunt(text: $manager.query, prompt: "Search extensions", focus: $hunting)
                        .frame(minWidth: 180)
                    ways
                }
                VStack(alignment: .leading, spacing: 8) {
                    Hunt(text: $manager.query, prompt: "Search extensions", focus: $hunting)
                    HStack(spacing: 8) { ways }
                }
            }
        }
    }

    @ViewBuilder
    private var ways: some View {
        Pill("Chrome Web Store") {
            manager.close()
            browser.open(Browser.webStore, foreground: true)
        }
        Pill("Load Unpacked…") {
            DispatchQueue.main.async { extensions.installFolder() }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            let rows = shown
            if extensions.installed.isEmpty {
                Card {
                    Line("Add your first extension", "Find one in the Chrome Web Store and press Add to \(Fork.name) on its page, paste its link below, or load a folder with a manifest.json.") { EmptyView() }
                }
            } else if rows.isEmpty {
                Card { Nothing("Nothing matches “\(manager.query)”.") }
            }
            ForEach(rows) { item in
                ExtensionCardRow(item: item, extensions: extensions, browser: browser)
                    .id(item.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A store link or an id straight in, as Settings always took it.
    private var adder: some View {
        Card {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if link.isEmpty {
                        Text("Paste a Chrome Web Store link or an id").foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    TextField("", text: $link)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .onSubmit(add)
                        .accessibilityLabel("Chrome Web Store link or id")
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .settingsField(radius: 8) // SB-04: the ink edge while the keyboard is in it
                if extensions.busy != nil {
                    Ring(size: 12)
                } else {
                    Pill("Add", action: add).disabled(Crx.id(in: link) == nil)
                }
            }
            .padding(12)
        }
    }

    private func add() {
        guard Crx.id(in: link) != nil else { return }
        extensions.install(from: link)
        link = ""
    }
}

// MARK: - one extension

@available(macOS 15.4, *)
private struct ExtensionCardRow: View {
    let item: Installed
    @ObservedObject var extensions: Extensions
    @ObservedObject var browser: Browser
    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var facts = ExtensionFacts.shared
    /// The view the popup hangs from when it is opened from here.
    @State private var spot = ExtensionPopupSpot()

    private var context: WKWebExtensionContext? { extensions.contexts[item.id] }
    private var found: WKWebExtension? { facts.of(item, in: extensions) }
    private var open: Bool { manager.expanded == item.id }

    /// Every complaint in one list: the manifest's, WebKit's about running
    /// it, and what its pages and worker reported. The same words once.
    private var problems: [String] {
        _ = manager.changed
        var seen = Set<String>(), out: [String] = []
        let all = (found?.errors ?? []).map(\.localizedDescription)
            + (context?.errors ?? []).map(\.localizedDescription)
            + (extensions.errors[item.id] ?? [])
        for text in all where seen.insert(text).inserted { out.append(text) }
        if item.enabled, context == nil { out.insert("It is on, but WebKit couldn't start it.", at: 0) }
        return out
    }

    var body: some View {
        Card {
            summary
            if open {
                Rule(inset: 0)
                ExtensionDetails(item: item, extensions: extensions, browser: browser, problems: problems, spot: spot)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: open)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                // The name, then its version and tags beside it — or under it
                // when the card is narrow, where they left the name a word
                // and an ellipsis.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        name.lineLimit(1)
                        badges
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        name.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) { badges }
                    }
                }
                // On one line of prose: some carry a build note after a
                // blank line (React's does), which would take the second line.
                Text(found?.displayDescription.map(ExtensionCardRow.prose) ?? (item.fromStore ? "From the Chrome Web Store" : "Loaded from a folder"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Each pill one line, and onto a second line when the card is
                // narrow: in one fixed row they ran past Settings' narrowest
                // page and pushed the switch off its edge.
                SettingsFlow(spacing: 6) {
                    Quick(open ? "Hide Details" : "Details") {
                        withAnimation(Motion.settle) { manager.expanded = open ? nil : item.id }
                    }
                    .accessibilityLabel(open ? "Hide details of \(item.name)" : "Details of \(item.name)")
                    if context?.optionsPageURL != nil {
                        Quick("Options") { manager.close(); extensions.openOptions(item.id) }
                            .accessibilityLabel("Options of \(item.name)")
                    }
                    Quick("Reload") { extensions.reload(item.id) }
                        .accessibilityLabel("Reload \(item.name)")
                    Quick("Remove", tint: .red.opacity(0.8)) { ExtensionRemoval.ask(item.id, name: item.name, icon: found?.icon(for: CGSize(width: 64, height: 64))) }
                        .accessibilityLabel("Remove \(item.name)")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                ExtensionPin(on: item.pinned == true, usable: context?.action(for: extensions.activeAdapter) != nil) {
                    extensions.setPinned(item.id, item.pinned != true)
                }
                Switch(on: Binding(get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }), label: item.name)
                    .help(item.enabled ? "On — switch off" : "Off — switch on")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .contentShape(Rectangle())
        .contextMenu {
            Button(open ? "Hide Details" : "Details") { manager.expanded = open ? nil : item.id }
            Button(item.pinned == true ? "Unpin" : "Pin to Toolbar") { extensions.setPinned(item.id, item.pinned != true) }
            Button(item.enabled ? "Turn Off" : "Turn On") { extensions.setEnabled(item.id, !item.enabled) }
        }
    }

    private var name: some View {
        Text(item.name)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(item.enabled ? Palette.ink : Palette.muted)
    }

    /// Its version, and the tags beside it.
    @ViewBuilder
    private var badges: some View {
        Text(found?.displayVersion ?? item.version)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
        if !item.fromStore { ExtensionTag("Unpacked") }
        if !problems.isEmpty { ExtensionTag("\(problems.count) error\(problems.count == 1 ? "" : "s")", warn: true) }
    }

    static func prose(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var icon: some View {
        Group {
            if let image = found?.icon(for: CGSize(width: 64, height: 64)) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Text(item.name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash))
            }
        }
        .frame(width: 36, height: 36)
        .saturation(item.enabled ? 1 : 0)
        .opacity(item.enabled ? 1 : 0.55)
    }
}

/// What an extension's page says when it is opened out.
@available(macOS 15.4, *)
private struct ExtensionDetails: View {
    let item: Installed
    @ObservedObject var extensions: Extensions
    @ObservedObject var browser: Browser
    let problems: [String]
    let spot: ExtensionPopupSpot
    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var facts = ExtensionFacts.shared

    /// The card is too narrow to indent the details under the name.
    @State private var narrow = false

    private var context: WKWebExtensionContext? { extensions.contexts[item.id] }
    private var found: WKWebExtension? { facts.of(item, in: extensions) }

    var body: some View {
        let _ = manager.changed
        VStack(alignment: .leading, spacing: 16) {
            if let context, item.enabled, let action = context.action(for: extensions.activeAdapter) {
                section("Button") {
                    HStack(spacing: 8) {
                        Pill(action.presentsPopup || Extensions.popupURL(for: context) != nil ? "Open Popup" : "Press") {
                            extensions.anchors[item.id] = WeakView(spot.view)
                            extensions.press(item.id)
                        }
                        .background(ExtensionPopupSpot.Holder(spot: spot))
                        Text(item.pinned == true ? "Pinned beside the address — shows under the pointer." : "In the puzzle list; pin it to keep it beside the address.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            if OnePasswordExtension.ids.contains(item.id), context != nil, item.enabled { onePassword }
            sites
            permissions
            if let commands = context?.commands, !commands.isEmpty { shortcuts(commands) }
            if context?.overrideNewTabPageURL != nil { newTabs }
            section("Shy tabs") {
                note("Never. \(Fork.name) keeps every extension out of shy tabs — they can't see them, their pages or their cookies.")
            }
            source
            if !problems.isEmpty { errors }
            about
        }
        // Under the name, past the icon — unless the card is narrow, where
        // that indent left the details a sliver and slid the page sideways.
        .padding(.horizontal, narrow ? 14 : 62)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < 460 } action: { narrow = $0 }
    }

    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.8))
                if let trailing {
                    Spacer(minLength: 6)
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 1Password

    /// Its two ways in (`OnePasswordExtension`): signed in by itself, or
    /// through the 1Password app once the app allows Copper.
    @ObservedObject private var onePasswordLink = OnePasswordExtension.shared

    private var onePassword: some View {
        section("1Password") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Pill("Sign In…", filled: true) { manager.close(); OnePasswordExtension.shared.signIn(in: browser) }
                    note("Email, Secret Key and password on 1Password's own page — the extension then unlocks with your password.")
                }
                HStack(spacing: 8) {
                    Pill(onePasswordLink.asking == .asking ? "Waiting for 1Password…" : "Use the 1Password App…") {
                        OnePasswordExtension.shared.connect(item.id)
                    }
                    .disabled(onePasswordLink.asking == .asking)
                    note(onePasswordAppLine)
                }
            }
        }
    }

    private var onePasswordAppLine: String {
        switch onePasswordLink.asking {
        case .idle, .asking: return "Touch ID through the app. 1Password asks in its own window whether to allow \(Fork.name)."
        case .allowed: return "1Password allowed \(Fork.name). The extension connects to the app from now on."
        case .refused(let why): return why
        }
    }

    // MARK: site access

    /// The sites it asked for, each on or off. Taking one away lasts past a
    /// relaunch (`applySiteChoices`); a page already open keeps what was
    /// injected into it until it reloads.
    @ViewBuilder
    private var sites: some View {
        let asked = (found?.allRequestedMatchPatterns ?? []).sorted { $0.string < $1.string }
        let extra = context.map { context in
            context.grantedPermissionMatchPatterns.keys.filter { !asked.contains($0) }.sorted { $0.string < $1.string }
        } ?? []
        section("Site access", trailing: siteSummary(asked)) {
            if asked.isEmpty && extra.isEmpty {
                note("It doesn't ask to read or change any website — only the page you press its button on, if that.")
            } else {
                VStack(spacing: 0) {
                    // `<all_urls>`, `*://*/*`, `http://*/*`… are one choice to a
                    // person, so they are one switch.
                    let every = asked.filter { $0.matchesAllHosts || $0.matchesAllURLs }
                    if !every.isEmpty {
                        let on = every.contains(where: allowed)
                        row("Every website", detail: every.map(\.string).joined(separator: "  ")) {
                            Switch(on: Binding(get: { on }, set: { value in
                                for pattern in every { extensions.setSite(pattern, allowed: value, for: item.id) }
                            }), label: "Every website")
                            .disabled(context == nil)
                            .opacity(context == nil ? 0.5 : 1)
                        }
                    }
                    ForEach(asked.filter { !($0.matchesAllHosts || $0.matchesAllURLs) }, id: \.string) { pattern in
                        let allowed = allowed(pattern)
                        row(Extensions.site(pattern), detail: pattern.string == Extensions.site(pattern) ? nil : pattern.string) {
                            Switch(on: Binding(get: { allowed }, set: { extensions.setSite(pattern, allowed: $0, for: item.id) }), label: Extensions.site(pattern))
                                .disabled(context == nil)
                                .opacity(context == nil ? 0.5 : 1)
                        }
                    }
                    // Granted later, when it asked and was told yes.
                    ForEach(extra, id: \.string) { pattern in
                        row(Extensions.site(pattern), detail: "Allowed when it asked") {
                            Quick("Revoke", tint: .red.opacity(0.8)) {
                                context?.grantedPermissionMatchPatterns.removeValue(forKey: pattern)
                                manager.noteChange()
                            }
                        }
                    }
                }
                .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                if context == nil { note("Switch it on to change these.") }
            }
        }
    }

    private func allowed(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        guard let context else { return !Extensions.deniedSites(item.id).contains(pattern.string) }
        return context.permissionStatus(for: pattern).rawValue >= WKWebExtensionContext.PermissionStatus.grantedImplicitly.rawValue
    }

    private func siteSummary(_ asked: [WKWebExtension.MatchPattern]) -> String? {
        guard !asked.isEmpty else { return nil }
        let on = asked.filter(allowed).count
        if on == 0 { return "none allowed" }
        if asked.contains(where: { ($0.matchesAllHosts || $0.matchesAllURLs) && allowed($0) }) { return "every website" }
        return on == asked.count ? "all \(on) allowed" : "\(on) of \(asked.count) allowed"
    }

    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: permissions

    /// What it may do, in words, then by name. What it was installed with
    /// can't be taken back short of removing it — Chrome's rule too; what it
    /// was given later, when it asked, can.
    @ViewBuilder
    private var permissions: some View {
        let words = found.map { Extensions.describe($0, in: Extensions.folder(for: item.id)) } ?? []
        let added = Extensions.added(item.id)
        let names = (found?.requestedPermissions ?? []).map(\.rawValue).filter { !added.contains($0) }.sorted()
        let optional = (found?.optionalPermissions ?? []).map(\.rawValue).sorted()
        let requested = found?.requestedPermissions ?? []
        let later = (context.map { Array($0.grantedPermissions.keys) } ?? [])
            .filter { !requested.contains($0) && $0 != .nativeMessaging }
            .sorted { $0.rawValue < $1.rawValue }
        let ours = Store.settings.stringArray(forKey: "extensions.granted.\(item.id)") ?? []
        section("Permissions", trailing: names.isEmpty ? nil : "\(names.count) at install") {
            VStack(alignment: .leading, spacing: 8) {
                if words.isEmpty && names.isEmpty {
                    note("It doesn't ask for anything special.")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(words, id: \.self) { sentence in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(Palette.muted)
                                Text(sentence).foregroundStyle(Palette.ink)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    if !names.isEmpty { PermissionChips(names: names) }
                }
                if !later.isEmpty || !ours.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(later, id: \.rawValue) { permission in
                            row(permission.rawValue, detail: "Allowed when it asked") {
                                Quick("Revoke", tint: .red.opacity(0.8)) {
                                    context?.grantedPermissions.removeValue(forKey: permission)
                                    manager.noteChange()
                                }
                            }
                        }
                        ForEach(ours, id: \.self) { name in
                            row(name, detail: "Allowed when it asked") {
                                Quick("Revoke", tint: .red.opacity(0.8)) {
                                    Store.settings.set(ours.filter { $0 != name }, forKey: "extensions.granted.\(item.id)")
                                    manager.noteChange()
                                }
                            }
                        }
                    }
                    .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                if !optional.isEmpty {
                    note("It may ask later for: " + optional.joined(separator: ", ") + ".")
                }
            }
        }
    }

    // MARK: the rest

    /// The keys it registered. Shown, not changed: WebKit takes them from the
    /// manifest each time it loads, and there is nowhere to keep another.
    private func shortcuts(_ commands: [WKWebExtension.Command]) -> some View {
        section("Keyboard shortcuts") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(commands, id: \.id) { command in
                    HStack {
                        Text(command.title.isEmpty ? command.id : command.title).font(.system(size: 12)).foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        Text(ExtensionDetails.keys(command) ?? "Not set")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(ExtensionDetails.keys(command) == nil ? Palette.muted : Palette.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
    }

    static func keys(_ command: WKWebExtension.Command) -> String? {
        guard let key = command.activationKey, !key.isEmpty else { return nil }
        let flags = command.modifierFlags
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + key.uppercased()
    }

    private var newTabs: some View {
        let key = "extensions.newtab.\(item.id)"
        return section("New tabs") {
            HStack {
                note("It asks to show its own page in new tabs.")
                Spacer(minLength: 8)
                Switch(on: Binding(get: { Store.settings.object(forKey: key) as? Bool == true }, set: {
                    Store.settings.set($0, forKey: key)
                    extensions.objectWillChange.send()
                }), label: "Its page in new tabs")
            }
        }
    }

    @ViewBuilder
    private var source: some View {
        if let path = item.source {
            section("Loaded from") {
                HStack(spacing: 8) {
                    Text(path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Pill("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
                    }
                }
                note("Reload copies it in again from this folder, so what you saved there is what runs.")
            }
        } else if item.fromStore {
            section("Source") {
                HStack {
                    note("The Chrome Web Store. \(Fork.name) checks it for updates once a day.")
                    Spacer(minLength: 8)
                    Pill("View in Store") {
                        manager.close()
                        if let url = URL(string: "https://chromewebstore.google.com/detail/\(item.id)") { browser.open(url, foreground: true) }
                    }
                }
            }
        } else {
            section("Source") { note("A folder, copied in when it was loaded.") }
        }
    }

    private var errors: some View {
        section("Errors", trailing: "Reload clears them") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(problems.suffix(12).enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        Text(text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    /// The small print: its id and what it is made of.
    private var about: some View {
        var parts: [String] = []
        if let found {
            parts.append("Manifest v\(Int(found.manifestVersion))")
            if found.hasPersistentBackgroundContent { parts.append("background page") }
            else if found.hasBackgroundContent { parts.append("service worker") }
            if found.hasInjectedContent { parts.append("runs scripts in pages") }
            if found.hasContentModificationRules { parts.append("blocks or changes requests") }
        }
        if item.enabled, context != nil { parts.append("running") } else if !item.enabled { parts.append("off") }
        return section("About") {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("ID").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    Text(item.id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.ink).textSelection(.enabled)
                }
                if !parts.isEmpty { note(parts.joined(separator: " · ")) }
            }
        }
    }
}

// MARK: - small parts

/// A word in a capsule beside the name — Unpacked, 2 errors.
private struct ExtensionTag: View {
    let text: String
    var warn = false
    init(_ text: String, warn: Bool = false) { self.text = text; self.warn = warn }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(warn ? Color.orange : Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background((warn ? Color.orange.opacity(0.12) : Palette.wash), in: Capsule())
    }
}

/// Permission names as small chips, wrapping.
private struct PermissionChips: View {
    let names: [String]
    var body: some View {
        Wrap(spacing: 4) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    /// Left to right, then onto the next line.
    private struct Wrap: Layout {
        var spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 480
            var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
                x += size.width + spacing
                line = max(line, size.height)
            }
            return CGSize(width: width, height: y + line)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
                view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
                line = max(line, size.height)
            }
        }
    }
}

/// Pinned beside the address, or not. Greyed for one with no button to pin.
private struct ExtensionPin: View {
    let on: Bool
    let usable: Bool
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: on ? "pin.fill" : "pin")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Palette.wash : (hovering ? Palette.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!usable && !on)
        .opacity(usable || on ? 1 : 0.4)
        .help(on ? "Pinned beside the address — click to unpin" : (usable ? "Pin beside the address" : "It has no button to pin"))
    }
}

/// A real view under the popup button, so a popup opened from the page has
/// something to hang from. Kept in a box the row holds, since the press
/// needs the view and the view is only made when SwiftUI makes it.
private final class ExtensionPopupSpot {
    var view = NSView()

    struct Holder: NSViewRepresentable {
        let spot: ExtensionPopupSpot
        func makeNSView(context: Context) -> NSView { spot.view }
        func updateNSView(_ view: NSView, context: Context) {}
    }
}

/// Removing asks first, as a sheet on the window — the page stays up under
/// it, and Cancel goes back to it.
@available(macOS 15.4, *)
@MainActor
enum ExtensionRemoval {
    /// The sheet while it is up, so the bench can answer it.
    private(set) static var asking: NSAlert?

    static func ask(_ id: String, name: String, icon: NSImage?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its settings and data go with it."
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            asking = nil
            guard response == .alertFirstButtonReturn else { return }
            if ExtensionManager.shared.expanded == id { ExtensionManager.shared.expanded = nil }
            Extensions.shared.remove(id)
        }
        asking = alert
        // A sheet on the window — or, in a test run, a question the bench
        // can answer too (X-13).
        TestConfirm.present(alert, kind: "extensions.remove", window: Links.window, decide: decide)
    }

    /// `bench ext-manager answer remove|cancel`.
    static func answer(_ remove: Bool) -> Bool {
        guard let alert = asking else { return false }
        if TestConfirm.holds { return TestConfirm.answer(remove ? "1" : "2")["answered"] != nil }
        alert.buttons[remove ? 0 : 1].performClick(nil)
        return true
    }
}

@available(macOS 15.4, *)
extension Extensions {
    /// What Copper itself added to an extension's manifest, left out of what
    /// the page says it asked for.
    static func added(_ id: String) -> Set<String> {
        let file = folder(for: id).appendingPathComponent(".search-added")
        return Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String] ?? [])
    }

    /// A match pattern as a person reads it: `*://*.github.com/*` is
    /// github.com and its subdomains; `<all_urls>` is every website.
    static func site(_ pattern: WKWebExtension.MatchPattern) -> String {
        if pattern.matchesAllURLs || pattern.matchesAllHosts { return "Every website" }
        guard let host = pattern.host, !host.isEmpty else { return pattern.string }
        return host.hasPrefix("*.") ? String(host.dropFirst(2)) + " and its subdomains" : host
    }
}

// MARK: - the bench

extension ExtensionManager {
    /// `bench ext-manager [open [ID]|close|toggle|manage|expand ID|none|search TEXT|picture PATH [light|dark]
    /// |site ID PATTERN on|off|remove ID|answer remove|cancel]`.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        guard #available(macOS 15.4, *) else { return ["error": "extensions need macOS 15.4"] }
        let op = request["op"] as? String ?? "status"
        let arg = request["arg"] as? String ?? ""
        let words = arg.split(separator: " ").map(String.init)
        let extensions = Extensions.shared
        switch op {
        case "open": open(arg.isEmpty ? nil : arg, in: browser)
        case "close": close()
        case "toggle": toggle(in: browser)
        // What the pill's puzzle piece and every "Manage Extensions…" call.
        case "manage": browser.openSettings(.extensions)
        case "expand": expanded = arg.isEmpty || arg == "none" ? nil : arg
        case "search": query = arg
        case "picture":
            guard let path = words.first else { return ["error": "ext-manager picture needs a path"] }
            let dark = words.count > 1 ? words[1] == "dark" : nil
            ExtensionFacts.shared.warm(extensions)
            guard let png = ExtensionsPicture.draw(of: browser, dark: dark)?.representation(using: .png, properties: [:]) else {
                return ["error": "couldn't draw the page"]
            }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": error.localizedDescription] }
            return ["path": path]
        case "site":
            guard words.count == 3, let pattern = try? WKWebExtension.MatchPattern(string: words[1]) else {
                return ["error": "ext-manager site ID PATTERN on|off"]
            }
            extensions.setSite(pattern, allowed: words[2] == "on", for: words[0])
        case "remove":
            guard let item = extensions.installed.first(where: { $0.id == arg }) else { return ["error": "no extension \(arg)"] }
            ExtensionRemoval.ask(item.id, name: item.name, icon: nil)
            return ["asking": "Remove “\(item.name)”?"]
        case "answer":
            guard ExtensionRemoval.answer(arg == "remove") else { return ["error": "no sheet is up"] }
        case "onepassword": return OnePasswordExtension.shared.bench(words, in: browser)
        case "status", "list": break
        default: return ["error": "unknown ext-manager op \(op)"]
        }
        return ["showing": showing, "expanded": expanded ?? "", "query": query, "extensions": extensions.installed.map { item -> [String: Any] in
            let context = extensions.contexts[item.id]
            let asked = context?.webExtension.allRequestedMatchPatterns.sorted { $0.string < $1.string } ?? []
            return [
                "id": item.id, "name": item.name, "enabled": item.enabled, "pinned": item.pinned ?? false,
                "sites": asked.map { ["pattern": $0.string, "allowed": (context?.permissionStatus(for: $0).rawValue ?? 0) >= 2] },
                "denied": Extensions.deniedSites(item.id).sorted(),
                "commands": (context?.commands ?? []).map { command in ExtensionDetails.keys(command).map { "\($0) \(command.title)" } ?? command.title },
            ]
        }]
    }
}
