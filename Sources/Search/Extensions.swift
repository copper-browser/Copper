import AppKit
import SwiftUI
import WebKit
import Combine

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the same one Safari runs its
// extensions on, reading the same manifest.json a Chrome extension ships.
// What is here is the browser's half of the contract — which tabs exist and
// which one is in front, what a new tab or a popup means in this window, who
// is asked for a permission and how — plus the Chrome Web Store install
// (Crx.swift) and the APIs WebKit doesn't have, filled in natively
// (ExtensionShims.swift, ExtensionNative.swift).
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab
// is represented to WebKit by a small adapter kept here. A tab can be in the
// row with no web view at all — asleep, or put down — and is reported with
// none; `built` is read, never `web`, which would make one.

/// One installed extension, as the list in Settings shows it.
struct Installed: Codable, Identifiable, Equatable {
    /// The Chrome Web Store id, or "local-…" for one loaded from a folder.
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// The permissions it was installed with, so an update that asks for more
    /// is asked about rather than slipped through.
    var permissions: [String]
    /// Kept in the row beside the menu rather than only in it. Optional, so
    /// a list written before there was pinning still reads.
    var pinned: Bool? = nil
    /// For one loaded from a folder: where that folder is, so Reload can
    /// bring the author's latest edits in.
    var source: String? = nil
    /// Fork (ardia profiles): the profiles it runs in ("" is Shared), or nil
    /// for every profile — what everything installed before profiles had
    /// their own extensions is, and what an install from Shared is.
    var profiles: [String]? = nil

    /// Whether it runs in that profile's tabs (nil: Shared).
    func reaches(_ profile: String?) -> Bool { profiles.map { $0.contains(Profiles.key(profile)) } ?? true }

    /// Its profiles with one more, from an install there: from Shared, every
    /// profile; already everywhere, as it was.
    static func adding(_ profile: String?, to profiles: [String]?) -> [String]? {
        guard let profile, let profiles else { return nil }
        return profiles.contains(profile) ? profiles : profiles + [profile]
    }
}

