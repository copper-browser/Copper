import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct SearchApp: App {
    // Fork: windows — the first of however many. Fork (observe): read in
    // `body`, after init has started the clock and taken the world.
    private var browser: Browser { Windows.main }
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    init() {
        Pace.start() // Fork (pace): the launch clock and the main-thread watch, first (Fork/Pace.swift)
        Instance.acquireIfNeeded() // Fork: one process per world, before anything is restored (Fork/Instance.swift)
        Fork.migratePasskeysPreference()
        Bridge.runIfAsked()
        Voice.shared.boot() // Fork (voice): the speech engine behind Settings › Voice, and ⌃⇧D (Fork/Voice/VoiceSession.swift)
    } // Fork: `--mcp-stdio` pipes to the running app and exits

    var body: some Scene {
        Window(Fork.name, id: "browser") {
            ContentView(browser: browser)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { AppCommands(main: browser) }

        // Fork: windows — every window ⌘N opens: its own row of tabs.
        WindowGroup(Fork.name, id: "window", for: UUID.self) { $id in
            OtherWindow(id: id)
        } defaultValue: {
            UUID()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
    }
}

/// The menus act on the window in front — the first one's browser when no
/// browser window is. (Fork: windows)
struct AppCommands: Commands {
    let main: Browser
    @FocusedValue(Browser.self) private var focused: Browser? // Fork (observe): Browser is @Observable
    /// Fork (perf): the History menu's own source, watched here rather than
    /// through every change of the browser (Browser.init).
    @ObservedObject private var history: History
    @ObservedObject private var keys = Shortcuts.shared // Fork (ardia-shortcuts): every key below is the table's (Fork/Shortcuts.swift)
    private var browser: Browser { focused ?? main }

    init(main: Browser) {
        self.main = main
        _history = ObservedObject(wrappedValue: main.history)
    }

    var body: some Commands {
        ForkCommands(browser: browser)
        // Tabs, and windows for more rows of them. (Fork: windows)
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.launch() } // Fork: the ⌘T card (Fork/Launcher)
                .shortcut(.newTab)
            Button("New Window") { Windows.newWindow() }
                .shortcut(.newWindow)
            Button("New Little Copper Window") { Little.open(nil) } // Fork (ardia: windows): Fork/Little.swift
                .shortcut(.newLittle)
            Button("New Private Tab") { browser.newShyTab() }
                .shortcut(.newPrivateTab)
            Button("New Canvas") { CanvasTabs.newCanvas(in: browser) } // Fork (canvas): ⌃⇧E is Arc's, and free here
                .shortcut(.newCanvas)
            Button("Reopen Closed Tab") { browser.reopen() }
                .shortcut(.reopenTab)
                .disabled(browser.ghosts.isEmpty)
            Divider()
            Button("Open Address…") { browser.edit() }
                .shortcut(.openAddress)
            Divider()
            Button("Close Tab") { if let tab = browser.active { browser.close(tab) } }
                .shortcut(.closeTab)
        }
        CommandGroup(replacing: .printItem) {
            ShareItem(browser: browser) // Fork (page-tools): File › Share… (Fork/PageShare.swift)
            Button("Print…") { browser.printPage() }
                .shortcut(.print)
                .disabled(browser.active?.isBlank ?? true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find on Page…") { browser.openFind() }
                .shortcut(.find)
                .disabled(browser.active?.isBlank ?? true)
            Button("Find Next") { browser.look(forward: true) }
                .shortcut(.findNext)
                .disabled(!browser.finding)
            Button("Find Previous") { browser.look(forward: false) }
                .shortcut(.findPrevious)
                .disabled(!browser.finding)
        }
        CommandGroup(replacing: .toolbar) {
            Toggle("Show Tabs in Sidebar", isOn: Binding(
                get: { browser.prefs.sidebar },
                set: { _ in browser.toggleSidebar() }
            ))
            .shortcut(.tabsInSidebar)
            // Folded away, not moved (see Fold.swift).
            Button(browser.folded ? "Show Sidebar" : "Hide Sidebar") { browser.toggleFold() }
                .shortcut(.foldSidebar)
                .disabled(!browser.prefs.sidebar)
            Divider()
            Button("Reload Page") { browser.reload() }
                .shortcut(.reload)
            Button("Hard Reload") { browser.hardReload() }
                .shortcut(.hardReload)
            Button("Reading Mode") { browser.toggleReader() }
                .shortcut(.readingMode)
            TranslateItems(browser: browser) // Fork (page-tools): Translate Page / Show Original, Never Translate This Site (Fork/Translate.swift)
            Button("Inspect Element") { browser.inspectElement() }
                .shortcut(.inspect)
            Button("Float Video") { browser.toggleFloat() }
                .shortcut(.floatVideo)
            Divider()
            Button("Hide Elements…") { browser.toggleHiding() }
                .shortcut(.hideElements)
            Button("Hidden on This Site…") { browser.reviewing.toggle() }
                .shortcut(.hiddenOnSite)
            Divider()
            Button("Zoom In") { browser.zoom(by: 1.1) }
                .shortcut(.zoomIn)
            Button("Zoom Out") { browser.zoom(by: 1 / 1.1) }
                .shortcut(.zoomOut)
            Button("Actual Size") { browser.resetZoom() }
                .shortcut(.actualSize)
        }
        CommandMenu("Tabs") {
            Button("Back") { browser.back() }
                .shortcut(.back)
                .disabled(browser.active?.canGoBack != true)
            Button("Forward") { browser.forward() }
                .shortcut(.forward)
                .disabled(browser.active?.canGoForward != true)
            Divider()
            Button("Next Tab") { browser.step(1) }
                .shortcut(.nextTab)
            Button("Previous Tab") { browser.step(-1) }
                .shortcut(.previousTab)
            Button("Search Tabs…") { browser.summon() }
                .shortcut(.searchTabs)
            Divider()
            if let tab = browser.active {
                if tab.pin == nil {
                    Button("Pin Tab") { browser.pin(tab) }
                        .shortcut(.pinTab)
                        .disabled(tab.isBlank)
                } else {
                    Button("Change Letter") { browser.editLetter(tab) }
                    Button("Unpin Tab") { browser.unpin(tab) }
                        .shortcut(.pinTab)
                }
            }
            Button("Duplicate Tab") { browser.duplicate() }
                .shortcut(.duplicateTab)
                .disabled(browser.active?.isBlank ?? true)
            Button("Copy Address") { browser.copyAddress() }
                .shortcut(.copyAddress)
                .disabled(browser.active?.isBlank ?? true)
            CopyLinkItems(browser: browser) // Fork (page-tools): Copy as Markdown ⌥⇧⌘C, Copy Link to Highlight (Fork/CleanLinks.swift)
            Button("Paste and Go") { browser.pasteAndGo() }
                .shortcut(.pasteAndGo)
            Divider()
            Button("Close Other Tabs") { if let tab = browser.active { browser.closeOthers(but: tab) } }
                .shortcut(.closeOtherTabs)
                .disabled(browser.tabs.count < 2)
            Button("Clear Tabs") { ClearTabs.shared.clear(in: browser) }
                .shortcut(.clearTabs)
                .disabled(ClearTabs.shared.clearable(in: browser).isEmpty)
            Button("Clean Up Tabs") { Cleaned.shared.cleanUp(in: browser) }.shortcut(.cleanUp) // Fork (ardia-tabs): Ardia's ⌥⌘K, into Recently Cleaned
            Button("Stop Sound in Tab") { browser.pauseMedia() }
                .shortcut(.stopSound)
        }
        CommandMenu("Bookmarks") {
            Button("Add This Page") { browser.bookmarkCurrent() }
                .shortcut(.addBookmark)
                .disabled(browser.active?.isBlank ?? true)
            Button("Show Bookmarks…") { browser.bookmarking = true }
                .shortcut(.showBookmarks)
            Divider()
            BookmarkTree(nodes: browser.bookmarks.roots) { browser.visit($0) }
        }
        CommandMenu("History") {
            Section("Recently Visited") {
                ForEach(browser.recentlyVisited) { trace in
                    Button {
                        browser.open(trace.url, foreground: true)
                    } label: {
                        MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
                    }
                }
            }
            if !browser.ghosts.isEmpty {
                Section("Recently Closed") {
                    ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                        Button {
                            browser.reopen(ghost)
                        } label: {
                            MenuLine(title: ghost.label, url: ghost.url)
                        }
                    }
                }
            }
            Divider()
            Button("Show History…") { browser.recalling = true }
                .shortcut(.history)
            Button("Downloads…") { browser.showDownloads() } // Fork (ui-flows r3)
                .shortcut(.downloads)
            Button("Open Downloads Folder") { browser.openDownloadsFolder() }
                .shortcut(.downloadsFolder)
            Divider()
            Button("Clear History") { browser.clearHistory() }
                .shortcut(.clearHistory)
        }
        CommandGroup(after: .appSettings) {
            Button("Settings…") { browser.tuning = true }
                .shortcut(.settings)
            Button("Welcome…") { browser.welcoming = true }
                .shortcut(.welcome)
            Button("Passwords…") { browser.managing = true }
                .shortcut(.passwords)
            Button("Search Accounts…") { browser.vaultOpen.toggle() } // Fork (vault-popup): Bitwarden's own shortcut for its popup
                .shortcut(.searchAccounts)
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { Links.writeFeedback() }
                .shortcut(.feedback)
        }
    }
}

