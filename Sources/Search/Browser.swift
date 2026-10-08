import SwiftUI
import WebKit
import Combine

// The address-bar rows use the older, file-wide Suggestion type. The picker
// rows below deliberately live under Browser so they cannot be confused with
// history and command-bar offers.
typealias OmniboxSuggestion = Suggestion

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

@MainActor
final class Browser: NSObject, ObservableObject {
    @Published var tabs: [Tab] = [] {
        didSet {
            // `tabs` is a window's projection of its current space. Keep the
            // canonical row in Spaces in step, then publish that row to every
            // other window looking at the same space.
            guard oldValue.map(\.id) != tabs.map(\.id) || oldValue.count != tabs.count else { return }
            Spaces.shared.tabsChanged(self)
        }
    }
    @Published var activeID: Tab.ID? {
        didSet {
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            guard oldValue != activeID, let old = oldValue else {
                Spaces.shared.activeChanged(self)
                return
            }
            tabs.first { $0.id == old }?.touch()
            Recent.shared.touched(activeID)
            Spaces.shared.activeChanged(self)
        }
    }

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    @Published private(set) var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs: Preferences // Fork: windows — one set, shared by every window
    /// The settings panel.
    @Published var tuning = false
    /// The page the settings panel should open on. Bench uses this to land on
    /// Passwords without pretending a native sidebar row is a web element.
    @Published var settingsPage: SettingsPanel.Page =
        SettingsPanel.Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false

    // MARK: - bookmarks

    let bookmarks: Bookmarks
    /// The full list, for taking things out.
    @Published var bookmarking = false
    /// The dropdown off the button.
    @Published var bookmarksOpen = false

    /// ⇧⌘B. The page you are on, at the end of the list.
    func bookmarkCurrent() {
        guard let tab = active, let url = tab.address else { return }
        guard !bookmarks.contains(url) else {
            announce("Already a bookmark")
            return
        }
        bookmarks.add(url, title: tab.title)
        announce("Bookmarked")
    }

    /// Another browser's bookmarks, folders and all — and, behind them, the
    /// icons it had for those sites, so the menu wears them from the start
    /// instead of a letter each. Returns how many pages came over.
    @discardableResult
    func takeBookmarks(from source: Chromium.Source) -> Int {
        let found = Chromium.bookmarks(in: source)
        bookmarks.take(found, from: source.name)
        let count = Bookmarks.count(found.nodes)
        announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
        let urls = Bookmarks.urls(found.nodes)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return count
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func toggleSidebar() {
        withAnimation(Motion.glide) { prefs.sidebar.toggle() }
    }

    /// ⌘S: the column folded away, and slid out over the page for a look
    /// while it is (see Fold.swift).
    @Published var folded = false
    @Published var peeking = false

    /// The address field, raised over a page by ⌘L. A blank tab shows it
    /// without being asked — there is nothing else for that tab to show.
    @Published var editing = false
    /// Fork (new-tab-launcher): what the field holds and offers, in an object
    /// of its own. Published from the browser, every letter typed told every
    /// view watching the browser — the sidebar, the tab strip, the menus — to
    /// draw again; now only the views that draw the field and its rows hear
    /// it, by observing `field` (Omnibox, AddressField, Fork/CommandPalette).
    final class Field: ObservableObject {
        @Published var typed = ""
        @Published var offers: [OmniboxSuggestion] = []
        @Published var ending: String?
        @Published var picked: Int?
    }
    let field = Field()

    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    var typed: String {
        get { field.typed }
        set { field.typed = newValue; guess() }
    }

    let history: History
    /// What the field is offering, best first.
    private(set) var offers: [OmniboxSuggestion] {
        get { field.offers }
        set { field.offers = newValue }
    }
    /// The rest of the best match, drawn grey after the caret. Tab takes it.
    private(set) var ending: String? {
        get { field.ending }
        set { field.ending = newValue }
    }
    /// Which row the arrow keys have walked to, if any.
    var picked: Int? {
        get { field.picked }
        set { field.picked = newValue }
    }
    /// Bumped when what was typed isn't an address and can't be searched for.
    @Published private(set) var refusals = 0
    /// Bumped whenever the cursor should go back into the field.
    @Published private(set) var focusRequest = 0

    /// True while the field is a switcher rather than an address bar. ⌘K asks
    /// one question — which of the pages I already have open — and answering it
    /// with somewhere you went last week would be answering a different one.
    @Published private(set) var summoning = false
    /// Fork (new-tab-launcher): the card is up for ⌘T rather than ⌘K — it
    /// opens what you pick in a new tab instead of in this one, and nothing
    /// exists until you pick. Always true together with `summoning`, so
    /// everything that draws the card draws it the same. See Fork/Launcher.
    @Published private(set) var launching = false
    /// True between the first ⌘K and letting go of ⌘.
    var cycling = false

    var active: Tab? { tabs.first { $0.id == activeID } }
    var fieldShowing: Bool { editing || (active?.isBlank ?? (taken == nil)) } // Fork: windows — not over "open in another window"

    /// Typed plus whatever the field is quietly finishing for you.
    var completed: String {
        if let picked, offers.indices.contains(picked) { return offers[picked].key }
        return typed + (ending ?? "")
    }

    // MARK: - looking for something on the page

    @Published var finding = false
    @Published var needle = "" { didSet { look(forward: true) } }
    /// Set when the page doesn't hold what was asked for.
    @Published private(set) var missed = false
    @Published private(set) var findFocus = 0

    func openFind() {
        guard active?.isBlank == false else { return }
        finding = true
        findFocus += 1
    }

    func closeFind() {
        guard finding else { return }
        finding = false
        needle = ""
        missed = false
        // There is no public way to call off a find, but letting go of the
        // selection is what taking the highlight away amounts to.
        active?.web.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    func look(forward: Bool) {
        guard let web = active?.web, !needle.isEmpty else {
            missed = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        web.find(needle, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated { self?.missed = !result.matchFound }
        }
    }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    func pauseMedia() {
        guard let tab = active else { return }
        tab.web.pauseAllMediaPlayback()
        announce("Paused")
    }

    // MARK: - taking things off pages

    let curtain: Curtain
    let loot: Loot
    let floater = Float()
    /// True while the pointer is picking things to hide.
    @Published private(set) var veiling = false
    /// True while the list of what is hidden here is up.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    var hereHost: String? { curtain.host(of: active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = active, !tab.isBlank else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back")
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published private(set) var offering: Offer?

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
        /// The destination selected in Settings when the offer was created.
        let target: Credentials.Backend
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published private(set) var suggesting: Suggesting?

    enum Suggestion: Identifiable, Hashable {
        case credential(Credential)
        /// The current two-step code of a Bitwarden login with an
        /// authenticator key, offered under a one-time-code box.
        case code(Credential)
        case username(String)
        case identity(AutofillIdentity)
        case card(AutofillCard)
        case field(AutofillField)

        var id: String {
            switch self {
            case .credential(let credential): return credential.stableID
            case .code(let credential): return "code:\(credential.stableID)"
            case .username(let name): return "user:\(name)"
            case .identity(let identity): return "id:\(identity.id)"
            case .card(let card): return "card:\(card.id)"
            case .field(let field): return "field:\(field.itemID)\u{1}\(field.name)"
            }
        }
    }

    struct Suggesting: Equatable {
        let tab: Tab.ID
        let spot: CGRect
        let credentials: [Credential]
        let rows: [Suggestion]

        init(tab: Tab.ID, spot: CGRect, credentials: [Credential]) {
            self.init(tab: tab, spot: spot, credentials: credentials,
                      rows: credentials.map(Suggestion.credential))
        }

        init(tab: Tab.ID, spot: CGRect, credentials: [Credential], rows: [Suggestion]) {
            self.tab = tab
            self.spot = spot
            self.credentials = credentials
            self.rows = rows
        }
    }
    /// The row whose secret is being fetched. Keeping it published lets the
    /// picker show a small, transient "Fetching…" state without exposing it.
    @Published private(set) var fetching: CredentialID?
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    private var pickedInto: Tab.ID?
    /// The account last put into each tab from the list. Its two-step code
    /// comes first on the page that asks for one, which is often on another
    /// host than the sign-in (accounts.google.com, login.microsoftonline.com).
    private var signedInWith: [Tab.ID: Credential] = [:]
    /// A code went into this tab's box. A password pick does not hold back
    /// the code list: the page that asks for the code often replaces the
    /// sign-in without the caret ever leaving a box.
    private var codePickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    private var lowering: DispatchWorkItem?

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        // Preserve the old synchronous keychain path exactly when Bitwarden
        // (or 1Password — Fork) is not the active destination.
        guard offer.target != .keychain else {
            guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date()) else {
                announce("The keychain refused it")
                return
            }
            relist()
            announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
            return
        }
        Task { [weak self] in
            do {
                try await Credentials.save(host: login.host, user: login.user, password: login.password)
                self?.relist()
                self?.announce(offer.changed ? "Password updated in \(offer.target.title) for \(login.host)" : "Password saved to \(offer.target.title)") // Fork: 1Password
            } catch {
                self?.announce(error.localizedDescription)
            }
        }
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host)
        offering = nil
        announce("Never for \(offer.login.host)")
    }