@available(macOS 15.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    /// Shared's: the list, the installs, the buttons in the window. Fork
    /// (ardia profiles): each other profile has an instance of its own — a
    /// controller with its own storage, told only its own tabs, running only
    /// what reaches that profile (`Installed.profiles`) — made the first time
    /// one of its pages is built. The list lives here; theirs is a copy.
    static let shared = Extensions(profile: nil)
    private(set) static var others: [String: Extensions] = [:]
    /// Nil for Shared.
    let profile: String?

    static var every: [Extensions] { [shared] + others.values }

    /// A profile's instance, made (and started) the first time it is asked for.
    static func of(profile: String?) -> Extensions {
        guard let profile else { return shared }
        if let known = others[profile] { return known }
        let made = Extensions(profile: profile)
        others[profile] = made
        made.installed = shared.installed
        if let browser = shared.browser { made.start(for: browser) }
        DispatchQueue.main.async { shared.follow() } // its tabs are the new one's now, told after this page is built
        return made
    }

    /// The instance whose extensions the page in front sees. Made here if
    /// need be: making one publishes nothing at once, so a view's body may ask.
    static var front: Extensions { of(profile: Profiles.front) }

    /// The instance a context was loaded into.
    static func owner(of context: WKWebExtensionContext) -> Extensions {
        every.first { $0.controller === context.webExtensionController } ?? shared
    }

    /// One extension's contexts, one per profile it is running in.
    static func contexts(of id: String) -> [WKWebExtensionContext] { every.compactMap { $0.contexts[id] } }

    /// The extension, as the page in front runs it — else as any profile does.
    func context(_ id: String) -> WKWebExtensionContext? {
        Extensions.front.contexts[id] ?? contexts[id] ?? Extensions.contexts(of: id).first
    }

    /// Every page view built for a tab is handed the controller at birth —
    /// it can't be given one later. Its profile's (Fork: ardia profiles), by
    /// the store it was given.
    static func attach(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = of(profile: Profiles.of(store: configuration.websiteDataStore)).controller
    }

    let controller: WKWebExtensionController
    @Published private(set) var installed: [Installed] = []
    /// The loaded ones, by id.
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes — icon, badge, enabled.
    @Published private(set) var actionsChanged = 0
    @Published private(set) var busy: String?
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    @Published private(set) var errors: [String: [String]] = [:]

    func noteError(_ text: String, for id: String) {
        // Fork (ardia profiles): said on Shared's, which Settings reads.
        guard profile == nil else { return Extensions.shared.noteError(text, for: id) }
        var list = errors[id] ?? []
        list.append(text)
        errors[id] = Array(list.suffix(40))
    }

    weak var browser: Browser?
    private var adapters: [Tab.ID: ExtensionTab] = [:]
    private var order: [Tab.ID] = []
    private var watching: [Tab.ID: [AnyCancellable]] = [:]
    private var bag = Set<AnyCancellable>()
    private(set) lazy var window = ExtensionWindow(owner: self)
    /// Where each extension's button is on screen, for its popup to hang from.
    /// Fork (ardia profiles): one set, Shared's, the buttons' own.
    var anchors: [String: WeakView] {
        get { profile == nil ? ownAnchors : Extensions.shared.anchors }
        set { if profile == nil { ownAnchors = newValue } else { Extensions.shared.anchors = newValue } }
    }
    private var ownAnchors: [String: WeakView] = [:]

    static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome — Copper uses the same ids. Servers allow
    /// their own extension in by that origin (Raindrop's refuses any other),
    /// and sites look for an extension at it. WebKit's own
    /// webkit-extension:// is what Copper used before; addresses kept from
    /// then are read as the new ones.
    static let scheme = "chrome-extension"
    static let formerScheme = "webkit-extension"

    static func current(_ url: URL) -> URL {
        guard url.scheme == formerScheme, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = scheme
        return parts.url ?? url
    }
    private static var list: URL { folder.appendingPathComponent("installed.json") }
    static func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    private init(profile: String?) {
        self.profile = profile
        if profile == nil { WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme) }
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords. A profile keeps its own, salted like its jar.
        let configuration: WKWebExtensionController.Configuration = if let profile {
            .init(identifier: Spaces.storeID(forProfile: profile, kind: 0xC0FF_EE01))
        } else if Store.testing && !Store.ownContainer {
            .init(identifier: Store.probeStore(2))
        } else {
            .default()
        }
        let jar = profile.map(Spaces.store(forProfile:)) ?? Store.sharedWebsites
        configuration.defaultWebsiteDataStore = jar
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        // Its own configuration starts with WebKit's default store; an
        // extension's pages keep what they store where the browser does —
        // and a test run's apart from the real one's.
        views.websiteDataStore = jar
        // The same user agent as the web tabs, to the letter. WebKit gives
        // workers the user agent of the last page that loaded and, when it
        // differs, stops the running workers to apply it — and extension
        // workers it then never starts again: every page that opened killed
        // the extensions. Extensions are told they run in Chrome by the shim
        // instead (navigator.userAgent in their pages and workers).
        views.applicationNameForUserAgent = Web.userAgentName
        // A test run sits behind other windows, where WebKit slows its views
        // to a crawl and messages between an extension's popup and its
        // worker stop arriving. Not what anyone is testing.
        if Store.testing, !Store.measuring { views.preferences.inactiveSchedulingPolicy = .none }
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        guard profile == nil else { return } // its list is Shared's (`of(profile:)`)
        installed = (try? JSONDecoder().decode([Installed].self, from: Data(contentsOf: Extensions.list))) ?? []
    }

    // MARK: - starting

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        // Fork (ardia profiles): a profile whose pages were built before the
        // first window was, now that there is one.
        if profile == nil { for other in Extensions.others.values { other.start(for: browser) } }
        controller.didOpenWindow(window)
        browser.feed(\.tabs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.follow() }
            .store(in: &bag)
        // Fork (extension-pages): a tab coming or going in a space not on
        // screen changes what extensions see too.
        Spaces.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.follow() }
            .store(in: &bag)
        browser.feed(\.activeID)
            .removeDuplicates()
            .scan((nil, nil)) { ($0.1, $1) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pair in self?.activated(from: pair.0, to: pair.1) }
            .store(in: &bag)
        Task {
            // One after another, a moment apart: started all at once, WebKit
            // fails some of their workers and never tries them again.
            for item in installed where item.enabled && item.reaches(profile) {
                await load(item)
                if contexts[item.id]?.webExtension.hasBackgroundContent == true {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            if profile == nil { checkForUpdates() }
        }
    }

    // MARK: - the row, as WebKit sees it

    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    /// Private tabs keep nothing and see no extensions. Every space's tabs,
    /// not only the one on screen (Fork: ExtensionPages.every).
    /// Fork (ardia profiles): this profile's tabs only — its pages are the
    /// ones built with its controller.
    var visibleTabs: [Tab] {
        let all = ExtensionPages.every(in: browser)
        return Profiles.any ? all.filter(mine) : all
    }

    var activeAdapter: ExtensionTab? {
        // The window in front's page, not always the first window's. (Fork: windows)
        guard let tab = Windows.current.active ?? browser?.active, !tab.shy, mine(tab) else { return nil }
        return adapter(for: tab)
    }

    /// A tab of this profile's (Fork: ardia profiles).
    func mine(_ tab: Tab) -> Bool { Profiles.of(tab) == profile }

    private func follow() {
        // Fork (perf): nothing to tell until an extension is loading. With
        // none installed this ran over every tab of every space — 264 adapters
        // made at launch, then a quadratic walk on every tab change and space
        // switch — for a controller with no extension to hear it. The first
        // load catches up (`track()`), before that extension starts.
        guard tracking else { return }
        let now = visibleTabs
        let ids = now.map(\.id)
        let present = Set(ids)
        let known = Set(order)
        let gone = order.filter { !present.contains($0) }
        for id in gone {
            if let adapter = adapters[id] { controller.didCloseTab(adapter, windowIsClosing: false) }
            adapters[id] = nil
            watching[id] = nil
        }
        for tab in now where !known.contains(tab.id) {
            controller.didOpenTab(adapter(for: tab))
            watch(tab)
        }
        // Moves: anything whose position changed among the ones that stayed.
        let stayed = order.filter { present.contains($0) }
        let staying = Set(stayed)
        let newOrder = ids.filter { staying.contains($0) }
        for (index, id) in stayed.enumerated() where newOrder[index] != id {
            if let adapter = adapters[id] { controller.didMoveTab(adapter, from: index, in: window) }
        }
        order = ids
    }

    /// Fork (perf): the tabs and the one in front, told to the controller the
    /// first time an extension is about to load — what `start` used to do for
    /// every launch, extensions or none.
    private var tracking = false
    private func track() {
        guard !tracking else { return }
        tracking = true
        follow()
        activated(from: nil, to: browser?.activeID)
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        func changed(_ properties: WKWebExtension.TabChangedProperties) {
            guard let adapter = adapters[id] else { return }
            controller.didChangeTabProperties(properties, for: adapter)
        }
        watching[id] = [
            tab.$title.dropFirst().removeDuplicates().sink { _ in changed(.title) },
            tab.$address.dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            tab.$loading.dropFirst().removeDuplicates().sink { _ in changed(.loading) },
            tab.$pin.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in changed(.pinned) },
        ]
    }

    private func activated(from old: Tab.ID?, to new: Tab.ID?) {
        guard tracking else { return } // Fork (perf): see `track()`
        guard let new, let tab = browser?.tabs.first(where: { $0.id == new }), !tab.shy, mine(tab) else { return }
        let previous = old.flatMap { id in browser?.tabs.first(where: { $0.id == id }) }.flatMap { mine($0) ? adapter(for: $0) : nil }
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
        bump()
    }

    /// The buttons drawn again: they watch Shared's instance, whichever
    /// profile's extension changed (Fork: ardia profiles).
    private func bump() { Extensions.shared.actionsChanged += 1 }

    // MARK: - loading

    @discardableResult
    private func load(_ item: Installed) async -> Bool {
        // Fork (ardia profiles): only where it runs, once at a time.
        guard item.reaches(profile) else { return false }
        if contexts[item.id] != nil { return true }
        guard loading.insert(item.id).inserted else { return false }
        defer { loading.remove(item.id) }
        // The shim this build of Copper carries, in place of whatever the
        // build that installed it carried.
        try? ExtensionShims.prepare(Extensions.folder(for: item.id))
        do {
            let found = try await WKWebExtension(resourceBaseURL: Extensions.folder(for: item.id))
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and everything an extension keeps in its own pages
            // — localStorage, IndexedDB — is filed under its origin.
            if let stable = URL(string: "\(Extensions.scheme)://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: everything it asked for then is
            // granted each time it loads. Optional ones are asked for when
            // the extension asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            for pattern in found.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            applySiteChoices(context) // Fork: sites taken back on the Extensions page stay taken back
            track() // Fork (perf): the tabs, before the first extension hears anything
            try controller.load(context)
            watch(context)
            if contexts[item.id] == nil, loadsThisRun.contains(item.id) { loadedBefore.insert(item.id) }
            loadsThisRun.insert(item.id)
            contexts[item.id] = context
            bump()
            return true
        } catch {
            NSLog("Extensions: couldn't load %@: %@", item.id, error.localizedDescription)
            return false
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts[id] else { return }
        try? controller.unload(context)
        contexts[id] = nil
        bump()
    }

    /// Ids being loaded now (Fork: ardia profiles — `settle` and a switch
    /// can ask for the same one at once).
    private var loading: Set<String> = []

    private func save() {
        try? FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: Extensions.list, options: .atomic)
        // Fork (ardia profiles): every profile's copy of the list, and what
        // each runs, follow it.
        for other in Extensions.others.values {
            other.installed = installed
            Task { await other.settle() }
        }
    }

    /// Fork (ardia profiles): running exactly what is on and reaches this
    /// profile — loaded what isn't yet, unloaded what no longer should be.
    func settle() async {
        for id in contexts.keys where !installed.contains(where: { $0.id == id && $0.enabled && $0.reaches(profile) }) { unload(id) }
        for item in installed where item.enabled && item.reaches(profile) && contexts[item.id] == nil { await load(item) }
    }

    /// Fork (ardia profiles): an extension's files taken up afresh in every
    /// profile it runs in (Reload, an update). True unless every start failed.
    private func restart(_ id: String) async -> Bool {
        var tried = false, started = false
        for owner in Extensions.every {
            owner.unload(id)
            guard let item = owner.installed.first(where: { $0.id == id }), item.enabled, item.reaches(owner.profile) else { continue }
            tried = true
            if await owner.load(item) { started = true }
        }
        return started || !tried
    }

    /// Fork (ardia profiles): the profiles an extension runs in, from its
    /// Settings page. Nil: every profile.
    func setProfiles(_ id: String, _ profiles: [String]?) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].profiles = profiles
        save()
        Task { await settle() }
    }

    // MARK: - installing

    /// A store link or an id, from the field in Settings or the bar that
    /// shows on a store page.
    /// `confirm: false` is for the bench in a test run only — there is no
    /// way to reach it from the real browser.
    /// Fork (ardia profiles): `profile` is where it was asked for (the store
    /// page's tab, else the page in front): it runs there, or everywhere from
    /// Shared. One installed in another profile already is added to this one.
    func install(from text: String, confirm: Bool = true, in profile: String? = Profiles.front) {
        guard let id = Crx.id(in: text) else {
            browser?.announce(Crx.Refused.notAnID.localizedDescription)
            return
        }
        if let item = installed.first(where: { $0.id == id }) {
            guard !item.reaches(profile) else {
                browser?.announce("Already installed")
                return
            }
            setProfiles(id, Installed.adding(profile, to: item.profiles))
            browser?.announce("\(item.name) is added to \(profile ?? "every profile")")
            return
        }
        busy = id
        Task {
            defer { busy = nil }
            do {
                let crx = try await Crx.fetch(id)
                let zip = try Crx.verifiedZip(crx, id: id)
                let target = Extensions.folder(for: id)
                let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
                try Crx.unpack(zip, into: staged)
                try ExtensionShims.prepare(staged)
                try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: confirm || !Store.testing, in: profile)
            } catch {
                browser?.announce(error.localizedDescription)
            }
        }
    }

    /// A store extension the person has already agreed to in bulk — Flow's
    /// "Extensions" switch is the consent, so no second dialog per item. Runs
    /// to completion so a caller can install a list one after another instead
    /// of racing twenty downloads and twenty prompts. True when it landed.
    /// Fork (ardia profiles): `profiles` as another Mac had them (iCloud
    /// sync); a list from Move in runs everywhere, as it did in that browser.
    func installAgreed(id text: String, enabled: Bool = true, profiles: [String]? = nil) async -> Bool {
        guard let id = Crx.id(in: text) else { return false }
        if installed.contains(where: { $0.id == id }) { return true }
        busy = id
        defer { busy = nil }
        do {
            let crx = try await Crx.fetch(id)
            let zip = try Crx.verifiedZip(crx, id: id)
            let target = Extensions.folder(for: id)
            let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged)
            try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: false, enabled: enabled, profiles: profiles)
            return installed.contains(where: { $0.id == id })
        } catch {
            NSLog("Copper: Flow could not install extension %@: %@", id, error.localizedDescription)
            return false
        }
    }

    /// An unpacked extension from disk — a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        // Fork (settings-browse): a sheet on the window, not a modal that
        // froze every window until it was answered.
        SettingsPanels.present(panel, on: browser.flatMap(Windows.window(of:)) ?? Links.window) { [weak self] source in
            guard let source else { return }
            self?.installFolder(at: source)
        }
    }

    func installFolder(at source: URL, confirm: Bool = true, in profile: String? = Profiles.front) {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            browser?.announce("That folder has no manifest.json")
            return
        }
        let id = "local-" + String(UUID().uuidString.prefix(8)).lowercased()
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            try ExtensionShims.prepare(staged)
        } catch {
            browser?.announce("Couldn't copy the extension")
            return
        }
        Task { try? await admit(staged, as: id, fromStore: false, finalFolder: Extensions.folder(for: id), confirm: confirm || !Store.testing, source: source, in: profile) }
    }

    /// Takes the extension up again — the way Chrome's reload button does
    /// in developer mode. One loaded from a folder is copied in afresh from
    /// that folder first, so what its author just saved is what runs.
    func reload(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let target = Extensions.folder(for: id)
        if let path = installed[index].source {
            let source = URL(fileURLWithPath: path, isDirectory: true)
            let files = FileManager.default
            guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                browser?.announce("The folder \(installed[index].name) was loaded from is gone")
                return
            }
            let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
            do {
                try? files.removeItem(at: staged)
                try files.copyItem(at: source, to: staged)
                try ExtensionShims.prepare(staged)
                try? files.removeItem(at: target)
                try files.moveItem(at: staged, to: target)
            } catch {
                try? files.removeItem(at: staged)
                browser?.announce("Couldn't copy \(installed[index].name) again")
                return
            }
        }
        for owner in Extensions.every { owner.unload(id) } // Fork (ardia profiles): in every profile it runs in
        errors[id] = nil
        Task {
            if let found = try? await WKWebExtension(resourceBaseURL: target),
               let index = installed.firstIndex(where: { $0.id == id }) {
                installed[index].name = found.displayName ?? installed[index].name
                installed[index].version = found.version ?? installed[index].version
                installed[index].permissions = found.requestedPermissions.map(\.rawValue).sorted()
                save()
            }
            guard let item = installed.first(where: { $0.id == id }), item.enabled else { return }
            browser?.announce(await restart(id) ? "\(item.name) reloaded" : "\(item.name) couldn't start — see Settings › Extensions")
        }
    }

    /// An extension whose worker won't start again: unloaded and loaded,
    /// as a relaunch would — at most once a minute, so one that can never
    /// start doesn't go round in circles.
    private var revived: [String: Date] = [:]
    /// Recent failed native messages, per extension and host.
    private var failures: [String: [Date]] = [:]

    /// Loaded at least once since the browser started, and loaded again.
    private var loadsThisRun: Set<String> = []
    private(set) var loadedBefore: Set<String> = []

    func revive(_ id: String, because reason: String) {
        guard let item = installed.first(where: { $0.id == id }), item.enabled,
              Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return }
        revived[id] = Date()
        noteError("restarted the extension: \(reason)", for: id)
        // Its popup goes with it; it is opened again once the extension is back.
        let popup = ExtensionPopup.shared.extensionID == id ? ExtensionPopup.shared.view?.url : nil
        let anchor = anchors[id]?.view?.window != nil ? anchors[id]?.view : anchors[Extensions.menuAnchor]?.view
        unload(id)
        Task {
            guard await load(item), let popup, let context = contexts[id] else { return }
            ExtensionPopup.shared.show(popup, for: context, from: anchor)
        }
    }

    /// WebKit records a worker that failed to start as an error on its
    /// context, and then doesn't try again: the extension would be dead
    /// until someone noticed. It is taken up afresh as soon as that shows.
    private var errorWatchers: [String: NSObjectProtocol] = [:]
    private func watch(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        errorWatchers[id] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let e = error as NSError
                    return e.domain == WKWebExtensionContext.errorDomain && e.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.contexts[id] === context else { return }
                    self.revive(id, because: "its worker failed to start")
                }
            }
        }
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned = on
        save()
        actionsChanged += 1
    }

    /// Reads what was unpacked, asks, and — on yes — moves it into place and
    /// loads it. On no, nothing is left behind.
    /// Fork (ardia profiles): asked for in `profile` (it runs there, or
    /// everywhere from Shared), unless `profiles` says where.
    private func admit(_ staged: URL, as id: String, fromStore: Bool, finalFolder: URL, confirm: Bool = true, source: URL? = nil, enabled: Bool = true,
                       in profile: String? = nil, profiles: [String]? = nil) async throws {
        let files = FileManager.default
        let found: WKWebExtension
        do {
            found = try await WKWebExtension(resourceBaseURL: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
        let name = found.displayName ?? id
        let wants = Extensions.describe(found, in: staged)
        let accepted = confirm ? await ask(install: name, wants: wants, icon: found.icon(for: CGSize(width: 64, height: 64))) : true
        guard accepted else {
            try? files.removeItem(at: staged)
            return
        }
        try? files.removeItem(at: finalFolder)
        try files.moveItem(at: staged, to: finalFolder)
        let item = Installed(
            id: id, name: name, version: found.version ?? "?", enabled: enabled, fromStore: fromStore,
            permissions: found.requestedPermissions.map(\.rawValue).sorted(),
            source: source?.path,
            profiles: profiles ?? profile.map { [$0] }
        )
        installed.removeAll { $0.id == id }
        installed.append(item)
        save()
        let started: Bool
        // Where it was asked for; the other profiles' settle as `save` told them.
        let owner: Extensions? = item.reaches(profile) ? Extensions.of(profile: profile) : Extensions.every.first(where: { item.reaches($0.profile) })
        if enabled, let owner { started = await owner.load(item) }
        else { started = true }
        if started {
            browser?.announce("\(name) is installed")
        } else {
            browser?.announce("\(name) is installed, but WebKit couldn't start it")
        }
    }

    func remove(_ id: String) {
        for owner in Extensions.every { owner.unload(id) } // Fork (ardia profiles)
        errors[id] = nil
        Extensions.setSettings([:], for: id)
        Store.settings.removeObject(forKey: "extensions.granted.\(id)")
        Extensions.forgetSites(id) // Fork
        loadsThisRun.remove(id)
        loadedBefore.remove(id)
        Store.settings.removeObject(forKey: "extensions.newtab.\(id)")
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: Extensions.folder(for: id))
    }

    // MARK: - new tab pages

    /// The page an extension asks to show in new tabs, from the one added
    /// last — once you've said yes to it. Nil while nobody asks, or you
    /// said no.
    var newTabPage: URL? {
        guard let (id, url) = newTabCandidate else { return nil }
        return Store.settings.object(forKey: "extensions.newtab.\(id)") as? Bool == true ? url : nil
    }

    private var newTabCandidate: (String, URL)? {
        for item in installed.reversed() where item.enabled {
            if let url = contexts[item.id]?.overrideNewTabPageURL { return (item.id, url) }
        }
        return nil
    }

    /// Chrome asks the first time an extension's page takes the place of
    /// the new tab — an extension that did it quietly could be anything.
    /// So does Copper, and then shows the page in the tab just opened.
    func offerNewTabPage(into tab: Tab) {
        guard let (id, url) = newTabCandidate, Store.settings.object(forKey: "extensions.newtab.\(id)") == nil,
              let name = installed.first(where: { $0.id == id })?.name else { return }
        Task {
            let yes = await ask("Show “\(name)” in new tabs?", detail: "It asked to replace the new tab page. You can change this later in Settings › Extensions.",
                                icon: contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Keep It", no: "Don't Allow")
            Store.settings.set(yes, forKey: "extensions.newtab.\(id)")
            if yes, tab.isBlank, let browser { browser.replaceBlank(tab, with: url) }
        }
    }

    /// What an extension set through chrome.privacy and chrome.proxy.
    static func settings(for id: String) -> [String: Any] {
        Store.settings.dictionary(forKey: "extensions.settings.\(id)") ?? [:]
    }

    static func setSettings(_ values: [String: Any], for id: String) {
        if values.isEmpty { Store.settings.removeObject(forKey: "extensions.settings.\(id)") }
        else { Store.settings.set(values, forKey: "extensions.settings.\(id)") }
    }

    /// The extension, on and running, that asked the browser not to offer to
    /// save passwords — a password manager doing the saving itself.
    var passwordSavingTakenBy: String? {
        installed.first { $0.enabled && $0.reaches(Profiles.current) && Extensions.settings(for: $0.id)["privacy.services.passwordSavingEnabled"] as? Bool == false }?.name
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save() // Fork (ardia profiles): the other profiles settle from here
        if on {
            Task { await load(installed[index]) }
        } else {
            unload(id)
        }
    }

    func openOptions(_ id: String) {
        guard let url = context(id)?.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    // MARK: - updates

    /// Once a day, the store is asked whether anything installed from it has
    /// a newer version; if so it is fetched, checked and swapped in. One that
    /// asks for more than it was installed with is asked about first.
    func checkForUpdates() {
        let key = "extensions.checked"
        let last = Store.settings.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        Store.settings.set(Date(), forKey: key)
        for item in installed where item.fromStore {
            Task { await update(item) }
        }
    }

    private func update(_ item: Installed) async {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(item.id)&v=\(item.version)&uc"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              xml.contains("status=\"ok\""),
              let version = xml.range(of: #"version="([^"]+)""#, options: .regularExpression)
                .map({ String(xml[$0].dropFirst(9).dropLast()) }),
              version != item.version
        else { return }
        do {
            let zip = try Crx.verifiedZip(try await Crx.fetch(item.id), id: item.id)
            let staged = Extensions.folder.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let wants = Set(found.requestedPermissions.map(\.rawValue))
            if !wants.isSubset(of: Set(item.permissions)) {
                guard await ask(install: "An update to \(item.name)", wants: Extensions.describe(found, in: staged), icon: found.icon(for: CGSize(width: 64, height: 64))) else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
            }
            for owner in Extensions.every { owner.unload(item.id) } // Fork (ardia profiles): every profile's copy
            let target = Extensions.folder(for: item.id)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            if let index = installed.firstIndex(where: { $0.id == item.id }) {
                installed[index].version = found.version ?? version
                installed[index].permissions = wants.sorted()
                save()
                if installed[index].enabled { _ = await restart(item.id) }
            }
        } catch {
            NSLog("Extensions: update of %@ failed: %@", item.id, error.localizedDescription)
        }
    }

    /// The page the manifest names for the button, when WebKit hasn't said.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let path = action?["default_popup"] as? String, !path.isEmpty else { return nil }
        // Relative to the extension, and keeping a query it may carry.
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    // MARK: - asking

    /// What an extension wants, in words.
    static func describe(_ found: WKWebExtension, in folder: URL) -> [String] {
        var out: [String] = []
        // Leaving out what Copper itself added to the manifest.
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String] ?? [])
        let declared = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? [])
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
            out.append("Read and change what's on " + (hosts.prefix(4).joined(separator: ", ")) + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [WKWebExtension.Permission: String] = [
            .tabs: "See your open tabs and their addresses",
            .cookies: "Read and change cookies",
            .webNavigation: "See where you go",
            .webRequest: "See the requests pages make",
            .declarativeNetRequest: "Block or change requests pages make",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to apps on this Mac",
            .scripting: "Run scripts in pages",
        ]
        for (permission, sentence) in words where found.requestedPermissions.contains(permission) && !added.contains(permission.rawValue) {
            out.append(sentence)
        }
        // Chrome's own, which Copper answers itself.
        let ours: [(String, String)] = [
            ("userScripts", "Run scripts you add to it on websites"), ("history", "Read and change your history"),
            ("bookmarks", "Read and change your bookmarks"), ("downloads", "Manage your downloads"),
            ("privacy", "Change your privacy settings"), ("browsingData", "Clear your browsing data"),
            ("management", "See your other extensions"), ("notifications", "Show notifications"),
        ]
        for (name, sentence) in ours where declared.contains(name) { out.append(sentence) }
        return out
    }

    private func ask(install name: String, wants: [String], icon: NSImage?) async -> Bool {
        await ask(
            "Add “\(name)” to \(Fork.name)?",
            detail: wants.isEmpty ? "It doesn't ask for anything special." : "It will be able to:\n• " + wants.joined(separator: "\n• "),
            icon: icon, yes: "Add Extension", no: "Cancel"
        )
    }

    /// An extension asking, through permissions.request, for one of the
    /// permissions Copper answers itself.
    func ask(more names: String, context: WKWebExtensionContext) async -> Bool {
        await ask("asks for more access", detail: names, context: context)
    }

    private func ask(_ question: String, detail: String, context: WKWebExtensionContext) async -> Bool {
        await ask(
            "\(context.webExtension.displayName ?? "An extension") \(question)",
            detail: detail, icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            yes: "Allow", no: "Don't Allow"
        )
    }

    /// The last question asked, so the next waits for its answer.
    private var question: Task<Bool, Never>?
    /// For the bench, in a test run only: answer every question this way
    /// instead of asking. Nil asks.
    var answerForTests: Bool?
    /// What was asked, for the bench.
    private(set) var asked: [String] = []

    /// One question at a time, as a sheet on the browser's window. An alert
    /// run modally would stop the whole browser — pages, downloads, every
    /// other extension — for as long as it waits, and an extension can ask
    /// when nobody is looking.
    private func ask(_ title: String, detail: String, icon: NSImage?, yes: String, no: String) async -> Bool {
        let before = question
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await before?.value
            self?.asked.append(title)
            if Store.testing, let answer = self?.answerForTests { return answer }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let icon { alert.icon = icon }
            alert.addButton(withTitle: yes)
            alert.addButton(withTitle: no)
            guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        question = task
        return await task.value
    }

    // MARK: - the buttons

    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
    }

    /// The list behind the puzzle button.
    @Published var menuOpen = false
    /// A popup is up. (Fork) The address pill only shows its buttons under
    /// the pointer, and has to keep them while one hangs from them.
    @Published var popupShowing = false
    /// Where a popup hangs when its extension isn't pinned: the puzzle button.
    static let menuAnchor = "__menu"

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        // Fork (ardia profiles): the extensions of the page in front's profile.
        let owner = Extensions.front
        let tab = owner.activeAdapter
        return installed.compactMap { item in
            guard let context = owner.contexts[item.id], let action = context.action(for: tab) else { return nil }
            return Button(
                id: item.id,
                name: item.name,
                label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badge: action.badgeText,
                enabled: action.isEnabled,
                pinned: item.pinned ?? false
            )
        }
    }

    func press(_ id: String) {
        let owner = Extensions.front // Fork (ardia profiles): the page in front's profile's
        guard let context = owner.contexts[id] else { return }
        let activeAdapter = owner.activeAdapter
        if let tab = activeAdapter { context.userGesturePerformed(in: tab) }
        // An extension that asked for its button to open its side panel.
        if ExtensionShims.panelOnClick.contains(id), context.action(for: activeAdapter)?.presentsPopup != true {
            ExtensionShims.openPanel(context, owner: owner)
            return
        }
        // A popup is opened here, straight away. Left to WebKit, it builds
        // a popup of its own first, and closing that one in favour of
        // Copper's lost the new popup's first messages to its worker.
        if context.action(for: activeAdapter)?.presentsPopup == true, let url = popupURL(for: context) {
            let own = anchors[id]?.view
            ExtensionPopup.shared.show(url, for: context, from: own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view)
            return
        }
        context.performAction(for: activeAdapter)
    }

    /// The page the button's popup is now: one the extension set for this
    /// tab or for all of them, else its manifest's.
    private func popupURL(for context: WKWebExtensionContext) -> URL? {
        let set = ExtensionShims.popups[context.uniqueIdentifier] ?? [:]
        let path = browser?.active.flatMap { set[$0.id.uuidString] } ?? set["*"]
        guard let path else { return Extensions.popupURL(for: context) }
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// A keystroke an extension registered for — unless it is one of
    /// Copper's own. Extensions hear a key before the app's shortcuts do, and
    /// a manifest may suggest any key at all: Claude's suggests ⌘E for its
    /// side panel, which took the agent pane's key from everyone who had it
    /// installed, and the pane never opened. A key one of Copper's menus
    /// carries stays Copper's, as a browser's own shortcuts do in Chrome.
    func take(_ event: NSEvent) -> Bool {
        guard !Extensions.ownKey(event) else { return false }
        for context in Extensions.front.contexts.values where context.command(for: event) != nil { // Fork (ardia profiles)
            return context.performCommand(for: event)
        }
        return false
    }

    /// True when an item in the app's menus answers to this keystroke,
    /// enabled or not — a key Copper uses only some of the time is still its.
    static func ownKey(_ event: NSEvent) -> Bool { ownKey(event, in: NSApp.mainMenu) }

    static func ownKey(_ event: NSEvent, in menu: NSMenu?) -> Bool {
        guard let menu, let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else { return false }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(modifiers)
        return menu.items.contains { item in
            if let submenu = item.submenu { return ownKey(event, in: submenu) }
            let key = item.keyEquivalent
            guard !key.isEmpty, key.lowercased() == typed else { return false }
            // "E" with ⌘ is ⇧⌘E: AppKit reads a capital as the shift.
            var mask = item.keyEquivalentModifierMask.intersection(modifiers)
            if key != key.lowercased() { mask.insert(.shift) }
            return mask == flags
        }
    }

    /// Right-click items an extension added, for the page's menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard !tab.shy else { return [] }
        // Fork (ardia profiles): the tab's own profile's extensions.
        let owner = Extensions.of(profile: Profiles.of(tab))
        guard owner === self else { return owner.menuItems(for: tab) }
        let adapter = adapter(for: tab)
        return contexts.values.flatMap { $0.menuItems(for: adapter) }
    }
}