/// The bookmarks, as menus within menus, for the menu bar.
private struct BookmarkTree: View {
    let nodes: [Bookmark]
    let open: (URL) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                Menu(node.title) {
                    if let kids = node.children, !kids.isEmpty {
                        BookmarkTree(nodes: kids, open: open)
                    } else {
                        Text("Empty")
                    }
                }
            } else if let text = node.url, let url = URL(string: text) {
                Button(node.title) { open(url) }
            }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

struct ContentView: View {
    let browser: Browser
    /// Fork (perf): the field up, ⌘K or not (`fieldShowing`, the transition
    /// below) — see `Browser.Bar`.
    @ObservedObject private var bar: Browser.Bar
    @ObservedObject private var recent = Recent.shared
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var clearTabs = ClearTabs.shared
    @ObservedObject private var launch = Launch.shared // Fork (launch): the column waits for the page (Fork/Launch.swift)

    @State private var keys: Any?
    @State private var window: NSWindow?
    @State private var resting: RestingLights?

    init(browser: Browser) {
        self.browser = browser
        _bar = ObservedObject(wrappedValue: browser.bar)
    }


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: .top) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            if browser.active?.immersed == true {
                Color.black
            } else if sidebar {
                WindowGround(browser: browser) // Fork (page-frame): the space's ground under the column and round the page
            } else {
                StripGround(browser: browser) // Fork (sheer): glass or the solid ground
            }

            HStack(spacing: 0) {
                // The column of tabs, in the way that has one. It takes the
                // full height, so the traffic lights sit in its own corner
                // rather than over the page.
                if sidebar {
                    if launch.dressed {
                        SideBar(browser: browser, prefs: browser.prefs, grounded: false) // Fork (page-frame): the window draws its ground
                            .transition(.move(edge: .leading))
                    } else {
                        // Fork (launch): the column's place, empty, until the restored page has painted.
                        Color.clear.frame(width: browser.prefs.sideWidth)
                    }
                }

                VStack(spacing: 0) {
                    // Room for the traffic lights, and for the strip when there
                    // is one. The page starts under it, not behind it — a page
                    // sliding beneath floating chrome is a browser showing off,
                    // and it costs a compositing pass.
                    Color.clear.frame(height: band)

                    // One stage, always.
                    if let tab = browser.active {
                        SplitStage(browser: browser, active: tab, inset: sidebar, framed: band > 0) // Fork (page-frame; uitype: the top-tab page is a card too)
                            .overlay {
                                if recent.showing {
                                    RecentStrip(browser: browser)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if browser.finding {
                                    FindBar(browser: browser)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if let asked = browser.suggesting, asked.tab == tab.id {
                                    AccountList(browser: browser, asked: asked)
                                        .padding(.top, sidebar || band > 0 ? SplitMetrics.margin : 0) // Fork (page-frame): the page card starts a margin down
                                        .transition(.opacity)
                                }
                            }
                            .animation(Motion.quick, value: browser.suggesting)
                    } else if let id = browser.taken, let tab = browser.tabs.first(where: { $0.id == id }) {
                        TakenStage(browser: browser, tab: tab) // Fork: windows — the page is on another window's stage
                    } else {
                        Palette.ground
                    }
                }
            }

            if !browser.prefs.sidebar, browser.active?.immersed != true {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(Motion.glide, value: browser.prefs.sidebar)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            clearTabsToast
            TidyToast(browser: browser) // Fork (tidy): Tidied N tabs · Undo (Fork/Tidy.swift)
            announcement
            HandoffSlot(browser: browser) // Fork (agent-handoff): an agent handing a step to you (Fork/MCP/Handoff.swift)
            CaptureSlot(browser: browser, desk: browser.capture) // Fork (page-capture): asks, a refusal to undo, macOS's own "no" (Fork/Capture/CaptureBar.swift)
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ShareBar(browser: browser) // Fork (tab-share): Sharing <tab> · Stop (Fork/TabShare/TabShareBar.swift)
            CanvasInviteSlot(browser: browser) // Fork (canvas): the invite pill's place; it is drawn over the panels
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: clearTabs.generation)
        .animation(Motion.settle, value: canvases.newInvite)
    }

    /// Fork (uichrome): the password offer hangs off the chrome — beside the
    /// column's address field, or under the strip's far end where the
    /// passwords door is — not at the foot of the window.
    private var offerSlot: some View {
        ZStack(alignment: sidebar ? .topLeading : .topTrailing) {
            Color.clear.allowsHitTesting(false)
            if let offer = browser.offering {
                keepAsking(offer)
                    .padding(.top, band + 8)
                    .padding(sidebar ? .leading : .trailing, sidebar ? browser.prefs.sideWidth + 8 : 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let ask = PageTranslate.shared.offerShown(in: browser) { // Fork (ardia polish): Fork/Translate.swift
                TranslateOfferCard(browser: browser, offer: ask)
                    .padding(.top, band + 8)
                    .padding(sidebar ? .leading : .trailing, sidebar ? browser.prefs.sideWidth + 8 : 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: browser.offering)
        .animation(Motion.settle, value: PageTranslate.shared.offer)
    }

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        if browser.fieldShowing {
            Omnibox(browser: browser, over: !(browser.active?.isBlank ?? true))
                // Centred on the page, not on the window. The column of tabs
                // is not what the field is standing over, and dimming it along
                // with the page says otherwise.
                .padding(.leading, sidebar ? browser.prefs.sideWidth : 0)
                // Fork (ui-flows): ⌘K's card draws its own arrival (solid, no
                // ghost; Fork/CommandPalette) and leaves in one quick fade.
                // Fork (perf): otherwise a fade. A scale redrew every letter on
                // the card at a new size each frame, and on a 1× screen each new
                // size of a glyph is hinted again, on the main thread.
                // Fork (ui-motion): the dim and the card leave as one, in 120 ms.
                .transition(bar.summoning
                    ? .asymmetric(insertion: .identity, removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12)))
                    : .opacity)
        }
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser) } close: { browser.recalling = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot, downloads: Downloads.shared) }
                close: { browser.hoarding = false }
        }
        if browser.tuning {
            sheet(fitted: false) { SettingsPanel(browser: browser, prefs: browser.prefs) }
                close: { browser.tuning = false }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser) } close: { browser.managing = false }
        }
        FlowBackdrop(browser: browser, column: sidebar ? browser.prefs.sideWidth : 0) // Fork (ui-flows r3): Move in's, the same backdrop
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, Metrics.strip + 8)
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    var body: some View {
        window_
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: .leading) { Fold(browser: browser, prefs: browser.prefs) }
            // Fork (update-pill): the folded column's update badge.
            .overlay(alignment: .bottomLeading) { UpdateCorner(browser: browser, prefs: browser.prefs) }
            .overlay(alignment: .bottomLeading) { UpdateNewsCorner(browser: browser, prefs: browser.prefs) } // Fork (ardia polish): What's New off the column (Fork/UpdateNews.swift)
            .overlay(alignment: .bottomLeading) { CloudHoldCorner(browser: browser, prefs: browser.prefs) } // Fork (cloud): the spaces brake's prompt with no column
            .overlay(alignment: .bottom) { bars }
            .overlay { offerSlot }
            .overlay { field }
            .overlay { panels }
            .overlay { SharePickerSlot(browser: browser) } // Fork (tab-share): what to share (Fork/TabShare/TabSharePicker.swift)
            .overlay(alignment: .bottom) { CanvasInviteBar(browser: browser) } // Fork (canvas): over the panels (Fork/Canvas/CanvasInvites.swift)
            .animation(Motion.settle, value: browser.fieldShowing)
            .background(WindowSetup { window = $0; dress($0) })
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                measureLights()
                resting?.isHidden = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
            }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async {
                        // Fork (perf): ⌘T and ⌘K have already put the caret in
                        // their field; asking again redrew the whole window a
                        // second time in the key's pass.
                        if (Windows.window(of: browser)?.firstResponder as? NSTextView)?.isFieldEditor == true { return }
                        browser.askFocus()
                    }
                } else {
                    handBack()
                }
            }
            .onChange(of: browser.activeID) { _, _ in handBack() }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            Pace.mark("window") // Fork (pace)
            Launch.shared.windowShown() // Fork (launch)
            watchKeys()
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on —
            // the first window; the others are opened from it. (Fork: windows)
            if browser.primary { Links.hand(to: browser) }
        }
        // The menus act on the window in front, and ⌘N works from any. (Fork: windows)
        .focusedSceneValue(browser)
        .onDisappear {
            if let keys { NSEvent.removeMonitor(keys) }
            keys = nil
        }
        .modifier(WindowOpener())
        .tint(Palette.accent) // Fork (ui-system): system controls in Copper's accent, not the Mac's blue
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard let web = browser.active?.web, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// The six-second Clear affordance, styled like the existing announcement
    /// pill but with an actionable Undo control.
    @ViewBuilder
    private var clearTabsToast: some View {
        ClearTabsToast(browser: browser)
    }

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// Offered once, answered once. The password is never shown back to you —
    /// there is nothing to be learned from reading your own password.
    private func keepAsking(_ offer: Browser.Offer) -> some View {
        let login = offer.login
        let vault = offer.target != .keychain // Fork: Bitwarden or 1Password
        let name = offer.target.title
        return HStack(spacing: 10) {
            // Fork (ui-system): whose password, at a glance — the site's
            // mark. Fork (uib): the 7 pt key badge on its corner went; the
            // sentence beside it already says password.
            Mark(icon: Favicons.shared.cached(login.host), size: 18)
                .padding(.trailing, 4)
                .accessibilityHidden(true)
            // Fork (uichrome): the question, then the site and the account on
            // lines of their own (one long sentence was cut on narrow windows).
            VStack(alignment: .leading, spacing: 1) {
                Text(vault
                     ? (offer.changed ? "Update the password in \(name)?" : "Save the password to \(name)?")
                     : (offer.changed ? "Update the password?" : "Save the password?"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(login.host)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                if !login.user.isEmpty {
                    Text(login.user)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            // Fork (ui-system): one accent button, one bordered, and the
            // rarely-wanted "never" tucked under ⌄ rather than a third word.
            Pill(vault ? (offer.changed ? "Update in \(name)" : "Save to \(name)") : (offer.changed ? "Update" : "Save"), filled: true) { browser.keepOffer() }
            Pill("Not now") { browser.dropOffer() }
            if !offer.changed {
                Menu {
                    Button("Never here") { browser.neverOffer() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Palette.muted) // a menu's label takes the tint, not its own colour
                .fixedSize()
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help("Never here: don't offer for \(login.host) again")
                .accessibilityLabel("More")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        .fixedSize()
    }


    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    private func sheet<Panel: View>(
        fitted: Bool = true,
        @ViewBuilder _ panel: () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        // Fork (ui-system): a panel is as tall as what it holds, up to 70% of
        // the window; its list (`Fitted`) scrolls past that. Settings keeps
        // its own size.
        let content = panel()
        let column = sidebar ? browser.prefs.sideWidth : 0
        return GeometryReader { room in
            ZStack {
                // Fork (ui-flows r3): the one backdrop (Fork/ModalBackdrop.swift):
                // the page card blurred and dimmed, the column left crisp.
                ModalBackdrop(column: column, tap: close)
                content
                    .frame(maxHeight: fitted ? max(280, room.size.height * 0.7) : nil)
                    // Over the page card, beside the column; Settings, wider,
                    // keeps the window's middle.
                    .padding(.leading, fitted ? column : 0)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
            .frame(width: room.size.width, height: room.size.height)
        }
        .transition(.opacity)
    }

    /// True while the tabs are down the left, and not folded away (see Fold.swift).
    private var sidebar: Bool {
        browser.prefs.sidebar && !browser.folded && browser.active?.immersed != true
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        guard browser.active?.immersed != true else { return 0 }
        return browser.prefs.sidebar ? 0 : Metrics.strip
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    private func measureLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    private func dress(_ window: NSWindow) {
        Windows.attach(window, to: browser) // Fork: windows
        if browser.primary { Links.window = window }
        // A ⌘N window comes back from windows.json, not from macOS's own
        // window restoration, which brings back an empty one. (Fork: windows)
        if !browser.primary { window.isRestorable = false }
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        Sheer.dress(window) // Fork (sheer): clear while it holds glass, else the ground colour
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Where you left it, at the size you left it. A test run keeps its
        // own: the name lives in the app's standard defaults, which every
        // copy shares, and a probe resized for a test once changed the size
        // the real window came back at.
        // Only the first window: the others cascade from it. (Fork: windows)
        if browser.primary { window.setFrameAutosaveName(Store.world.map { "search (\($0))" } ?? "search") }

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Fork (agent-keys): a key an agent pressed in a page and the page
            // didn't use goes no further — not to the window in front, not to
            // the menus (Fork/MCP/Input.swift `returned`).
            if Input.returned(event) { return nil }
            if let mine = Little.key(event) { return mine ? nil : event } // Fork (ardia: windows): a Little Copper's or Peek's keys are their own
            // Every window watches the keys; a keystroke is the window's it
            // was typed in, and a panel or popup of no browser's goes to the
            // one in front. (Fork: windows)
            if (Windows.owner(of: event.window) ?? Windows.current) !== browser { return event }
            guard event.type == .keyDown else {
                SpaceWarm.control(event.modifierFlags.contains(.control), in: browser, window: event.window) // Fork (switch, covers): ⌃ down warms the spaces either side
                // Releasing ⌃ commits a most-recent tab walk wherever it stopped.
                if !event.modifierFlags.contains(.control), Recent.shared.walking {
                    Recent.shared.end(in: browser)
                }
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            SpaceWarm.key(event, in: browser) // Fork (covers): a non-space key with ⌃ takes the warming guess back
            return take(event) ? nil : event
        }
    }

    private func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Fork (ardia-shortcuts): a Settings › Shortcuts row recording keys hears them first.
        if Shortcuts.shared.take(event) { return true }

        // Fork (voice): Escape cancels a dictation before anything else hears
        // it, and ⌃⇧D is the agent pane's while it is open (Fork/Voice/VoiceKeys.swift).
        if VoiceKeys.take(event) { return true }

        // Fork (flow): while Move in is up, a key typed on it is the sheet's —
        // ⌘W closes it, the window's other ⌘ shortcuts wait (Fork/Flow/FlowPresenter.swift).
        if let taken = FlowKeys.take(event) { return taken }

        // Fork (tab-share): while the share picker is up, the keyboard is its own.
        if SharePicker.take(event, in: browser) { return true }

        // Fork (new-tab-launcher): while the ⌘T card is up, Escape, ⇧/⌥
        // Return and ⌘1–9 are its own.
        if browser.launching, Launcher.key(event, in: browser) { return true }

        // Fork (settings-revamp): while Settings is open, ⌘F, Esc (the query
        // before the panel), ↑ ↓ ↩ over results and type-to-search are its own.
        if browser.tuning, SettingsKeys.take(event, in: browser) { return true }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // Fork (ui-flows): ⌘K's card goes in one press, as Arc's does —
            // its first row is always picked, so a step back there was a
            // second ⎋ for nothing. ⌘L keeps the step: the list, then the field.
            if browser.summoning {
                browser.dismiss()
                return true
            }
            if browser.picked != nil {
                browser.picked = nil
                return true
            }
            if browser.editing {
                guard browser.active?.isBlank == false else { return false }
                browser.dismiss()
                return true
            }
            // Fork (agent-ux): an agent driving — the Stop pill's ⎋ — before the page has it.
            if DriveStop.escape(in: browser) { return true }
            // Last of all, a pane beside the page — while the keyboard is
            // not in a page, where Escape is the page's. (Fork: Panes)
            return Panes.escape(event, in: browser)
        }

        // Fork (developer-shortcuts): plain Tab and ⇧Tab are never a tab
        // switch. They belong to whoever has the keyboard — the page, a field
        // in it, a site's own Tab-to-accept, a native field — and in the
        // address field, ⌘T and ⌘K they take the completion on offer (see
        // AddressField). Only ⌃Tab and ⌃⇧Tab walk the row, from anywhere.
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option) {
            if browser.editingTab != nil { return true }
            guard flags.contains(.control) else { return false }
            if !browser.fieldShowing, browser.prefs.tabSwitching == .recent {
                Recent.shared.step(flags.contains(.shift) ? -1 : 1, in: browser)
            } else {
                browser.step(flags.contains(.shift) ? -1 : 1)
            }
            return true
        }

        // Fork (ardia profiles): ⌥⌘← / ⌥⌘→, Ardia's (and Arc's) keys for the
        // space — and so the profile — before or after, beside ⌃⌥←/→.
        if flags.intersection([.command, .option, .control, .shift]) == [.command, .option], event.keyCode == 123 || event.keyCode == 124 {
            Spaces.shared.step(event.keyCode == 123 ? -1 : 1, in: browser)
            return true
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, unless
        // a menu of ours carries the same key (⌘E is the agent's, whatever an
        // extension's manifest suggests; Extensions.take).
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           Extensions.shared.take(event) {
            return true
        }

        // Fork (ardia-shortcuts): the key's command, from the one table the
        // menus read (Fork/Shortcuts.swift) — wherever Settings › Shortcuts
        // moved it. The commands not run here are the menu's.
        if let command = Shortcuts.shared.table.command(for: event), let taken = run(command, event) { return taken }

        guard flags.contains(.command) else { return false }
        let shifted = flags.contains(.shift)

        // Anything with ⌥ or ⌃ on top is somebody else's.
        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        switch key {
        case "z" where !shifted:
            // Clear's undo owns ⌘Z while its pill is up; otherwise only while
            // pointing. Everywhere else undo belongs to the page.
            if ClearTabs.shared.undoCount(in: browser) != nil {
                ClearTabs.shared.undo(in: browser)
                return true
            }
            if Tidy.shared.undoLine(in: browser) != nil { // Fork (tidy): and Tidy's, while its pill is up
                Tidy.shared.undo(in: browser)
                return true
            }
            guard browser.veiling else { return false }
            browser.undoHiding()
        default:
            // ⌘1 through ⌘9: the ninth is the last one, however many there are.
            if let number = Int(key), (1...9).contains(number), !shifted {
                browser.select(index: number == 9 ? browser.tabs.count - 1 : number - 1)
                return true
            }
            // ⌘← and ⌘→, for hands that never learned the brackets — unless
            // the caret is in text, where they are line start and end. (Fork:
            // LineKeys asks who has the keyboard.)
            if LineKeys.isLineKey(event) { return LineKeys.take(event, in: browser) }
            return false
        }
        return true
    }

    /// Fork (ardia-shortcuts): the commands this monitor runs itself, on
    /// whatever key the table gives them, before a page can take the key;
    /// nil leaves the key to the menu bar, which carries the rest.
    private func run(_ command: MenuCommand, _ event: NSEvent) -> Bool? {
        switch command {
        case .newTab: browser.launch() // Fork: the ⌘T card (Fork/Launcher)
        case .reopenTab: browser.reopen()
        case .copyAddress: browser.copyAddress()
        case .duplicateTab: browser.duplicate()
        case .newPrivateTab: browser.newShyTab()
        case .newWindow: Windows.newWindow() // Fork: windows
        case .history: browser.recalling.toggle()
        case .downloads: browser.showDownloads(toggling: true) // Fork (ui-flows r3): the popover from the column
        case .pasteAndGo: browser.pasteAndGo()
        case .print: browser.printPage()
        case .find: browser.openFind()
        case .findNext: browser.look(forward: true)
        case .findPrevious: browser.look(forward: false)
        case .stopSound: browser.pauseMedia()
        case .floatVideo: browser.toggleFloat()
        case .searchTabs:
            // Held down, ⌘K walks the list a step at a time; letting go of ⌘
            // takes wherever it stopped.
            if browser.editing, !browser.offers.isEmpty {
                browser.stepSummon()
            } else {
                // A page with its own ⌘K keeps it; the app acts only when the
                // page hands the key back unused. (Fork: PageFirst.)
                if PageFirst.lend(event) { return false }
                browser.summon()
            }
        case .tabsInSidebar: browser.toggleSidebar()
        case .foldSidebar:
            // The strip has nothing to fold; ⌘S stays the page's (see Fold.swift).
            guard browser.prefs.sidebar else { return false }
            browser.toggleFold()
        case .addBookmark: browser.bookmarkCurrent()
        case .settings: browser.tuning.toggle()
        case .hideElements: browser.toggleHiding()
        case .hiddenOnSite: browser.reviewing.toggle()
        case .clearTabs:
            guard !ClearTabs.shared.clearable(in: browser).isEmpty else { return false }
            ClearTabs.shared.clear(in: browser)
        case .zoomIn: browser.zoom(by: 1.1)
        case .zoomOut: browser.zoom(by: 1 / 1.1)
        case .actualSize: browser.resetZoom()
        case .closeTab: if let tab = browser.active { browser.close(tab) }
        case .openAddress: browser.edit()
        case .reload: browser.reload()
        case .hardReload: browser.hardReload()
        case .inspect: browser.inspectElement()
        case .back: browser.back()
        case .forward: browser.forward()
        case .nextTab: browser.step(1)
        case .previousTab: browser.step(-1)
        default: return nil
        }
        return true
    }
}