    /// One of the accounts in the list, picked by name. Bitwarden secrets are
    /// fetched only after the user chooses a row; metadata never contains one.
    func choose(_ credential: Credential) {
        lowering?.cancel()
        guard let tab = tabs.first(where: { $0.id == suggesting?.tab }) ?? active else { return }
        guard fetching == nil else { return }
        pickedInto = tab.id
        fetching = credential.id
        Task { [weak self, weak tab] in
            do {
                let secret = try await Credentials.secret(credential.id)
                guard let self, let tab else { return }
                tab.fill(user: credential.user, password: secret) { worked in
                    if !worked { self.announce("Couldn't find the sign-in fields anymore") }
                }
                Credentials.touch(credential)
                self.signedInWith[tab.id] = credential
                self.suggesting = nil
            } catch {
                self?.announce(error.localizedDescription)
                self?.suggesting = nil
            }
            self?.fetching = nil
        }
    }

    /// Fill one of the non-password rows without putting its value in a log or
    /// an announcement. The page reports only whether its boxes still exist.
    func choose(_ suggestion: Suggestion) {
        if case .credential(let credential) = suggestion {
            choose(credential)
            return
        }
        if case .code(let credential) = suggestion {
            chooseCode(credential)
            return
        }
        lowering?.cancel()
        guard fetching == nil,
              let tab = tabs.first(where: { $0.id == suggesting?.tab }) ?? active
        else { return }
        pickedInto = tab.id
        suggesting = nil

        func announceFailure() {
            announce("Couldn't find the boxes anymore")
        }
        switch suggestion {
        case .credential, .code:
            break
        case .username(let name):
            tab.fillFocused(name) { worked in
                if !worked { announceFailure() }
            }
        case .identity(let identity):
            tab.fillValues(identity.values()) { filled in
                if filled == 0 { announceFailure() }
            }
        case .card(let card):
            tab.fillValues(card.values()) { filled in
                if filled == 0 { announceFailure() }
            }
        case .field(let field):
            tab.fillFocused(field.value) { worked in
                if !worked { announceFailure() }
            }
        }
    }

    /// The code is read when the row is picked, never earlier, and goes
    /// straight into the page — not into a log or an announcement.
    private func chooseCode(_ credential: Credential) {
        lowering?.cancel()
        guard let tab = tabs.first(where: { $0.id == suggesting?.tab }) ?? active else { return }
        guard fetching == nil else { return }
        pickedInto = tab.id
        codePickedInto = tab.id
        fetching = credential.id
        Task { [weak self, weak tab] in
            do {
                let code = try await Credentials.totp(credential.id)
                guard let self, let tab else { return }
                tab.fillOTP(code) { worked in
                    if !worked { self.announce("Couldn't find the code box anymore") }
                }
                Credentials.touch(credential)
                self.suggesting = nil
            } catch {
                self?.announce(error.localizedDescription)
                self?.suggesting = nil
            }
            self?.fetching = nil
        }
    }

    /// Accounts with an authenticator key for a one-time-code box: the one
    /// just signed in with in this tab first, then the site's own.
    private func codeCredentials(for tab: Tab, host: String) -> [Credential] {
        var rows = Credentials.candidates(for: host, hint: tab.fieldHint).filter(\.hasTOTP)
        if let recent = signedInWith[tab.id], recent.hasTOTP {
            rows.removeAll { $0.id == recent.id }
            rows.insert(recent, at: 0)
        }
        return rows
    }

    func dropChoice() { suggesting = nil }

    static var bitwardenLocked: Bool {
        if case .locked = Bitwarden.shared.state { return true }
        return false
    }

    // The list of what is kept.

    @Published var managing = false { didSet { if managing { relist() } } }
    @Published private(set) var saved: [Login] = []
    @Published var hunting = ""

    struct SiteRow {
        let host: String
        let logins: [Login]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func relist() { saved = Vault.all() }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce("Kept for \(host)")
    }

    func forget(_ login: Login) {
        Vault.forget(host: login.host, user: login.user)
        relist()
    }

    func copy(_ login: Login) {
        guard let full = Vault.resolve(login) else {
            announce("The keychain didn't give up that password")
            return
        }
        SettingsActions.copy(full.password) // Fork (probe-pasteboard): a test world's copy stays in its own pasteboard — Fork/SettingsActions.swift
        announce("Password copied")
    }

