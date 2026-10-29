import SwiftUI

/// Everything there is to set. Pages down the left in four groups under a
/// search field, one page at a time on the right: its title and what it is
/// for, then titled sections of lines — what it is, a plain sentence, the
/// control at the right. The panel takes the room the window gives it.
///
/// Fork (settings-revamp): sized to the window, grouped rail, page headers,
/// sections, and search over every setting (`Fork/SettingsSearch.swift`,
/// `Fork/SettingsIndex.swift`, `Fork/SettingsSearchUI.swift`,
/// `Fork/SettingsLook.swift`). Every setting, storage key and behaviour is
/// the same as before; only where it is drawn changed.
struct SettingsPanel: View {
    /// Fork (settings-perf): not observed. The browser publishes for every
    /// tab, find, hover and announcement; watching it redrew the whole panel
    /// each time. Only the page matters here, kept below via `onReceive`.
    let browser: Browser
    @ObservedObject var prefs: Preferences

    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = SettingsDefaultBrowser.isDefault // Fork (settings-perf): one LaunchServices ask per opening, not per redraw
    /// Fork (settings-revamp): the panel's own width, for the rail's.
    @State private var width: CGFloat = 900
    /// Fork (settings-revamp): the page has scrolled under its header.
    /// Fork (settings-perf): an object only the header's hairline watches,
    /// so crossing the edge redraws the hairline rather than the panel.
    /// (Held in `@State`, not `@StateObject`, which would redraw the panel
    /// on every change of it all the same.)
    @State private var edge = SettingsScrollEdge()
    @Environment(\.accessibilityReduceMotion) private var still

    /// Fork (settings-revamp): this window's search, observed so the rail,
    /// the header and the results follow the query.
    @ObservedObject private var finder: SettingsFinder

    init(browser: Browser, prefs: Preferences) {
        self.browser = browser
        self.prefs = prefs
        self._finder = ObservedObject(wrappedValue: SettingsFinder.of(browser))
        self._page = State(initialValue: browser.settingsPage) // Fork (settings-perf)
    }