// MARK: - WebKit asks, the browser answers

@available(macOS 15.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        let url = configuration.url ?? URL(string: "about:blank")!
        let tab = browser.open(url, foreground: configuration.shouldBeActive, atEnd: true)
        if configuration.shouldBePinned { browser.pin(tab) }
        return adapter(for: tab)
    }

    /// One window, on purpose. A new window's pages become tabs in this one.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let browser else { return nil }
        for (index, url) in configuration.tabURLs.enumerated() {
            browser.open(url, foreground: index == 0 && configuration.shouldBeFocused, atEnd: true)
        }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return await ask("asks for more access", detail: detail, context: extensionContext) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        // WebKit asks this the way Safari does: whenever an extension reaches
        // for a page it has no host permission for — listing tabs, running a
        // script in one — often with nobody having touched anything. Chrome
        // never asks there: the extension has the sites its manifest named,
        // the page it was clicked on (activeTab), and the ones it asked for
        // through permissions.request. So neither does Copper.
        asked.append("(refused) \(extensionContext.webExtension.displayName ?? "?") → \(Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", "))")
        return ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "every website" : matchPatterns.map(\.string).sorted().joined(separator: ", ")
        return await ask("wants to read and change \(what)", detail: "Until you remove the extension.", context: extensionContext) ? (matchPatterns, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        bump()
    }

    /// The popup page, in a popover of the browser's own (ExtensionPopup
    /// says why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Extensions.popupURL(for: context)
        action.closePopup()
        guard let url else { return }
        let own = anchors[context.uniqueIdentifier]?.view
        let anchor = own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view
        ExtensionPopup.shared.show(url, for: context, from: anchor)
    }

    /// `runtime.sendNativeMessage`. To "search" — the APIs WebKit doesn't
    /// have, answered by this app. To anything else — a Chrome native
    /// messaging host installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            return try await ExtensionShims.answer(message, from: extensionContext, owner: self)
        }
        let id = extensionContext.uniqueIdentifier, host = applicationIdentifier!
        do {
            return try await ExtensionNative.send(message, to: host, from: id)
        } catch {
            // An extension asking an app that isn't there, over and over —
            // a retry loop — is answered slowly once it has asked a dozen
            // times in a second, so it can't swamp the browser.
            let key = id + "→" + host, now = Date()
            failures[key] = (failures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
            if (failures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
    }

    /// `runtime.connectNative`. Answered before this call returns, never
    /// after a hop: until WebKit hears back, what the extension posts on the
    /// port is queued, and WebKit (macOS 15.4–26) hands its queue back to the
    /// extension's own `port.onMessage` instead of to the host. An extension
    /// that writes at once after connecting — 1Password's NmRequestAccounts
    /// and NmAuthorizePartnerBrowser — then hears its own question, which
    /// never reaches the app (`t.content is not an Object`). Fork
    /// (native-connect-sync); docs/passwords.md.
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        // The shim's port to the browser itself, made only to reach the
        // prototype every port shares (port-own-disconnect); it closes it.
        if port.applicationIdentifier == ExtensionShims.application {
            completionHandler(nil)
            return
        }
        do {
            try ExtensionNative.connect(port, from: extensionContext.uniqueIdentifier)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

// MARK: - adapters

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    private var browser: Browser? { owner.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab else { return NSNotFound }
        return owner.visibleTabs.firstIndex { $0.id == tab.id } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { ExtensionPages.view(of: tab, in: owner.controller) } // Fork (extension-pages, ardia profiles)
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.address }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab?.id == browser?.activeID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pin != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.built?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.built?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { return }
        if pinned, tab.pin == nil { browser.pin(tab) }
        if !pinned, tab.pin != nil { browser.unpin(tab) }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.magnify(to: CGFloat(zoomFactor))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { tab?.go(to: url) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.forward() }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.select(tab)
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.close(tab)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = tab?.built else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    init(owner: Extensions) { self.owner = owner }

    private var nsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frameAutosaveName == "search" }
            ?? NSApp.mainWindow
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        owner.visibleTabs.map(owner.adapter(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { owner.activeAdapter }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate(ignoringOtherApps: true)
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - the buttons in the row

/// The extensions, behind one puzzle button — a list to press them from,
/// pin them out of, reload or remove them. The pinned ones also sit in the
/// row beside it, the way Chrome does it. Nothing at all below macOS 15.4
/// or with nothing installed.
struct ExtensionSlot: View {
    /// The side the list opens toward: down from the top row, out to the
    /// right from the sidebar.
    var edge: Edge = .bottom
    /// Fork: the sidebar's address pill shows the buttons only while the
    /// pointer is over it, the way Arc does. Nil is always shown, as in
    /// the top row.
    var reveal: Bool? = nil
    /// Fork: a tinted column's ink and hover, as `Door` takes them.
    var ink: Color? = nil
    var glow: Color? = nil
    /// Fork: where the puzzle button goes instead of opening the list —
    /// the pill sends it to the Extensions page, and keeps the list on a
    /// right-click.
    var manage: (() -> Void)? = nil

    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionButtons(extensions: .shared, edge: edge, reveal: reveal, ink: ink, glow: glow, manage: manage)
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionButtons: View {
    @ObservedObject var extensions: Extensions
    let edge: Edge
    var reveal: Bool? = nil
    var ink: Color? = nil
    var glow: Color? = nil
    var manage: (() -> Void)? = nil

    /// What is on screen, which trails what is wanted by a moment on the
    /// way out: a row pressed in the list closes the list a beat before its
    /// popup opens, and the puzzle button it hangs from has to still be
    /// there when it does.
    @State private var shown = false
    /// Bumped by every change, so a late hide from an earlier one lets go.
    @State private var turn = 0

    /// Under the pointer, or holding up a popover of its own.
    private var wanted: Bool {
        guard let reveal else { return true }
        return reveal || extensions.menuOpen || extensions.popupShowing
    }

    var body: some View {
        if !extensions.installed.isEmpty {
            Group {
                if reveal == nil || shown {
                    buttons
                        .transition(.opacity.combined(with: .offset(x: 6)))
                }
            }
            .onAppear { shown = wanted }
            .onChange(of: wanted) { _, now in
                turn += 1
                if now {
                    withAnimation(Motion.quick) { shown = true }
                } else {
                    let mine = turn
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if turn == mine { withAnimation(Motion.quick) { shown = false } }
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            ForEach(extensions.buttons.filter(\.pinned)) { button in
                ActionButton(button: button, ink: ink, glow: glow) { extensions.press(button.id) }
                    .background(Anchor(id: button.id))
                    .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
            }
            // Rightmost, whichever way it opens.
            Door(icon: "puzzlepiece.extension", on: extensions.menuOpen,
                 help: manage == nil ? "Extensions" : "Manage extensions",
                 ink: ink, glow: glow) {
                if let manage { manage() } else { extensions.menuOpen.toggle() }
            }
            .background(Anchor(id: Extensions.menuAnchor))
            .popover(isPresented: $extensions.menuOpen, arrowEdge: edge) {
                ExtensionMenu(extensions: extensions)
            }
            .contextMenu {
                if manage != nil {
                    SwiftUI.Button("Show Extensions List") { extensions.menuOpen = true }
                    SwiftUI.Button("Manage Extensions…") { manage?() }
                    Divider()
                    SwiftUI.Button("Chrome Web Store…") { extensions.browser?.open(Browser.webStore, foreground: true) }
                    SwiftUI.Button("Load Unpacked…") { extensions.installFolder() }
                }
            }
        }
    }

    private struct ActionButton: View {
        let button: Extensions.Button
        var ink: Color? = nil
        var glow: Color? = nil
        let press: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: press) {
                ExtensionIcon(button: button, size: 15, ink: ink)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hovering ? (glow ?? Palette.hover) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(button.label)
        }
    }

    /// A real view under the button, so the popup has something to hang from.
    private struct Anchor: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            Extensions.shared.anchors[id] = WeakView(view)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            Extensions.shared.anchors[id] = WeakView(view)
        }
    }
}

/// An extension's icon with its badge in the corner.
@available(macOS 15.4, *)
private struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat
    /// Fork: the letter of one with no icon, in a tinted column's ink.
    var ink: Color? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = button.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                } else {
                    // Its initial, rather than a puzzle piece that would
                    // pass for the button the list opens from.
                    Text(button.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(ink?.opacity(0.72) ?? Palette.muted)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(ink?.opacity(0.1) ?? Palette.wash))
                }
            }
            .frame(width: size + 4, height: size + 4)
            .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                Text(button.badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }
}

/// What a right-click on an extension offers, in the row and in the list.
@available(macOS 15.4, *)
private struct ExtensionActions: View {
    let id: String
    let name: String
    let extensions: Extensions

    var body: some View {
        let pinned = extensions.installed.first { $0.id == id }?.pinned ?? false
        SwiftUI.Button(pinned ? "Unpin" : "Pin to Toolbar") { extensions.setPinned(id, !pinned) }
        if extensions.context(id)?.optionsPageURL != nil {
            SwiftUI.Button("Options…") { extensions.openOptions(id) }
        }
        SwiftUI.Button("Reload") { extensions.reload(id) }
        Divider()
        SwiftUI.Button("Remove “\(name)”…") { ExtensionActions.confirmRemove(id, name: name, extensions) }
    }

    static func confirmRemove(_ id: String, name: String, _ extensions: Extensions) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its settings and data go with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { extensions.remove(id) }
    }
}