    /// What came back from another browser's store, put in the keychain.
    func took(_ outcome: Result<Chromium.Found, Error>, from source: Chromium.Source) {
        switch outcome {
        case .success(let found):
            var kept = 0
            for login in found.logins
            where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used) {
                kept += 1
            }
            var never = Vault.never
            found.never.forEach { never.insert($0) }
            Vault.never = never
            relist()
            announce(kept == 0 ? "Nothing new in \(source.name)" : "\(kept) passwords from \(source.name)")
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(source.name) didn't give up its keychain key")
        case .failure:
            announce("Nothing readable in \(source.name)")
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: Chromium.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Chromium.places(in: source)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                done(places.count)
            }
        }
    }

    /// Takes in a CSV as Google Password Manager exports one. The file is read
    /// once and never copied.
    func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "A passwords export — from Chrome, Safari, Apple Passwords or a password manager." // Fork (password-csv)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPasswordsCSV(from: url) // Fork (password-csv): checked, off the main thread, one clear sentence — Fork/Credentials/PasswordCSV.swift
    }

    // MARK: - what is kept, and getting rid of it

    @Published var recalling = false
    @Published var hoarding = false
    @Published var recallHunt = ""

    /// Cookies, caches, local storage — everything a site left on this Mac.
    /// Clearing it signs you out of everything, which is the point.
    func clearSites() {
        // Fork (privacy-clear): every jar — the shared one and each space profile's — not only the front space's.
        PrivacyClear.remove(WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] in
            self?.announce("Signed out of everything")
        }
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        PrivacyClear.remove(PrivacyClear.cacheTypes) { [weak self] in // Fork (privacy-clear): every jar
            self?.announce("Cache cleared")
        }
    }

    func clearHistory() {
        history.forget()
        announce("History cleared")
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent(8) // Fork (new-tab-launcher): was everything().prefix(8), a sort of all history per read
    }

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        var id: String { host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func denyCapture() { answerCapture(.deny) }

    private func answerCapture(_ decision: WKPermissionDecision) {
        guard let decide else { return }
        // Remembered per site, so a call you take every week asks once.
        Store.settings.set(decision == .grant, forKey: "capture." + askedAbout)
        decide(decision)
        self.decide = nil
        askedAbout = ""
        asking = nil
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") {
            Store.settings.removeObject(forKey: key)
        }
        announce("Camera and microphone choices forgotten")
    }

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    @Published var editingPin: Tab.ID?

    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    func pin(_ tab: Tab) {
        // Fork: global pins — one set every space shows, kept by Spaces: the
        // tab leaves its space's row for the end of the pins, and every
        // window, on every space, has it at once.
        Spaces.shared.pin(tab, in: self)
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters — which is why it is not folded into this one.
        writeSession(now: true)
    }

    /// Change Letter, or a double-click on the square itself.
    func editLetter(_ tab: Tab) {
        guard tab.pin != nil else { return }
        editingPin = tab.id
    }

    /// Typed into the square. Empty leaves the letter as it was — a pinned tab
    /// with nothing on it would be a blank square you could never identify.
    func letter(_ typed: String, for tab: Tab) {
        guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return
        }
        Spaces.shared.renamePin(String(first), for: tab) // Fork: global pins — the letter is the same everywhere
    }

    func endPinEdit() {
        Spaces.shared.endPinEdit(self)
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        // Fork: global pins — out of every space's pins, into this window's
        // space at the head of its loose tabs.
        Spaces.shared.unpin(tab, in: self)
        writeSession(now: true)
        rememberSession()
    }

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""

    func beginTabEdit(_ tab: Tab) {
        guard let url = tab.address else {
            edit()
            return
        }
        tabDraft = Address.pretty(url)
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        guard let url = Google.destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        Trails.typed(into: tab, in: self) // Fork (trails): typed = a new trail, only while the flight is on
        tab.go(to: url)
    }

    func cancelTabEdit() {
        editingTab = nil
        tabDraft = ""
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published private(set) var announcement: String?

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() {
        guard let url = active?.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        announce("Address copied")
    }

    func announce(_ text: String) {
        announcement = text
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announcement = nil }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Announcements.seconds(text), execute: work) // Fork (announce-time): long enough to read — Fork/Announcements.swift
    }

    /// A download door is present in either chrome mode unless the page owns
    /// the whole window. Toasts remain the fallback only while the door cannot
    /// be seen (folded sidebar or immersed page).
    var downloadsDoorVisible: Bool {
        Downloads.shared.doorShowing && active?.immersed != true && (!prefs.sidebar || !folded)
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(prefs.downloads)
    }

    /// The names extensions asked their downloads to be saved under.
    var namedDownloads: [URL: String] = [:]

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    @Published private(set) var ghosts: [Ghost] = []

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// Downloads still under way. See `keep(_:)`.
    var downloading: [WKDownload] = []
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    private var hush: DispatchWorkItem?
    private var zoomShown = 100
    private var remembering = false
    /// The untouched blank tab created only for a reopened/new window. It is
    /// removed on close without affecting the shared real rows.
    private var windowBlankID: Tab.ID?
    /// Fork: windows — the tab another window took off this stage while it
    /// was the only one here. The stage says so and offers it back
    /// (`TakenStage`); cleared the moment anything is active here again.
    @Published var taken: Tab.ID?

    // MARK: - beginning and ending

    /// Fork: windows — nil for the window Copper launches with; the scene id
    /// of a window opened with ⌘N (Fork/Windows.swift).
    let windowID: UUID?
    var primary: Bool { windowID == nil }

    override convenience init() { self.init(window: nil) }

    init(window: UUID?) {
        windowID = window
        // Another window shares the first one's files instead of opening
        // its own copies of them, which would each write over the other.
        let first = window == nil ? nil : Windows.main
        prefs = first?.prefs ?? Preferences()
        bookmarks = first?.bookmarks ?? Bookmarks()
        history = first?.history ?? History()
        curtain = first?.curtain ?? Curtain()
        loot = first?.loot ?? Loot()
        super.init()
        guard primary else { joinAsWindow(); return }
        Shield.shared.enabled = prefs.shielded
        Shield.shared.compile()
        if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
        if prefs.bench { Bench.shared.start(for: self) }
        MCP.shared.start(for: self) // Fork: agents drive this window
        Updates.shared.start(for: self) // Fork: Copper feed updates
        welcoming = !prefs.welcomed
        // Once a day, quietly: is there a newer one?
        Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
        FormRelay.passkeysOffered = prefs.passkeys

        // The History menu lists what the history holds, and the menu is drawn
        // from this object's changes — so the history's are passed on.
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        watchVault()
        // An icon that arrives is put on every tab showing that site, not only
        // the one that happened to ask for it.
        Favicons.shared.arrived = { host, image in
            for tab in Windows.all.flatMap(\.tabs) where tab.address?.host()?.lowercased() == host {
                tab.icon = image
            }
        }
        wireFloater()

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            watchForSleep()
            Tab.touched = { [weak self] tab in if let owner = Windows.owner(of: tab) ?? self { Split.shared.touched(tab, in: owner) } }
            SpaceSwipe.watch(self)
            MouseButtons.watch(self) // Fork: thumb buttons back/forward, wheel click on the column
            Heat.shared.start(for: self)
        }

        CanvasImport.prepare() // Fork (canvas-hooks): every easel has a canvas before the session names one
        let saved = Session.read()
        Spaces.shared.restore(saved, into: self)
        guard !tabs.isEmpty else {
            // A blank tab costs nothing until it is asked for its page. Its
            // web view — and with it WebKit's helper processes — is built a
            // moment after the window is up, so that the first address typed
            // finds everything already running, and the first frame never
            // had to share the CPU with it.
            let tab = Tab()
            adopt(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak tab] in
                guard let tab, tab.isBlank else { return }
                _ = tab.web
            }
            return
        }
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        prefs.$shielded
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.apply(to: Windows.all.flatMap(\.tabs).compactMap { $0.built?.configuration.userContentController }) // Fork: windows
                announce(on ? "Ads and trackers blocked" : "Blocking off — reload to see the difference")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive \(Fork.name) — see ./bench" : "The bench is closed")
            }
            .store(in: &bag)

        prefs.$passkeys
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in Windows.all.flatMap(\.tabs) { // Fork: windows
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys offered again — reload the page" : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // WebKit read the defaults once at the start and keeps its own copy.
        // The only way to change its mind while running is the same action
        // the Edit menu would send it, which also writes the default back.
        prefs.$autocorrect
            .dropFirst()
            .sink { [weak self] on in
                guard let self, let web = active?.web else { return }
                // Fork (settings-browse): WebKit's toggle writes the app's own
                // defaults — in a test run, the real Copper's. There the
                // change waits for the next launch (`tellWebKit`).
                if Store.testing {
                    Preferences.tellWebKit(autocorrect: on)
                    announce(on ? "Autocorrect on" : "Autocorrect off")
                    return
                }
                let selector = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
                guard web.responds(to: selector) else { return }
                // Toggling is all there is, so it is only sent when the two
                // actually disagree.
                if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on {
                    web.perform(selector, with: nil)
                }
                Preferences.tellWebKit(autocorrect: on)
                announce(on ? "Autocorrect on" : "Autocorrect off")
            }
            .store(in: &bag)
    }

    private func relook() {
        Favicons.shared.relook(tabs.filter { !$0.asleep })
    }

    private func writeSession(now: Bool = false) {
        // Spaces owns the rows for every window; session.json is still the
        // single canonical tab store. windows.json records view state only.
        Session.write(now: now, Spaces.shared.shape(visible: tabs, active: activeID))
        if !primary { Windows.keep(self, now: now) }
    }

    private func rememberSession() {
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        writeSession(now: true)
    }

    // MARK: - Fork: windows

    /// The vault's index arriving a moment after unlock: an account list
    /// that is already open redraws with what came. (Fork: windows — every window)
    private func watchVault() {
        Bitwarden.shared.$cacheVersion.dropFirst()
            .merge(with: OnePassword.shared.$cacheVersion.dropFirst()) // Fork: 1Password
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let open = suggesting, let tab = tabs.first(where: { $0.id == open.tab }),
                      let host = curtain.host(of: tab.address) else { return }
                let rows = suggestions(for: tab, host: host)
                let credentials = rows.compactMap { suggestion -> Credential? in
                    guard case .credential(let credential) = suggestion else { return nil }
                    return credential
                }
                let isLogin = (tab.fieldFocus?.group ?? .login) == .login
                let pending = isLogin && Self.vaultPending // Fork: Bitwarden or 1Password locked/loading
                suggesting = rows.isEmpty && !pending
                    ? nil
                    : Suggesting(tab: tab.id, spot: open.spot, credentials: credentials, rows: rows)
            }
            .store(in: &bag)

    }

    /// The little window's own buttons, in every window. (Fork: windows)
    private func wireFloater() {
        // The little window's own three buttons.
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floating
            self.land()
            if let came, let tab = self.tabs.first(where: { $0.id == came }) {
                self.select(tab)
            }
            NSApp.activate(ignoringOtherApps: true)
            (Windows.window(of: self) ?? NSApp.windows.first { $0.contentView != nil })?.makeKeyAndOrderFront(nil) // Fork: windows
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let id = self.floating,
                  let tab = self.tabs.first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tabs.first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Isolate.where_) { found, _ in
                MainActor.assumeIsolated {
                    guard let pair = found as? [Any], pair.count == 2,
                          let through = pair[0] as? Double,
                          let playing = pair[1] as? Bool
                    else { return }
                    answer(through, playing)
                }
            }
        }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tabs.first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Isolate.toggle) { playing, _ in
                MainActor.assumeIsolated { answer((playing as? Bool) ?? true) }
            }
        }
        floater.onClose = { [weak self] in self?.land() }
    }

    /// A window opened with ⌘N shares the canonical Spaces rows. Only its
    /// current space and active tab are private view state; settings and the
    /// stores remain borrowed from the main browser.
    private func joinAsWindow() {
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        watchForSleep()
        watchVault()
        wireFloater()

        let saved = windowID.flatMap { Windows.savedState(for: $0) }
        let target = Spaces.shared.register(self, at: saved?.space)
        if let id = windowID, let (legacy, index) = Windows.legacy(id) {
            Spaces.shared.foldLegacy(legacy, active: index, into: self, space: target)
            Windows.markMigrated(id, space: target)
        }
        tabs = Spaces.shared.projection(target)
        // A brand-new window gets its own untouched blank tab on the shared
        // row. A reopened window instead resumes its saved active tab.
        if saved == nil || tabs.isEmpty {
            let tab = Tab()
            prepare(tab)
            tabs.append(tab)
            windowBlankID = tab.id
            activeID = tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tab] in
                guard let tab, tab.isBlank else { return }
                _ = tab.web
            }
        } else if let tab = Spaces.shared.pick(from: tabs, remembered: tabs.first { ($0.pending ?? $0.address)?.absoluteString == saved?.url }?.id, for: self, steal: false) {
            // The tab it was on, unless a window already up is showing it —
            // then another; a window coming back should not take a page off
            // the first window's stage.
            activeID = tab.id
            tab.touch()
            if !tab.wake() { tab.revive() }
        } else {
            let tab = Tab()
            prepare(tab)
            tabs.append(tab)
            windowBlankID = tab.id
            activeID = tab.id
        }
        Windows.keep(self, now: true)
    }

    /// A ⌘N window closed with the red button forgets only its view state.
    /// Tabs belong to the shared space rows and remain available elsewhere.
    func retire() {
        guard !primary else { return }
        dozing?.invalidate()
        dozing = nil
        pressure?.cancel()
        pressure = nil
        if floating != nil { land() }
        if Split.shared.holder === self { Split.shared.close() }
        // Out of the shared rows first, so what follows reaches only the
        // windows that remain. Then: Arc does not leave an untouched blank
        // tab behind when the window that made it closes. A real page, a
        // pin, or a shared row survives; a window left with nothing by the
        // blank's going gets a blank of its own (Spaces.publish).
        Spaces.shared.unregister(self)
        // Fork: global pins — a blank that was pinned is every window's now,
        // and is left alone: dropBlank would not find it in a row, and
        // closing it would leave a dead tab in every grid.
        if let id = windowBlankID, let tab = tabs.first(where: { $0.id == id }), tab.isBlank, tab.pin == nil {
            Spaces.shared.dropBlank(tab)
            tab.close()
        } else if let tab = active, tab.isBlank, tab.pin == nil, !Spaces.shared.shown(tab, outside: self) {
            // The blank this window was on — made for it when its last page
            // closed — and no other window's.
            Spaces.shared.dropBlank(tab)
            tab.close()
        }
        tabs = []
        activeID = nil
        taken = nil
        bag.removeAll()
    }

    // MARK: - tabs

    /// ⌘T. On a tab that is already blank this just puts the cursor back in the
    /// field — otherwise holding ⌘T leaves a row of identical empty tabs.
    func newTab() {
        // An extension's new tab page, if one asked and you said yes.
        if #available(macOS 15.4, *), let page = Extensions.shared.newTabPage {
            open(page, foreground: true)
            summoning = false
            launching = false
            rememberSession()
            return
        }
        launching = false
        if let active, active.isBlank {
            summoning = false
            editing = true
            typed = ""
            focusRequest += 1
            return
        }
        let tab = Tab()
        adopt(tab)
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        rememberSession()
        if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage(into: tab) }
    }

    /// A blank tab given an extension's new tab page: the page needs a view
    /// built from that extension's configuration, so it is a new tab in the
    /// blank one's place.
    func replaceBlank(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    func select(_ tab: Tab) {
        cancelTabEdit()
        summoning = false
        launching = false
        suggesting = nil
        if !tabs.contains(where: { $0.id == tab.id }), let space = Spaces.shared.spaceID(of: tab) {
            // Straight to this tab, not by way of the one the space last showed.
            Spaces.shared.select(space, in: self, landing: tab.id)
        }
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        guard tab.id != activeID else { return }
        // One WKWebView cannot be mounted in two stages. Selecting it here
        // hands it over and leaves its previous window on another tab.
        Spaces.shared.claim(tab, for: self)
        // Fork: if this tab is the one in the side pane, the two panes trade
        // places now rather than after the stage has drawn a frame with the
        // same page in both of them. See Split.arriving.
        Split.shared.arriving(tab, in: self)
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land() }
        leaving()
        activeID = tab.id
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it — and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if !tab.wake() { tab.revive() }
        rememberSession()
        editing = false
        typed = ""
    }

    /// Close one of Clear's tabs through the ordinary path and return the
    /// recently-closed record it created, so Undo can remove exactly those
    /// records without disturbing a person's other history.
    @discardableResult
    func closeForClear(_ tab: Tab) -> UUID? {
        let before = Set(ghosts.map(\.id))
        close(tab)
        return ghosts.last(where: { !before.contains($0.id) })?.id
    }

    /// Restore the live Tab objects captured by Clear. The close itself still
    /// went through `close(_:)`; this only puts those objects back in their
    /// original projection positions and removes the matching ghost records.
    func restoreClearedTabs(_ entries: [(tab: Tab, index: Int)], activeID: Tab.ID?,
                            blankID: Tab.ID?, ghostIDs: Set<UUID>) {
        var restored = tabs
        if let blankID, let blank = restored.first(where: { $0.id == blankID }) {
            restored.removeAll { $0.id == blankID }
            blank.close()
        }
        let ids = Set(entries.map { $0.tab.id })
        restored.removeAll { ids.contains($0.id) }
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            restored.insert(entry.tab, at: min(entry.index, restored.count))
        }
        tabs = restored
        ghosts.removeAll { ghostIDs.contains($0.id) }
        if let activeID, let tab = restored.first(where: { $0.id == activeID }) {
            self.activeID = nil
            select(tab)
        }
        rememberSession()
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves a blank tab
    /// behind; closing that blank tab closes the window.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        signedInWith[tab.id] = nil
        if tab.pin == nil { CanvasHost.forget(tab) } // Fork (canvas): its room closes with it

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to a
        // tab that no longer exists.
        if floating == tab.id { land() }

        // A pinned tab is not closed by ⌘W — it is put down. The letter keeps
        // its place, the page is let go, and you land on whatever you were
        // looking at before. Only Unpin takes it out of the row.
        if tab.pin != nil {
            // Fork: global pins — a pin is in every window's grid; one that
            // is on another window's stage is not this window's to put down.
            guard !Spaces.shared.shown(tab, outside: self) else { return }
            tab.rest()
            // Ordinary tabs first. Falling back to the most recent tab of any
            // kind meant closing one pin landed you on another pin, and ⌘W
            // bounced between the two instead of getting you out of them.
            let others = tabs.filter { $0.id != tab.id && !$0.asleep }
            let loose = others.filter { $0.pin == nil }
            if let back = landing(among: loose.isEmpty ? others : loose) { // Fork: windows — not one on another window's stage
                select(back)
            } else if let asleepPin = tabs.first(where: { $0.id != tab.id }) {
                select(asleepPin)
            } else {
                newTab()
            }
            writeSession(now: true)
            return
        }

        if tabs.count == 1 {
            if tab.isBlank {
                (Windows.window(of: self) ?? NSApp.keyWindow)?.performClose(nil) // Fork: windows — this browser's window, not whichever is key
            } else {
                let fresh = Tab()
                remember(tab, at: 0)
                tab.close()
                adopt(fresh)
                tabs = [fresh]
                Recent.shared.prune(tabs)
                activeID = fresh.id
                typed = ""
            }
            return
        }

        remember(tab, at: index)
        tab.close()
        tabs.remove(at: index)
        Recent.shared.prune(tabs)
        if activeID == tab.id {
            // The neighbour on the right, or the last one if there is no
            // right — through select(), same as everywhere else you land on
            // a tab, so one that was never built yet actually wakes up
            // instead of sitting there blank until a manual reload.
            select(landing(after: index)) // Fork: windows — unless another window is showing that one
        }
        rememberSession()
    }

    /// Everything but this one. Pinned tabs are put down rather than removed —
    /// they are not open pages so much as places kept.
    func closeOthers(but keep: Tab) {
        select(keep)
        // The list is read once: closing walks the row and can add to it.
        for tab in tabs.filter({ $0.id != keep.id }) {
            close(tab)
        }
        select(keep)
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text) else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// ⌘⇧T. Back into the row at the place it left.
    func reopen() {
        guard let ghost = ghosts.last else { return }
        reopen(ghost)
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        ghosts.removeAll { $0.id == ghost.id }
        let tab = Tab()
        prepare(tab)
        leaving()
        tabs.insert(tab, at: min(ghost.index, tabs.count))
        activeID = tab.id
        editing = false
        typed = ""
        tab.go(to: ghost.url)
    }

    private func remember(_ tab: Tab, at index: Int) {
        guard !tab.shy, let url = tab.address else { return }
        ghosts.append(Ghost(url: url, title: tab.title, index: index))
        if ghosts.count > 12 { ghosts.removeFirst() }
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        if tab.pin != nil {
            // Fork: global pins — the pins lead every row, so a pin's index
            // is its place in the grid, and the order is one for every space.
            Spaces.shared.movePin(tab, to: index)
            return
        }
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }),
              index != here, tabs.indices.contains(index)
        else { return }
        // The pinned block and the loose one don't mix: a letter that wandered
        // into the middle of the titles would stop meaning anything.
        let pinned = pinnedCount
        if index < pinned { return }
        tabs.move(fromOffsets: IndexSet(integer: here), toOffset: index > here ? index + 1 : index)
        rememberSession()
    }

    func step(_ direction: Int) {
        guard tabs.count > 1, let here = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let next = (here + direction + tabs.count) % tabs.count
        select(tabs[next])
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false) -> Tab {
        if let board = CanvasTabs.already(url, in: self, foreground: foreground) { return board } // Fork (canvas-hooks): one tab per board
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let tab = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(tab)
        let here = atEnd ? nil : tabs.firstIndex { $0.id == activeID }
        // Fork: global pins — beside a pin means the head of the loose tabs;
        // the pins are the same in every space and take no tab in among them.
        tabs.insert(tab, at: here.map { max($0 + 1, pinnedCount) } ?? tabs.count)
        tab.go(to: url)
        Recent.shared.prune(tabs)
        if foreground {
            leaving()
            activeID = tab.id
            editing = false
            typed = ""
        }
        return tab
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.current(url) }
        return url
    }

    /// The configuration for an extension's page, or nil for anything else.
    /// (Fork: or a canvas tab's, for a canvas's address — Fork/Canvas.)
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        if let canvas = CanvasHost.configuration(for: url) { return canvas } // Fork (canvas)
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    /// A page for the bench: at the end of the row, behind whatever you are
    /// looking at, and marked as not yours.
    @discardableResult
    func benchOpen(_ url: URL) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(bench: true, configuration: Browser.extensionConfiguration(for: url))
        prepare(tab)
        tabs.append(tab)
        tab.go(to: url)
        Recent.shared.prune(tabs)
        return tab
    }

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if CanvasJoinFlow.handle(url, in: self) { return }
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked — into a new one with ⌘
    /// held, or when the one you are on is busy playing in the float.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart, !active.floating {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true)
        }
    }

    /// ⌘⇧N. A tab that keeps nothing — its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        let tab = Tab(shy: true)
        adopt(tab)
        leaving()
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        announce("A tab that keeps nothing")
    }

    /// ⌘D. The same page, beside itself.
    func duplicate() {
        guard let url = active?.address else { return }
        open(url, foreground: true)
    }

    /// ⌘⇧V. What is in the clipboard, if it is a place — or a search.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = Google.destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    /// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
    func printPage() {
        guard let tab = active, !tab.isBlank, let window = NSApp.keyWindow else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let job = tab.web.printOperation(with: info)
        job.view?.frame = tab.web.bounds
        job.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    private func leaving() {
        lift(active, quietly: true)
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        if floater.showing {
            land()
            return
        }
        lift(active, quietly: false)
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    private func lift(_ tab: Tab?, quietly: Bool) {
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, !tab.isBlank, !tab.asleep, !floater.showing else { return }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. ⌘⇧P still lifts from anywhere.
        if quietly, !Players.knows(tab.address) { return }
        tab.web.evaluateJavaScript(Isolate.on) { [weak self] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (answer as? String) == "floating" else {
                    if !quietly { self.announce("Nothing is playing here") }
                    return
                }
                self.floating = tab.id
                tab.floating = true
                self.floater.lift(tab.web)
            }
        }
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    func land() {
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        guard let id = floating, let tab = tabs.first(where: { $0.id == id }) else { return }
        floating = nil
        tab.floating = false
        tab.web.evaluateJavaScript(Isolate.off)
    }

    private func suggestions(for tab: Tab, host: String) -> [Suggestion] {
        let kind = tab.fieldFocus?.kind
        let group = tab.fieldFocus?.group ?? .login
        let credentials: [Credential] = prefs.fillsPasswords
            ? Credentials.candidates(for: host, hint: tab.fieldHint)
            : []
        guard prefs.fillsPasswords || prefs.fillsEverything else { return [] }

        let fields: [Suggestion] = prefs.fillsEverything
            ? Autofill.fields(for: host, matching: tab.fieldFocus?.label ?? "").map(Suggestion.field)
            : []
        var rows: [Suggestion] = []
        if kind == .otp, prefs.fillsPasswords {
            let codes = codeCredentials(for: tab, host: host)
            if !codes.isEmpty { return codes.map(Suggestion.code) + fields }
        }
        switch group {
        case .login:
            rows += credentials.map(Suggestion.credential)
            if prefs.fillsEverything && credentials.isEmpty,
               (kind == .username || kind == .email) {
                rows += Autofill.topUsernames.map(Suggestion.username)
            }
            // Custom fields are deliberately after the normal account rows.
            rows += fields
        case .card:
            rows += fields
            if prefs.fillsEverything { rows += Autofill.cards.map(Suggestion.card) }
        case .identity:
            rows += fields
            if prefs.fillsEverything { rows += Autofill.identities.map(Suggestion.identity) }
        case .other:
            rows += fields
        }
        return rows
    }

    func prepare(_ tab: Tab) {
        tab.delegate = self
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            curtain.hide(selector, label: label, note: note, on: host)
            let css = curtain.css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            announce("Hidden — ⌘Z puts it back")
        }
        tab.onPickEnd = { [weak self] _ in self?.veiling = false }
        tab.onImageMenu = { [weak self] tab, url in self?.showImageMenu(for: tab, at: url) }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot in
            guard let self else { return }
            guard let spot else {
                if pickedInto == tab.id { pickedInto = nil }
                if codePickedInto == tab.id { codePickedInto = nil }
                guard suggesting?.tab == tab.id else { return }
                lowering?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, suggesting?.tab == tab.id else { return }
                    suggesting = nil
                }
                lowering = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                return
            }
            lowering?.cancel()
            guard (prefs.fillsPasswords || prefs.fillsEverything), tab.id == activeID,
                  pickedInto != tab.id || (tab.fieldFocus?.kind == .otp && codePickedInto != tab.id),
                  let host = curtain.host(of: tab.address)
            else { return }
            let rows = suggestions(for: tab, host: host)
            let credentials = rows.compactMap { suggestion -> Credential? in
                switch suggestion {
                case .credential(let credential), .code(let credential): return credential
                default: return nil
                }
            }
            let isLogin = (tab.fieldFocus?.group ?? .login) == .login
            // Only a login box stays visible while Bitwarden is locked or
            // loading, so it can offer the unlock control or say so.
            let pending = isLogin && Self.vaultPending // Fork: Bitwarden or 1Password locked/loading
            suggesting = (rows.isEmpty && !pending)
                ? nil
                : Suggesting(tab: tab.id, spot: spot, credentials: credentials, rows: rows)
        }

        tab.onCredentials = { [weak self] tab, host, user, password in
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host)
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if #available(macOS 15.4, *), Extensions.shared.passwordSavingTakenBy != nil { return }
            let known = Vault.logins(for: host)
            let target = Credentials.saveTarget
            // Nothing to ask about one that is already known. Only the
            // account with this name is read — one item, not the site's list.
            if target == .keychain, let same = known.first(where: { $0.user == user }) {
                if let full = Vault.resolve(same), full.password == password {
                    Vault.touch(full)
                    return
                }
            }
            let offer = Offer(
                login: Login(host: host, user: user, password: password, used: nil),
                changed: target == .keychain && known.contains { $0.user == user },
                target: target
            )
            // Bitwarden metadata deliberately omits the secret. For an
            // existing username, fetch that one secret asynchronously so an
            // unchanged sign-in is merely touched while a changed one reads
            // as an Update offer. New usernames can show the offer at once.
            if target != .keychain, // Fork: Bitwarden or 1Password
               let same = Credentials.candidates(for: host).first(where: {
                   $0.source == target.source && $0.user == user
               }) {
                Task { [weak self] in
                    do {
                        let current = try await Credentials.secret(same.id)
                        guard let self, self.prefs.savesPasswords else { return }
                        if current == password {
                            Credentials.touch(same)
                            return
                        }
                        guard self.offering != offer else { return }
                        self.offering = Offer(
                            login: offer.login, changed: true, target: offer.target
                        )
                    } catch {
                        // A transient Bitwarden read failure should not lose a
                        // human's save offer; show it as a new save.
                        guard let self, self.prefs.savesPasswords else { return }
                        guard self.offering != offer else { return }
                        self.offering = offer
                    }
                }
                return
            }
            guard offering != offer else { return }
            offering = offer
        }
        tab.onPickTrouble = { [weak self] _, reason in
            self?.announce("Couldn't hide that — \(reason)")
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            announce("\(percent)%")
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.rememberSession() }
            .store(in: &bag)

        tab.$title
            .dropFirst()
            .sink { [weak self, weak tab] title in
                guard let tab, !tab.shy, let url = tab.address else { return }
                self?.history.retitle(url, title)
            }
            .store(in: &bag)
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

    // MARK: - guessing

    /// ⌘K again, with ⌘ still down: one step further down the list.
    func stepSummon() {
        cycling = true
        walk(1)
    }

    /// ⌘ let go of: take whatever the walk landed on.
    func landSummon() {
        guard cycling else { return }
        cycling = false
        guard picked != nil else { return }
        submit()
    }

    /// ⌘K. Only what is open, nothing else.
    func summon() {
        reviewing = false
        cancelTabEdit()
        launching = false
        summoning = true
        typed = ""
        editing = true
        focusRequest += 1
    }

    /// Fork (new-tab-launcher): ⌘T, the way Arc has it — the card, asking
    /// where to, and no tab until there is an answer. An extension's new tab
    /// page, when one was allowed to take over, still gets the new tab.
    func launch() {
        if #available(macOS 15.4, *), Extensions.shared.newTabPage != nil {
            newTab()
            return
        }
        reviewing = false
        cancelTabEdit()
        Launcher.shared.begin()
        launching = true
        summoning = true
        typed = ""
        editing = true
        focusRequest += 1
    }

    /// Fork (new-tab-launcher): rows that arrived after the keystroke that
    /// asked for them — Google's completions, history ranked off the main
    /// thread. The row you had walked to stays the row you are on, by what it
    /// is rather than where it was.
    func relaunch(_ rows: [OmniboxSuggestion]) {
        guard launching else { return }
        let was = picked.flatMap { offers.indices.contains($0) ? offers[$0].url : nil }
        let index = picked
        offers = rows
        ending = completion(in: rows)
        if let index, index > 0, let was { picked = rows.firstIndex { $0.url == was } ?? min(index, rows.count - 1) }
        else { picked = rows.isEmpty ? nil : index }
    }

    private func guess() {
        walked = false // Fork (developer-shortcuts)
        if launching {
            offers = Launcher.shared.rows(for: typed, in: self)
            ending = completion(in: offers)
            // A question is answered by its first row; the empty card is a
            // list to walk down, and Return on nothing picked does nothing.
            picked = offers.isEmpty || typed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : 0
            return
        }
        guard !summoning else {
            offers = CommandBar.offers(for: typed, open: openPages(matching: typed), in: self)
            ending = completion(in: offers.filter { !CanvasLinks.isCanvas($0.url) }) // Fork (canvas-hooks): "canvas" never carries on into a canvas's id
            // The most recent page is already chosen, so ⌘K then Return is the
            // whole gesture.
            picked = offers.isEmpty ? nil : 0
            return
        }

        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = []
            ending = nil
            picked = nil
            return
        }

        // Three places and, if it can't be a place, a search. No open pages:
        // ⌘K exists for those, and mixing them in here made the list long
        // enough that reading it cost more than typing the address would have.
        var list = history.suggestions(for: typed, limit: 3)
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty,
           Address.url(from: typed) == nil,
           let asked = Google.url(for: typed) {
            list.append(
                OmniboxSuggestion(key: typed, title: Google.name, url: asked, kind: .search)
            )
        }
        offers = list
        ending = history.completion(for: typed, among: offers.filter { $0.kind != .open })
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
    }

    /// Fork (developer-shortcuts): ⌘T's and ⌘K's grey ending, for Tab to take.
    /// Their rows are commands and searches as well as places, and a command
    /// called "Exact time" must not finish "ex" ahead of example.com, so the
    /// ending comes from the places — open, visited, kept — and only from a
    /// search when there is no place at all.
    private func completion(in options: [OmniboxSuggestion]) -> String? {
        let addresses = options.filter { ["http", "https", "file"].contains($0.url.scheme?.lowercased() ?? "") }
        let places = addresses.filter { $0.kind != .search && $0.kind != .command }
        return history.completion(for: typed, among: places.isEmpty ? addresses : places)
    }

    /// What is open, most recently looked at first, filtered by what has been
    /// typed. On an empty field this is the whole point of the summon: it is
    /// the tab strip, except you read it only when you ask for it.
    private func openPages(matching typed: String) -> [OmniboxSuggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return tabs
            .filter { $0.id != activeID && !$0.isBlank }
            .filter { tab in
                guard !needle.isEmpty else { return true }
                let address = tab.address.map { Address.pretty($0) } ?? ""
                return tab.label.lowercased().contains(needle) || address.contains(needle)
            }
            .sorted {
                let leftKept = $0.pin != nil || Sections.shared.isSaved($0)
                let rightKept = $1.pin != nil || Sections.shared.isSaved($1)
                return leftKept == rightKept ? $0.touched > $1.touched : leftKept
            }
            .prefix(needle.isEmpty ? 6 : 3)
            .compactMap { tab in
                guard let url = tab.address else { return nil }
                return OmniboxSuggestion(
                    key: tab.label,
                    title: Address.pretty(url),
                    url: url,
                    kind: .open,
                    tab: tab.id
                )
            }
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: OmniboxSuggestion) {
        if launching { Launcher.shared.take(offer, in: self); return }
        summoning = false
        if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
            select(tab)
        } else {
            (active ?? tabs.first)?.go(to: offer.url)
        }
        editing = false
        typed = ""
        picked = nil
    }

    /// Fork (new-tab-launcher): the card put away after ⌘T has done what was
    /// picked — which may have been to open a tab, switch to one, or nothing.
    func landed() {
        launching = false
        summoning = false
        typed = ""
        picked = nil
        // A blank tab behind the card keeps its own field; anything else goes
        // back to being a page.
        if active?.isBlank == false { editing = false }
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten.
    func stopCompleting() { ending = nil }

    /// Fork (developer-shortcuts): Tab. Take what the field is offering — the
    /// row the arrows walked to, else the grey ending, else the row ⌘T or ⌘K
    /// picked for you — and put it in the field with the caret after it, as if
    /// it had been typed (so the rows are the ones for the new text). It only
    /// edits the field: nothing opens, and no tab is switched to. False when
    /// there was nothing to take.
    @discardableResult
    func acceptCompletion() -> Bool {
        let row = picked.flatMap { offers.indices.contains($0) ? offers[$0] : nil }
        let text: String
        if walked, let row, let words = words(for: row) {
            text = words
        } else if let ending, !ending.isEmpty {
            text = typed + ending
        } else if let row, let words = words(for: row) {
            text = words
        } else {
            return false
        }
        typed = text
        ending = nil
        return true
    }

    /// What a row puts in the field. The address bar already shows a walked
    /// row as its key. ⌘T's and ⌘K's rows read as titles and commands, so
    /// there it is the place's address, or the words of a search — and
    /// nothing for a command, whose name is not worth keeping as text.
    private func words(for row: OmniboxSuggestion) -> String? {
        guard summoning else { return row.key }
        if row.kind == .search {
            return URLComponents(url: row.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
        }
        guard row.kind != .command, ["http", "https", "file"].contains(row.url.scheme?.lowercased() ?? "") else { return nil }
        return Address.pretty(row.url) + (row.url.query.map { "?" + $0 } ?? "")
    }

    /// Fork (developer-shortcuts): the arrows have moved since the last
    /// keystroke, so the row they are on is what Tab takes.
    private var walked = false

    /// The arrow keys walk the list, and walking off the top lets go of it.
    func walk(_ step: Int) {
        guard !offers.isEmpty else { return }
        walked = true // Fork (developer-shortcuts)
        switch picked {
        case nil:
            picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
    }

    // MARK: - the address field

    /// ⌘L. The current address comes up selected, so typing over it replaces it
    /// and Escape puts it back.
    func edit() {
        summoning = false
        launching = false
        typed = active?.address?.absoluteString ?? ""
        editing = true
        focusRequest += 1
    }

    func dismiss() {
        // Fork (new-tab-launcher): Escape out of ⌘T leaves nothing behind —
        // not even the words in the field of a blank tab under the card.
        if launching { typed = "" }
        summoning = false
        launching = false
        cycling = false
        // A blank tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { return }
        editing = false
        typed = ""
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so.
    func submit() {
        // Fork (new-tab-launcher): ⌘T has its own idea of what Return does.
        if launching {
            if let picked, offers.indices.contains(picked) { Launcher.shared.take(offers[picked], in: self) }
            else { Launcher.shared.take(typed: typed, in: self) }
            return
        }
        // A page already open is switched to, not opened again.
        if let picked, offers.indices.contains(picked), let id = offers[picked].tab {
            summoning = false
            editing = false
            typed = ""
            // In this row, or in another space's.
            if let tab = tabs.first(where: { $0.id == id }) { select(tab) } else { _ = Spaces.shared.reveal(id, in: self) }
            return
        }
        if let picked, offers.indices.contains(picked), CommandBar.run(offers[picked].url, in: self) {
            summoning = false
            editing = false
            typed = ""
            return
        }

        // The switcher proposes nothing but pages you have open. It still has
        // to accept an address typed into it, though — the two fields look
        // alike, and a Return that quietly does nothing is the worst answer
        // either of them could give.
        if summoning {
            summoning = false
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
                editing = false
                return
            }
        }

        let target: URL?
        if let picked, offers.indices.contains(picked) {
            target = offers[picked].url
        } else if ending != nil {
            target = Address.url(from: completed)
        } else {
            target = Google.destination(for: typed)
        }

        guard let url = target else {
            refusals += 1
            return
        }
        if CanvasJoinFlow.handle(url, in: self) { editing = false; typed = ""; return }
        Trails.typed(into: active ?? tabs.first, in: self) // Fork (trails): typed = a new trail, only while the flight is on
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    // MARK: - the page

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }
    func resetZoom() { active?.resetZoom() }

    /// ⌥⌘R. The article, and nothing that was arranged around it.
    func toggleReader() {
        guard let tab = active else { return }
        tab.toggleReader { [weak self] worked in
            guard !worked else { return }
            self?.announce("Nothing to read on this page")
        }
    }

    /// ⌘⇧R. Keep identity and saved page state, but fetch this site's page
    /// caches from origin before displaying it again.
    func hardReload() {
        guard active != nil else { return }
        announce("Cache cleared — reloading")
        active?.hardReload()
    }

    /// ⌘⇧I. WebKit exposes the inspector picker only through its private
    /// inspector object; `Inspect` contains the defensive bridge and fallback.
    func inspectElement() {
        guard let tab = active else { return }
        // A tab still asleep has no page to inspect: asking for its web view
        // would build an empty one and open the inspector on about:blank.
        // Waking it loads the page first, as reload() does.
        tab.wake()
        let state = Inspect.element(in: tab)
        if !state.available { announce("Right-click › Inspect Element") }
    }

    func reload() { active?.reload() }
    func back() { active?.back() }
    func forward() { active?.forward() }
}

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self) {
            decisionHandler(.cancel)
            return
        }
        // Fork (canvas): copper://canvas/<id> loads the canvas page here, and
        // a canvas page goes nowhere else (Fork/Canvas/CanvasHost.swift).
        if CanvasHost.decide(action, url: url, in: webView, browser: self) {
            decisionHandler(.cancel)
            return
        }
        // Canvas join links are consumed by native Copper, including links
        // clicked inside ordinary pages. A different cloud's HTTPS landing
        // page remains a normal web navigation.
        if CanvasJoinFlow.handle(url, in: self) {
            decisionHandler(.cancel)
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it. Middle-click does what ⌘-click does, for hands
        // that learned it that way. (Fork: WebKit's button numbers are a mask
        // and the wheel button is 4, not AppKit's 2 — see MouseButtons.)
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme) {
            let flags = action.modifierFlags
            MouseButtons.noteLinkClick(action)
            if flags.contains(.command) || MouseButtons.isMiddle(action) {
                let opened = open(url, foreground: flags.contains(.shift))
                Trails.opened(opened, from: tab(for: webView), in: self) // Fork (trails): lineage, only while the flight is on
                decisionHandler(.cancel)
                return
            }
        }

        // Fork (extension-pages): an extension's page leaving for the web
        // goes in a view that can show it (Fork/ExtensionPages.swift).
        if ExtensionPages.leave(action, url: url, in: webView, browser: self) {
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: curtain.css(on: host))
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host)
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if CanvasHost.popup(action, from: webView, browser: self) { return nil } // Fork (canvas-hooks): a window from a board's live frame is an ordinary tab (Fork/Canvas/CanvasFrames)
        if ExtensionPages.popup(action, from: webView, browser: self) { return nil } // Fork (extension-pages): an extension page's window at a web address is an ordinary tab
        let from = tab(for: webView)?.id ?? activeID
        let tab = Tab(shy: tab(for: webView)?.shy ?? false, configuration: configuration)
        adopt(tab)
        tab.opener = from
        // A target=_blank link ⌘-clicked or middle-clicked stays behind, the
        // way the same click on any other link does (Fork: MouseButtons).
        let flags = action.modifierFlags
        let behind = MouseButtons.isMiddle(action) || (flags.contains(.command) && !flags.contains(.shift))
        if !behind {
            activeID = tab.id
            editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Page, file, or nothing — Fork (download-policy): see
    /// Fork/DownloadPolicy.swift for why this is no longer just
    /// `canShowMIMEType`.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        switch DownloadPolicy.decide(response) {
        case .show: decisionHandler(.allow)
        case .download: decisionHandler(.download)
        case .drop(let reason):
            decisionHandler(.cancel)
            if let reason, let tab = tab(for: webView) {
                tab.uncover()
                tab.failure = reason
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
        guard navigationResponse.isForMainFrame, let tab = tab(for: webView) else { return }
        // Fork (download-policy): the tab forgets the file's address, so
        // nothing fetches — and saves — it a second time.
        tab.becameDownload()
        // A tab that exists only for this file — a link that opened it in a
        // new window, a ⌘-click, an address typed into ⌘T — has nothing left
        // to show once it is a file: close it and go back to where the click
        // came from, as Chrome and Safari do, rather than leave a blank tab.
        if webView.backForwardList.currentItem == nil, tab.pin == nil, tabs.count > 1 {
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, tab.built?.backForwardList.currentItem == nil else { return }
                if let opener = tab.opener, let home = self.tabs.first(where: { $0.id == opener }) {
                    self.select(home)
                }
                self.close(tab)
            }
        }
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(_ download: WKDownload) {
        download.delegate = self
        downloading.append(download)
        Downloads.shared.began(
            download,
            name: download.originalRequest?.url?.lastPathComponent,
            from: download.originalRequest?.url?.host
        )
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
        let key = "\(host)|\(type.rawValue)"

        if let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // One question at a time. A second page asking while the first is still
        // waiting is refused rather than queued behind it.
        guard decide == nil else {
            decisionHandler(.deny)
            return
        }

        decide = decisionHandler
        askedAbout = key
        asking = CaptureAsk(host: host, wants: Browser.name(for: type))
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        if tab.pin != nil { Spaces.shared.unpin(tab, in: self) }
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and once it has
        // drawn (`renderingProgressDidChange`, below) the picture of the old
        // one goes. This is the fallback for a view that never says so —
        // long enough that a page which does say so is never undercut, and a
        // flash of unpainted ground never stands in for a page still coming.
        // (Fork: wake-cover — was 0.45 s, ahead of many a first paint.)
        tab.uncover(after: 1.2)
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
        // Fork (wake-cover): the page is painted, so the picture of its old
        // self can go — the moment Safari takes its own down. A beat after
        // the view's own fade-in, so the two never cross over the ground.
        tab(for: webView)?.uncover(after: 0.15)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = tab(for: webView), let url = tab.address else { return }
        tab.uncover()
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history.record(url, title: tab.title)
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        tab(for: webView)?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        tab(for: webView)?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView }
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)

        guard !prefs.asksWhereToSave else {
            // Fork (settings-browse): a test run never puts a save panel on
            // somebody's screen; the bench answers it (Fork/SettingsBrowse.swift).
            if Store.testing {
                guard let url = DownloadAsk.answer(name, in: prefs.downloads) else {
                    completionHandler(nil)
                    return
                }
                completionHandler(url)
                Downloads.shared.destined(download, to: url)
                announce("Downloading \(url.lastPathComponent)")
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = prefs.downloads
            panel.canCreateDirectories = true
            // Fork (settings-browse): a sheet on this window rather than a
            // modal that froze every window until it was answered.
            SettingsPanels.present(panel, on: Windows.window(of: self)) { [weak self] url in
                guard let url else {
                    completionHandler(nil)
                    return
                }
                completionHandler(url)
                Downloads.shared.destined(download, to: url)
                self?.announce("Downloading \(url.lastPathComponent)")
            }
            return
        }

        let destination = Browser.free(name, in: prefs.downloads)
        completionHandler(destination)
        Downloads.shared.destined(download, to: destination)
        announce("Downloading \(name)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        Downloads.shared.finished(download)
        guard let file = download.progress.fileURL else {
            if !downloadsDoorVisible { announce("Download finished") }
            return
        }
        loot.add(
            Keep(
                name: file.lastPathComponent,
                from: download.originalRequest?.url?.host() ?? "",
                path: file.path,
                date: Date()
            )
        )
        if !downloadsDoorVisible { announce("Saved \(file.lastPathComponent)") }
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloading.removeAll { $0 === download }
        Downloads.shared.failed(download, error: error, resumeData: resumeData)
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if !cancelled && !downloadsDoorVisible { announce("Download failed") }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}