    enum Page: String, CaseIterable, Identifiable {
        case general, tabs, spaces, intelligence, agents, cloud, extensions, passwords, privacy, about // Fork: spaces, intelligence, agents, cloud (settings-merge: downloads → General, labs → Tabs, voice → Intelligence, addons → Extensions, updates → About)
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .tabs: return "Tabs"
            case .spaces: return "Spaces" // Fork
            case .intelligence: return "Intelligence" // Fork
            case .agents: return "Agents" // Fork
            case .cloud: return "Cloud" // Fork
            case .extensions: return "Extensions"
            case .passwords: return "Passwords"
            case .privacy: return "Privacy"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .tabs: return "rectangle.split.3x1"
            case .spaces: return "square.stack" // Fork
            case .intelligence: return "sparkles" // Fork
            case .agents: return "cpu" // Fork
            case .cloud: return "icloud" // Fork
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .privacy: return "hand.raised"
            case .about: return "info.circle"
            }
        }
    }

    /// Fork (settings-revamp): as big as reads well, never past the window.
    static func span(_ length: CGFloat, most: CGFloat, least: CGFloat) -> CGFloat {
        min(most, max(min(least, length - 24), length - 80))
    }

    private var rail: CGFloat { width < 760 ? 190 : 220 }

    @State private var page: Page = .general // Fork (settings-perf): mirrors browser.settingsPage

    var body: some View {
        let _ = SettingsPerf.tick("panel") // Fork (settings-perf)
        HStack(spacing: 0) {
            pages(finder)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content(finder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerRelativeFrame(.horizontal) { length, _ in SettingsPanel.span(length, most: 920, least: 600) }
        .containerRelativeFrame(.vertical) { length, _ in SettingsPanel.span(length, most: 700, least: 440) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(SettingsInk.content, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Fork (settings-perf): the shadow is cast by a plain shape behind the
        // panel. A `.shadow` on the panel itself is drawn from its content, so
        // every scrolled frame, hover and keystroke re-blurred all 920 × 700 pt
        // of it offscreen — the lag. The shape never changes, so its shadow is
        // drawn once.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SettingsInk.content)
                .shadow(color: .black.opacity(0.18), radius: 40, y: 14)
        )
        .environment(\.settingsLook, true)
        .onAppear {
            finder.opened()
            Task { await Bitwarden.shared.refreshStatus() }
            CloudIntelligence.shared.settingsOpened() // Fork (cloud-intelligence)
        }
        .onReceive(browser.$settingsPage.removeDuplicates()) { now in // Fork (settings-perf)
            guard now != page else { return }
            page = now
            Store.settings.set(now.rawValue, forKey: "settings.page")
            edge.scrolled = false
        }
        .onDisappear { SettingsDefaultBrowser.forget() } // Fork (settings-perf)
        // Fork (settings-browse): opened again before the last close had
        // faded, the panel is the same view, so onAppear doesn't come round —
        // start fresh all the same, not on the old query.
        .onReceive(browser.$tuning.removeDuplicates().dropFirst().filter { $0 }) { _ in finder.opened() }
    }

    // MARK: - the rail

    private func pages(_ finder: SettingsFinder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 6)
                .padding(.top, 20)
                .padding(.bottom, 12)
            SettingsSearchField(finder: finder)
                .padding(.bottom, 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Page.Group.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.rawValue)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SettingsInk.detail)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                            ForEach(Page.railOrder.filter { $0.group == group }) { item in
                                SettingsRailRow(
                                    page: item,
                                    on: page == item && !finder.showingResults,
                                    count: finder.searching ? (finder.counts[item] ?? 0) : nil
                                ) {
                                    finder.leaveResults()
                                    browser.settingsPage = item
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, SettingsRailFade.height) // Fork (settings-browse): was 14; room for the fade
            }
            .mask(SettingsRailFade()) // Fork (settings-browse): a soft lower edge says there is more below
        }
        .padding(.horizontal, 12)
        .frame(width: rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsInk.rail)
    }

    // MARK: - the page

    private func content(_ finder: SettingsFinder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if finder.showingResults {
                    SettingsHeader(title: "Search", blurb: resultsLine(finder)) { close }
                } else {
                    SettingsHeader(title: page.title, blurb: page.blurb) { close }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 16)
            SettingsHeaderRule(edge: edge, hidden: finder.showingResults) // Fork (settings-perf): Fork/SettingsLook.swift
            if finder.showingResults {
                SettingsResults(finder: finder, browser: browser)
            } else {
                scroll(finder)
                    .id(page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.settingsFlash, finder.flashing)
    }

    private var close: some View {
        Door(icon: "xmark", help: "Close  ⎋") { browser.tuning = false } // Fork (settings-a11y): ⎋ as everywhere else in Copper
            .accessibilityLabel("Close Settings") // Fork (settings-a11y)
    }

    private func resultsLine(_ finder: SettingsFinder) -> String {
        let shown = finder.query.trimmingCharacters(in: .whitespaces)
        let n = finder.results.count
        if n == 0 { return "Every page searched" }
        let pages = finder.groups.count
        return "\(n) result\(n == 1 ? "" : "s") for “\(shown)”" + (pages > 1 ? " on \(pages) pages" : "") + "  ·  ↑↓ to choose, ↩ to go"
    }

    private func scroll(_ finder: SettingsFinder) -> some View {
        let page = page
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).settingsAnchor(page.topAnchor)
                    VStack(alignment: .leading, spacing: 26) {
                        switch page {
                        case .general: general
                        case .tabs: tabs
                        case .spaces: SpacesSettingsPage(browser: browser) // Fork
                        case .intelligence:
                            IntelligencePage(browser: browser) // Fork
                            VoicePage(browser: browser) // Fork (settings-merge): Fork/Voice/VoiceSettings.swift
                        case .agents: AgentsPage(browser: browser) // Fork
                        case .cloud: CloudPage(browser: browser) // Fork
                        case .extensions:
                            ExtensionsPage(browser: browser)
                            AddonsPage(browser: browser) // Fork (settings-merge): Fork/Addons/AddonUI.swift
                        case .passwords: passwords
                        case .privacy: privacy
                        case .about: about
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 4)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .environment(\.settingsPageName, page.rawValue) // Fork (settings-a11y): the bench's control ledger
                .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < -2 } action: { now in
                    if edge.scrolled != now { edge.scrolled = now }
                }
            }
            .onPreferenceChange(SettingsAnchorsKey.self) { finder.drawn[page] = $0 }
            .task(id: finder.pending?.token) {
                guard let target = finder.pending else { return }
                // The page draws first, and says which anchors it has.
                try? await Task.sleep(nanoseconds: 140_000_000)
                let anchor = finder.resolve(target, on: page)
                let spot = target.flash ? UnitPoint(x: 0.5, y: 0.22) : UnitPoint.top
                withAnimation(still || !SettingsAnchor.glides ? nil : Motion.glide) { // Fork (settings-a11y): no glide where no one sees it
                    if let anchor { SettingsAnchor.land(proxy, on: anchor, spot: spot) } // Fork (settings-a11y): a card lands by its top edge
                    // A card another build marks with a plain `.id` still
                    // scrolls into view, even though the index check can't see it.
                    if anchor != target.anchor { proxy.scrollTo(target.anchor, anchor: spot) }
                }
                finder.landed(target, on: anchor)
            }
        }
    }

    // MARK: - general

    private var general: some View {
        Group {
            SettingsSection("Copper on this Mac") {
                Line(
                    "Open links from other apps",
                    isDefault ? "Copper is the default browser on this Mac"
                        : Links.refusesDefault ? "Not in a test run — links stay with the browser you use" // Fork (default-guard)
                        : "Mail, Slack and the rest still send links elsewhere"
                ) {
                    if isDefault {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 24)
                    } else {
                        Pill("Make default", filled: true) {
                            Links.becomeDefault { worked in
                                isDefault = Links.isDefault
                                browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                            }
                        }
                        .disabled(Links.refusesDefault) // Fork (default-guard): Links.becomeDefault refuses too
                    }
                }
                .settingsAnchor("general.default")
                Rule()
                Line("Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too") {
                    Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
                }
                .settingsAnchor("general.appearance")
                Rule()
                Line("Correct spelling as you type", "macOS's autocorrect inside pages — the one that capitalises for you") {
                    Switch(on: $prefs.autocorrect)
                }
                .settingsAnchor("general.autocorrect")
            }
            downloads // Fork (settings-merge): was its own page
            SettingsSection("Moving in") {
                FlowSettingsLine(browser: browser)
                    .settingsAnchor("general.flow")
                Rule()
                HistorySettingsLine(browser: browser)
                    .settingsAnchor("general.history")
            }
            SettingsSection("Developer") {
                Line("Let a script drive Copper", "A local socket for testing; its tabs carry a flask — see ./bench") {
                    Switch(on: $prefs.bench)
                }
                .settingsAnchor("general.bench")
            }
        }
    }

    // MARK: - tabs

    private var tabs: some View {
        Group {
            SettingsSection("Layout") {
                Line("Tabs in a sidebar", "Down the left instead of across the top. Drag its edge to resize.") { // Fork (settings-browse): copy
                    Switch(on: Binding(
                        get: { prefs.sidebar },
                        set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                    ))
                }
                .settingsAnchor("tabs.sidebar")
                Rule()
                // Fork (settings-browse): the sidebar honours it too (Side.swift).
                Line("Tabs show", "Beside the title, and on a pinned square") {
                    Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
                }
                .settingsAnchor("tabs.glyph")
            }
            SettingsSection("Switching") {
                Line("⌃Tab switches to", "The next tab in the row, or the one you used last") {
                    Segmented(options: TabSwitching.allCases.map { ($0, $0.title) }, selection: $prefs.tabSwitching)
                }
                .settingsAnchor("tabs.switching")
                // Fork (swipe-direction): here rather than on the Spaces page,
                // which is the editor for one space at a time; this is how the
                // column itself answers the trackpad, like ⌃Tab above it.
                // Fork (settings-merge): only with the sidebar — the swipe
                // lives over its column, so with the strip there is nothing to set.
                if prefs.sidebar {
                    Rule()
                    Line("Swipe between spaces", "Two fingers across the sidebar. Natural moves it with your fingers, Inverted the other way; Like scrolling follows the Mac's own setting.") {
                        Segmented(options: SwipeDirection.allCases.map { ($0, $0.title) }, selection: $prefs.swipeDirection)
                    }
                    .settingsAnchor("tabs.swipe")
                }
            }
            SettingsSection("Tabs you leave") {
                Line("Sleep tabs you aren't using",  "When many pages are open or memory runs short, the tabs you left longest sleep and come back where you were. Pinned tabs, sound, calls and anything typed stay awake.") {
                    Switch(on: $prefs.sleepsTabs)
                }
                .settingsAnchor("tabs.sleep")
                Rule()
                ArchiveLine() // Fork: sections
                    .settingsAnchor("tabs.archive")
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Copper not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        Group {
            SettingsSection("Saved passwords") {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID — bring yours in from Dia, Chrome, Arc, Brave or Edge there") { // Fork (settings-merge): was also an Import… row that opened the same window
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                .settingsAnchor("passwords.list")
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                .settingsAnchor("passwords.save")
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                .settingsAnchor("passwords.fill")
                Rule()
                // Fork (auto-codes): Fork/Credentials/KeychainCodes.swift keeps the keychain's keys
                Line("Fill two-step codes", "Right after you pick an account whose code Copper keeps, the code page fills itself") {
                    Switch(on: $prefs.fillsCodes)
                }
                .settingsAnchor("passwords.codes")
                Rule()
                Line("Fill addresses and cards", "Click into a checkout or address form and your Bitwarden and 1Password identities and cards hang from it") { // Fork: 1Password
                    Switch(on: $prefs.fillsEverything)
                }
                .settingsAnchor("passwords.everything")
                Rule()
                Line(
                    "Offer passkeys",
                    prefs.passkeysPossible
                        ? "Touch ID or an iCloud passkey, on sites that offer one"
                        : "Copper keeps its own passkeys — Touch ID to sign in; new passkeys are saved here and in your Passwords list"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                .settingsAnchor("passwords.passkeys")
                NeverAskedLines(browser: browser) // Fork (never-asked): one row per site, each with Forget — Fork/Credentials/NeverAsked.swift
            }
            // Fork (settings-revamp): one card per password manager, one
            // under the other — Bitwarden's here, 1Password's beside it.
            SettingsSection("Password managers", carded: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SaveTargetCard(browser: browser) // Fork: Keychain / Bitwarden / 1Password (Fork/OnePasswordSettings.swift)
                    BitwardenCard(browser: browser)
                        .settingsAnchor("bitwarden", card: true)
                    OnePasswordCard(browser: browser) // Fork: 1Password (Fork/OnePasswordSettings.swift)
                        .settingsAnchor("onepassword", card: true)
                }
                .settingsAnchor("passwords.managers", card: true)
            }
            SettingsSection("Agent access", carded: false) {
                AgentAccessCard(browser: browser)
                    .settingsAnchor("passwords.agents", card: true)
            }
            SettingsSection("Import and export") { // Fork (password-csv): CSV in and out — Fork/Credentials/PasswordCSV.swift
                PasswordCSVLines(browser: browser)
            }
            PasskeysSettings() // Fork (settings-merge): its own section, only once there are passkeys
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        SettingsSection("Downloads") { // Fork (settings-merge): a section of General
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            .settingsAnchor("downloads.folder")
            Rule()
            Line("Ask where to save each file", "A save panel for every download, starting in the folder above") { // Fork (settings-browse): every row says what it does
                Switch(on: $prefs.asksWhereToSave)
            }
            .settingsAnchor("downloads.ask")
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        Group {
            SettingsSection("Blocking") {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                .settingsAnchor("privacy.shield")
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart Copper") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                    .settingsAnchor("privacy.site")
                }
            }
            SettingsSection("Permissions") {
                Line("Camera and microphone", "What each site was allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
                .settingsAnchor("privacy.capture")
            }
            SettingsSection("Clear browsing data") {
                ClearBrowsingDataLines(browser: browser) // Fork (privacy-clear): asks first, every jar — Fork/PrivacySettings.swift
            }
        }
    }

    // MARK: - about

    private var about: some View {
        Group {
            HStack(spacing: 16) {
                CopperIcon(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fork.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(verbatim: "by Collin and Felipe") // Fork (settings-merge): the version is the Updates row below
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsInk.detail)
                        .textSelection(.enabled)
                    Text("Built on Search by Office Commun")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsInk.detail.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(SettingsInk.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SettingsInk.cardEdge, lineWidth: 1))
            .settingsAnchor("about.identity", card: true)

            UpdatesPage(browser: browser) // Fork (settings-merge): Updates was its own page — Fork/SettingsFork.swift

            SettingsSection("Help") {
                Line("Found something wrong?", "Opens a new issue on Copper’s page, with the version already in it") { // Fork (feedback)
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
                .settingsAnchor("about.feedback")
            }

            CrashesSection() // Fork: the last crash, only when there is one (Fork/CrashesUI.swift)

            SettingsSection("Keyboard shortcuts", carded: false) {
                Card {
                    ForEach(Array(SettingsShortcuts.all.enumerated()), id: \.offset) { index, shortcut in
                        if index > 0 { Rule() }
                        Shortcut(shortcut.keys, shortcut.does)
                    }
                }
                .settingsAnchor("about.shortcuts", card: true)
            }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        // Fork (settings-browse): a sheet on this window, not a modal that
        // froze every window until it was answered.
        let prefs = prefs
        SettingsPanels.present(panel, on: Windows.window(of: browser)) { url in
            if let url { prefs.downloads = url }
        }
    }

    // MARK: - pieces

    /// A keystroke and what it does.
    private struct Shortcut: View {
        let keys: String
        let does: String
        init(_ keys: String, _ does: String) { self.keys = keys; self.does = does }

        var body: some View {
            HStack {
                Text(does)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(keys)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(SettingsInk.detail) // Fork (settings-revamp)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false
    /// Fork (settings-a11y): what VoiceOver calls the row of choices; a
    /// `Line` hands its title down instead (Fork/SettingsControls.swift).
    var label: String? = nil

    @Namespace private var slide
    @Environment(\.controlLabel) private var rowLabel // Fork (settings-a11y)
    @Environment(\.isEnabled) private var enabled // Fork (settings-a11y)
    @Environment(\.settingsPageName) private var pageName // Fork (settings-a11y)
    @FocusState private var focused: Bool // Fork (settings-a11y)

    init(options: [(Option, String)], selection: Binding<Option>, wide: Bool = false, label: String? = nil) {
        self.options = options
        self._selection = selection
        self.wide = wide
        self.label = label
    }

    /// Fork (settings-a11y): ← → move the choice along, as in a radio group.
    private func step(_ by: Int) {
        guard enabled, let next = SettingsControlRules.step(from: options.firstIndex { $0.0 == selection }, by: by, count: options.count) else { return }
        withAnimation(Motion.settle) { selection = options[next].0 }
    }

    var body: some View {
        let _ = SettingsControlLedger.note("choices", page: pageName, name: SettingsControlRules.name(given: label, row: rowLabel),
                                           value: options.first { $0.0 == selection }?.1 ?? "", keyboard: enabled, disabled: !enabled, focused: focused) // Fork (settings-a11y)
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        guard enabled else { return } // Fork (settings-a11y)
                        withAnimation(Motion.settle) { selection = option }
                    }
                    // Fork (settings-a11y): each choice a button VoiceOver can press.
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(option == selection ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { if enabled { withAnimation(Motion.settle) { selection = option } } }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
        // Fork (settings-a11y): one stop for Tab; ← → choose.
        .settingsFocusable($focused, enabled: enabled, shape: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SettingsControlRules.name(given: label, row: rowLabel))
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool
    /// Fork (settings-a11y): what VoiceOver calls it; a `Line` hands its
    /// title down instead (Fork/SettingsControls.swift).
    var label: String? = nil
    @Environment(\.controlLabel) private var rowLabel // Fork (settings-a11y)
    @Environment(\.isEnabled) private var enabled // Fork (settings-a11y)
    @Environment(\.settingsPageName) private var pageName // Fork (settings-a11y)
    @FocusState private var focused: Bool // Fork (settings-a11y)

    init(on: Binding<Bool>, label: String? = nil) {
        self._on = on
        self.label = label
    }

    private func flip() {
        guard enabled else { return }
        withAnimation(Motion.settle) { on.toggle() }
    }

    var body: some View {
        let _ = SettingsPerf.tick("switch") // Fork (settings-perf)
        let _ = SettingsControlLedger.note("switch", page: pageName, name: SettingsControlRules.name(given: label, row: rowLabel),
                                           value: on ? "On" : "Off", keyboard: enabled, disabled: !enabled, focused: focused) // Fork (settings-a11y)
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { flip() }
            .animation(Motion.settle, value: on)
            // Fork (settings-a11y): a switch to VoiceOver, and Space or
            // Return flips it once Tab has reached it.
            .settingsFocusable($focused, enabled: enabled, shape: Capsule())
            .onKeyPress(keys: [.space, .return]) { _ in
                flip()
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(SettingsControlRules.name(given: label, row: rowLabel))
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction { flip() }
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool // Fork (settings-a11y)
    @Environment(\.isEnabled) private var enabled // Fork (settings-a11y)
    @Environment(\.settingsPageName) private var pageName // Fork (settings-a11y)

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        let _ = SettingsPerf.tick("pill") // Fork (settings-perf)
        let _ = SettingsControlLedger.note("button", page: pageName, name: title, keyboard: enabled, disabled: !enabled, focused: focused) // Fork (settings-a11y)
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                // A pill is as wide as its word, never a tall wrapped column.
                .fixedSize()
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .settingsFocusRing($focused, shape: Capsule()) // Fork (settings-a11y)
    }
}