/// The list, drawn off screen — for the bench, which can't keep a popover
/// open in a browser that isn't in front.
@available(macOS 15.4, *)
@MainActor
func extensionMenuPicture() -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: ExtensionMenu(extensions: .shared))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}

/// The list behind the puzzle button: every running extension, a pin for
/// each, and the way to Settings.
@available(macOS 15.4, *)
private struct ExtensionMenu: View {
    @ObservedObject var extensions: Extensions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let buttons = extensions.buttons
            if buttons.isEmpty {
                Text("None of your extensions is on")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(buttons) { button in
                            Row(button: button, extensions: extensions)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("storefront", "Chrome Web Store…") {
                    extensions.menuOpen = false
                    extensions.browser?.open(Browser.webStore, foreground: true)
                }
                Foot("folder", "Load Unpacked…") {
                    extensions.menuOpen = false
                    DispatchQueue.main.async { extensions.installFolder() }
                }
                Foot("gearshape", "Manage Extensions…") {
                    extensions.menuOpen = false
                    // Fork: through `openSettings`, which also moves the
                    // panel's own page — the key alone left it on the last one.
                    extensions.browser?.openSettings(.extensions)
                }
            }
            .padding(6)
        }
        .frame(width: 280)
        .background(Palette.ground)
    }

    private struct Row: View {
        let button: Extensions.Button
        @ObservedObject var extensions: Extensions
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 9) {
                ExtensionIcon(button: button, size: 16)
                Text(button.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering, extensions.installed.first(where: { $0.id == button.id })?.source != nil {
                    Tool(symbol: "arrow.clockwise", help: "Reload from its folder") { extensions.reload(button.id) }
                }
                if hovering || button.pinned {
                    Tool(symbol: button.pinned ? "pin.fill" : "pin", help: button.pinned ? "Unpin" : "Pin to toolbar", on: button.pinned) {
                        extensions.setPinned(button.id, !button.pinned)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                // The list goes first; the popup, if there is one, then
                // hangs from the puzzle button it came out of.
                extensions.menuOpen = false
                let id = button.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.press(id) }
            }
            .onHover { hovering = $0 }
            .help(button.label)
            .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
        }
    }

    /// A small icon button at the end of a row.
    private struct Tool: View {
        let symbol: String
        let help: String
        var on = false
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}
