import Combine
import Foundation

// The sync engine. Six domains, each off until the person turns it on in
// Settings › Cloud:
//
//   spaces     the spaces and the tabs kept in them (pins and Saved)
//   settings   the look-and-behaviour settings in CloudSettingsKeys
//   bookmarks  the bookmarks tree
//   tabs       this Mac's open tabs, for the other Macs to look at (one
//              way: nothing of another Mac's ever opens here by itself)
//   history    places visited, append-only
//   canvas     the Personal canvas's room (Fork/Canvas/). Not a document
//              here: the switch only says whether Personal may connect —
//              `syncs(.canvas)`, read by `Canvases.room(for:)`. Shared
//              canvases live on the cloud by definition and ignore it.
//
// Pushing: a change here (Preferences, Bookmarks and History publish theirs;
// the session file's writes say when tabs and spaces moved) waits two quiet
// seconds, then the domain's document is built and, if it differs from the
// last one synced, PUT with that one's version. A 409 hands back the
// server's copy: merged three ways (CloudMerge), written here with
// `applyingRemote` set so writing it doesn't count as a change, and PUT
// again. Pulling: at sign-in, at "Turn on sync", on every reconnect of the
// event stream, and on each event another Mac's write causes.
//
// Nothing runs while signed out. The token never reaches the log.

/// The cloud's own log, a few hundred lines, no secrets. Posted onto the
/// main actor so any thread (and Cloud's own initialiser) can write to it.
enum CloudLog {
    static func note(_ text: String) {
        Task { @MainActor in CloudSync.shared.note(text) }
    }
}

@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    enum Domain: String, CaseIterable, Identifiable {
        case spaces, settings, bookmarks, tabs, history, canvas

        var id: String { rawValue }

        var title: String {
            switch self {
            case .spaces: return "Spaces and kept tabs"
            case .settings: return "Settings"
            case .bookmarks: return "Bookmarks"
            case .tabs: return "Open tabs"
            case .history: return "History"
            case .canvas: return "Personal canvas"
            }
        }

        var detail: String {
            switch self {
            case .spaces: return "Your spaces — names, colours, themes, order — and their pinned and Saved tabs. Today's tabs stay on this Mac."
            case .settings: return "How Copper looks and behaves: appearance, sidebar, tab switching and sleep, swipes, blocking, autocorrect, archiving. Never passwords, paths or keys."
            case .bookmarks: return "The whole bookmarks tree, folders and all."
            case .tabs: return "Let your other Macs see the tabs open here, and open them from there. Nothing opens by itself."
            case .history: return "Places you visit, so the address field knows them everywhere. Clearing history here, or forgetting a page, deletes it on the cloud too, on a cloud that can."
            case .canvas: return "Your Personal canvas follows you between Macs. Shared canvases always live on the cloud — that is what sharing means."
            }
        }

        var symbol: String {
            switch self {
            case .spaces: return "square.stack"
            case .settings: return "slider.horizontal.3"
            case .bookmarks: return "bookmark"
            case .tabs: return "macbook.and.iphone"
            case .history: return "clock.arrow.circlepath"
            case .canvas: return "scribble.variable"
            }
        }
    }

    enum State: Equatable {
        case idle, syncing, error(String), offline

        var text: String {
            switch self {
            case .idle: return "Up to date"
            case .syncing: return "Syncing…"
            case .error(let message): return message
            case .offline: return "Can't reach the cloud — will retry"
            }
        }
    }

    /// Another Mac's open tabs.
    struct DeviceTabs: Identifiable, Equatable {
        var id: String { domain }
        let domain: String
        let deviceId: UUID?
        let name: String
        let updated: Date?
        let version: Int64
        let tabs: [CloudDocs.Tabs.Open]
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    @Published private(set) var log: [Entry] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var otherDevices: [DeviceTabs] = []
    /// Mirrors of what cloud.json keeps, for the page to bind to. (The
    /// canvas switch is kept in cloud-sync.json — see `canvasSwitch`.)
    /// Either changing posts `didChange`.
    @Published private(set) var on = false {
        didSet { if on != oldValue { CloudSync.announce() } }
    }
    @Published private(set) var enabled: Set<Domain> = [] {
        didSet { if enabled != oldValue { CloudSync.announce() } }
    }

    /// `on` or `enabled` changed: the canvas host starts or stops Personal's room.
    static let didChange = Notification.Name("CloudSync.didChange")

    private static func announce() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private weak var browser: Browser?
    private var started = false
    private var applyingRemote = false
    private var bag: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var stamps: [String: Date] = [:]
    private var waiting: Set<Domain> = []
    private var timer: DispatchWorkItem?
    private var busy = 0
    /// Sync now passes running. While one is, a piece of work finishing
    /// settles nothing: the pass settles once, at its end, so a later step
    /// that had nothing to send can't paint "Up to date" over an earlier
    /// one the server never answered.
    private var passes = 0
    /// At the start of a burst of work: the status before it, and how many
    /// answers the server had given (see `Cloud.answers`).
    private var before: (state: State, answers: Int) = (.idle, 0)
    private var running: Set<String> = []
    private var failure: String?
    private var account: UUID?

    private init() {
        let prefs = Cloud.shared.sync
        account = Cloud.shared.account?.userId
        loadState()
        on = prefs.on
        enabled = CloudSync.domains(prefs, canvas: canvasSwitch)
        if let account, let owner, owner != account { resetState() }
    }

    func note(_ text: String) {
        log.append(Entry(at: Date(), text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if Headless.on { Headless.log("cloud: \(text)") }
    }

    private var cloud: Cloud { Cloud.shared }

    /// Signed in, sync on, and this domain switched on.
    func active(_ domain: Domain) -> Bool {
        cloud.isSignedIn && on && enabled.contains(domain)
    }

    /// Sync is on and this domain is one of the chosen — whether or not
    /// anyone is signed in right now (the caller checks that).
    func syncs(_ domain: Domain) -> Bool { on && enabled.contains(domain) }

    // MARK: - starting

    /// Once, for the first window, after its session is back.
    func start(for browser: Browser) {
        guard browser.primary, !started else { return }
        started = true
        self.browser = browser
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CloudSync.shared.cloudChanged() }
        })
        observers.append(center.addObserver(forName: Cloud.event, object: nil, queue: .main) { note in
            let event = note.userInfo?["event"] as? [String: Any] ?? [:]
            MainActor.assumeIsolated { CloudSync.shared.received(event) }
        })
        browser.prefs.objectWillChange.sink { [weak self] in self?.changed(.settings) }.store(in: &bag)
        Sections.shared.$archive.dropFirst().sink { [weak self] _ in self?.changed(.settings) }.store(in: &bag)
        browser.bookmarks.objectWillChange.sink { [weak self] in self?.changed(.bookmarks) }.store(in: &bag)
        browser.history.objectWillChange.sink { [weak self] in self?.changed(.history) }.store(in: &bag)
        Spaces.shared.objectWillChange.sink { [weak self] in self?.changed(.spaces) }.store(in: &bag)
        Groups.shared.objectWillChange.sink { [weak self] in self?.changed(.spaces) }.store(in: &bag) // folders travel in the spaces document
        watch()
        guard cloud.isSignedIn, on else { return }
        // A moment after launch, not during it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { await self?.syncNow() }
        }
    }

    /// The data folder, watched for the session file's writes: that is when
    /// a tab, a pin or a space has moved. Only the modification times are
    /// read on each event.
    private func watch() {
        let fd = Darwin.open(Store.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
        for name in ["session.json", "windows.json", "history.json"] { stamps[name] = CloudSync.modified(name) }
    }

    private static func modified(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Store.file(name).path))?[.modificationDate] as? Date
    }

    private func folderChanged() {
        for name in ["session.json", "windows.json", "history.json"] {
            let now = CloudSync.modified(name)
            guard now != stamps[name] else { continue }
            stamps[name] = now
            if name == "history.json" { changed(.history) } else { changed(.spaces); changed(.tabs) }
        }
    }

    // MARK: - local changes

    /// Something of this domain changed here. Two quiet seconds, then push.
    private func changed(_ domain: Domain) {
        guard !applyingRemote, active(domain) || (domain == .spaces && active(.tabs)) else { return }
        waiting.insert(domain)
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let due = waiting
            waiting = []
            Task { for domain in Domain.allCases where due.contains(domain) { await self.push(domain) } }
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - switches

    private static func domains(_ prefs: Cloud.SyncPrefs, canvas: Bool) -> Set<Domain> {
        var out: Set<Domain> = []
        if prefs.spaces { out.insert(.spaces) }
        if prefs.settings { out.insert(.settings) }
        if prefs.bookmarks { out.insert(.bookmarks) }
        if prefs.tabs { out.insert(.tabs) }
        if prefs.history { out.insert(.history) }
        if canvas { out.insert(.canvas) }
        return out
    }

    private func store(_ domains: Set<Domain>, on: Bool) {
        var prefs = cloud.sync
        prefs.spaces = domains.contains(.spaces)
        prefs.settings = domains.contains(.settings)
        prefs.bookmarks = domains.contains(.bookmarks)
        prefs.tabs = domains.contains(.tabs)
        prefs.history = domains.contains(.history)
        prefs.on = on
        cloud.sync = prefs
        if canvasSwitch != domains.contains(.canvas) {
            canvasSwitch = domains.contains(.canvas)
            saveState()
        }
        self.on = on
        enabled = domains
    }

    /// One switch. Once sync is on, turning a domain on syncs it now;
    /// turning Open tabs off clears this Mac's list on the server.
    func set(_ domain: Domain, _ value: Bool) {
        var next = enabled
        if value { next.insert(domain) } else { next.remove(domain) }
        guard next != enabled else { return }
        let wasOn = active(domain)
        store(next, on: on)
        note("\(domain.title): \(value ? "on" : "off")")
        guard cloud.isSignedIn, on else { return }
        if value { Task { await sync(domain) } }
        else if wasOn, domain == .tabs { Task { await clearTabs() } }
    }

    /// "Turn on sync": these domains, and a first sync of each.
    func turnOn(_ domains: Set<Domain>) async {
        store(domains, on: true)
        note("Sync on: \(Domain.allCases.filter(domains.contains).map(\.rawValue).joined(separator: ", "))")
        await syncNow()
    }

    func turnOff() {
        let hadTabs = active(.tabs)
        store(enabled, on: false)
        note("Sync off")
        state = .idle
        if hadTabs { Task { await clearTabs(force: true) } }
    }

    // MARK: - the account changing

    private func cloudChanged() {
        let now = cloud.account?.userId
        guard now != account else {
            if !cloud.isLinked { state = .idle }
            return
        }
        account = now
        otherDevices = []
        if now == nil {
            // Signed out (by hand, or by the server ending the session): sync
            // stops, the switches are remembered for next time. Nothing
            // syncs again until "Turn on sync" is pressed.
            if on { store(enabled, on: false); note("Sync off — signed out") }
            state = .idle
            return
        }
        // Another account than the one the kept state belongs to: start over.
        if now != owner { resetState() }
        if on { Task { await syncNow() } }
    }

    /// Before signing out by hand: clear this Mac's open tabs from the
    /// server while the session still works, and turn sync off.
    func signingOut() async {
        if active(.tabs) { await clearTabs() }
        if on { store(enabled, on: false) }
    }

    // MARK: - events

    private func received(_ event: [String: Any]) {
        guard cloud.isSignedIn, on else { return }
        let type = event["type"] as? String ?? ""
        let mine = cloud.account?.deviceId.uuidString.lowercased()
        switch type {
        case "ready", "resync":
            // Connected again: anything may have been missed meanwhile.
            Task { await pullAll() }
        case "doc":
            guard let domain = event["domain"] as? String else { return }
            let from = (event["device_id"] as? String)?.lowercased()
            if from == mine { return }
            if domain.hasPrefix("tabs:") {
                Task { await refreshDevices() }
            } else if let d = Domain(rawValue: domain), active(d) {
                Task { await pull(d) }
            }
        case "history":
            if active(.history) { Task { await pullHistory() } }
        case "history_deleted":
            // Rows deleted on the cloud, from here or another Mac. Nothing to
            // do: a delete there never reaches into History here, and what
            // was deleted can't be pulled again.
            break
        default:
            break
        }
    }

    // MARK: - syncing

    /// Everything that is on: pull, merge, push.
    func syncNow() async {
        guard cloud.isSignedIn else { state = .idle; return }
        guard on else { return }
        if passes == 0, busy == 0 { begin() }
        passes += 1
        await pullAll()
        for domain in Domain.allCases where active(domain) && domain != .history { await push(domain) }
        if active(.history) { await pushHistory(force: true) }
        passes -= 1
        if passes == 0, busy == 0 { settle() }
    }

    /// The first piece of work of a burst: what the status was, and how far
    /// the server's answers had got.
    private func begin() {
        before = (state == .syncing ? .idle : state, cloud.answers)
    }

    /// The burst is over: a failure anywhere in it is what the status says;
    /// "Up to date" and a new "last synced" only when the server answered
    /// and nothing failed; with nothing sent, the status is what it was.
    private func settle() {
        let outcome = CloudSync.settled(signedIn: cloud.isSignedIn, failure: failure,
                                        answered: cloud.answers > before.answers, before: before.state)
        state = outcome.state
        if outcome.stamp { lastSync = Date() }
        failure = nil
    }

    /// `settle`, as a rule.
    nonisolated static func settled(signedIn: Bool, failure: String?, answered: Bool, before: State) -> (state: State, stamp: Bool) {
        guard signedIn else { return (.idle, false) }
        if let failure { return (failure == "offline" ? .offline : .error(failure), false) }
        if answered { return (.idle, true) }
        return (before == .syncing ? .idle : before, false)
    }

    private func pullAll() async {
        guard cloud.isSignedIn, on else { return }
        await work("docs") {
            let list: [Meta] = try await self.cloud.requestJSON("GET", "/v1/sync/docs")
            for d in [Domain.spaces, .settings, .bookmarks] where self.active(d) {
                let server = list.first { $0.domain == d.rawValue }
                if server?.version != self.bases[d.rawValue]?.version || server == nil {
                    await self.pull(d)
                }
            }
            await self.refreshDevices(list)
            if self.active(.history) { await self.pullHistory() }
        }
    }

    private func sync(_ domain: Domain) async {
        switch domain {
        case .history:
            await pullHistory()
            await pushHistory(force: true)
        case .tabs:
            await push(.tabs)
            await refreshDevices()
        case .canvas:
            // Personal's room comes up on its own (didChange → CanvasHost).
            break
        default:
            await pull(domain)
            await push(domain)
        }
    }

    struct Meta: Decodable, Equatable {
        var domain: String
        var version: Int64
        var updated_at: String?
        var device_id: UUID?
        var bytes: Int?
    }

    private struct Doc: Decodable {
        var version: Int64
        var payload: String?
        var device_id: UUID?
        var updated_at: String?
    }

    private struct Put: Decodable {
        var version: Int64
    }

    /// One piece of network work: counted for the status line, failures
    /// turned into it.
    @discardableResult
    private func work(_ name: String, _ body: @escaping () async throws -> Void) async -> Bool {
        if busy == 0, passes == 0 { begin() }
        busy += 1
        state = .syncing
        defer {
            busy -= 1
            if busy == 0, passes == 0 { settle() }
        }
        do {
            try await body()
            return true
        } catch let error as Cloud.Failure {
            if error.code == "network" { failure = "offline" } else { failure = error.message }
            note("\(name): \(error.message)")
            return false
        } catch is CancellationError {
            return false
        } catch {
            failure = error.localizedDescription
            note("\(name): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - one domain

    /// Pull a shared domain: take the server's copy, merged with anything
    /// changed here since the last sync.
    func pull(_ domain: Domain) async {
        guard active(domain), let browser else { return }
        switch domain {
        case .spaces:
            await pullDoc(domain, as: CloudDocs.Spaces.self, build: { CloudApply.spaces(browser, base: $0) },
                          merge: CloudMerge.spaces, apply: { CloudApply.apply(spaces: $0, base: $1, in: browser) })
        case .settings:
            await pullDoc(domain, as: CloudDocs.Settings.self, build: { _ in CloudApply.settings(browser) },
                          merge: CloudMerge.settings, apply: { doc, _ in CloudApply.apply(settings: doc, in: browser) })
        case .bookmarks:
            await pullDoc(domain, as: CloudDocs.Bookmarks.self, build: { _ in CloudApply.bookmarks(browser) },
                          merge: CloudMerge.bookmarks, apply: { doc, _ in CloudApply.apply(bookmarks: doc, in: browser) })
        case .history:
            await pullHistory()
        case .tabs:
            await refreshDevices()
        case .canvas:
            // A room, not a document: the canvas host connects it.
            break
        }
    }

    /// Push a domain if it changed here since the last sync.
    func push(_ domain: Domain) async {
        guard let browser else { return }
        switch domain {
        case .spaces:
            if active(.spaces) {
                await pushDoc(domain, as: CloudDocs.Spaces.self, build: { CloudApply.spaces(browser, base: $0) },
                              merge: CloudMerge.spaces, apply: { CloudApply.apply(spaces: $0, base: $1, in: browser) })
            }
            if active(.tabs) { await push(.tabs) }
        case .settings:
            guard active(domain) else { return }
            await pushDoc(domain, as: CloudDocs.Settings.self, build: { _ in CloudApply.settings(browser) },
                          merge: CloudMerge.settings, apply: { doc, _ in CloudApply.apply(settings: doc, in: browser) })
        case .bookmarks:
            guard active(domain) else { return }
            await pushDoc(domain, as: CloudDocs.Bookmarks.self, build: { _ in CloudApply.bookmarks(browser) },
                          merge: CloudMerge.bookmarks, apply: { doc, _ in CloudApply.apply(bookmarks: doc, in: browser) })
        case .tabs:
            guard active(.tabs) else { return }
            await pushTabs()
        case .history:
            guard active(.history) else { return }
            await pushHistory()
        case .canvas:
            break
        }
    }

    private func encode<T: Encodable>(_ doc: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(doc)
    }

    private func decode<T: Decodable>(_ type: T.Type, base64: String?) -> T? {
        guard let base64, let data = Data(base64Encoded: base64) ?? Data(base64Encoded: CloudSync.padded(base64)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// base64url without padding, as standard base64.
    private static func padded(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return s
    }

    private func base<T: Decodable>(_ domain: Domain, as type: T.Type) -> T? {
        bases[domain.rawValue].flatMap { try? JSONDecoder().decode(T.self, from: $0.payload) }
    }

    /// Apply a merged document here without it counting as a change.
    private func applying(_ body: () -> Void) {
        applyingRemote = true
        body()
        // Publishers fire synchronously, the session write lands a beat
        // later: its push finds nothing new against the base set after this.
        applyingRemote = false
    }

    /// One at a time per domain: a pull waits for a push in flight (and the
    /// other way round), then runs against what that one left.
    private func serialized(_ name: String, _ body: @escaping () async -> Void) async {
        while running.contains(name) { await CloudSync.pause() }
        running.insert(name)
        defer { running.remove(name) }
        await body()
    }

    /// A tenth of a second, stopped or not: a stopped history delete still
    /// waits its turn, and Task.sleep, throwing at once, would spin the main
    /// thread until the lane is free.
    private static func pause() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done.resume() }
        }
    }

    /// A document as it reads back from JSON: what is compared against the
    /// base is what the base would decode to, so a value that doesn't survive
    /// the trip unchanged can't make a push that never settles.
    private func normalized<T: Codable>(_ doc: T) -> T {
        (try? encode(doc)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? doc
    }

    private func pullDoc<T: Codable & Equatable>(
        _ domain: Domain, as type: T.Type,
        build: @escaping (T?) -> T,
        merge: @escaping (T?, T, T) -> T,
        apply: @escaping (T, T?) -> Void
    ) async {
        await serialized(domain.rawValue) {
            await self.work(domain.rawValue) {
                let doc: Doc
                do {
                    doc = try await self.cloud.requestJSON("GET", "/v1/sync/docs/\(domain.rawValue)")
                } catch let failure as Cloud.Failure where failure.status == 404 {
                    // Nothing there yet: this Mac's copy goes up as the first.
                    self.bases[domain.rawValue] = nil
                    self.saveState()
                    return
                }
                guard self.active(domain) else { return }
                if doc.version == self.bases[domain.rawValue]?.version { return }
                guard let server = self.decode(T.self, base64: doc.payload) else {
                    throw Cloud.Failure(status: 0, code: "decode", message: "The cloud's \(domain.rawValue) didn't read — left alone")
                }
                let base = self.base(domain, as: T.self)
                let local = self.normalized(build(base))
                let merged: T
                if let base, local == base { merged = server } else { merged = merge(base, local, server) }
                if merged != local { self.applying { apply(merged, base) } }
                self.bases[domain.rawValue] = Base(version: doc.version, payload: try self.encode(server))
                self.saveState()
                self.note("Pulled \(domain.rawValue) v\(doc.version)\(merged == local ? "" : " — applied")")
                if merged != server { try await self.put(domain, merged, build: build, merge: merge, apply: apply) }
            }
        }
    }

    private func pushDoc<T: Codable & Equatable>(
        _ domain: Domain, as type: T.Type,
        build: @escaping (T?) -> T,
        merge: @escaping (T?, T, T) -> T,
        apply: @escaping (T, T?) -> Void
    ) async {
        await serialized(domain.rawValue) {
            let base = self.base(domain, as: T.self)
            let local = self.normalized(build(base))
            if let base, local == base { return }
            await self.work(domain.rawValue) {
                try await self.put(domain, local, build: build, merge: merge, apply: apply)
            }
        }
    }

    /// PUT against the base's version; on 409 merge with the server's copy,
    /// apply, and try again (three times at most).
    private func put<T: Codable & Equatable>(
        _ domain: Domain, _ first: T,
        build: @escaping (T?) -> T,
        merge: @escaping (T?, T, T) -> T,
        apply: @escaping (T, T?) -> Void
    ) async throws {
        var doc = first
        for _ in 0..<3 {
            guard active(domain) else { return }
            let version = bases[domain.rawValue]?.version ?? 0
            let payload = try encode(doc)
            do {
                let answer: Put = try await cloud.requestJSON("PUT", "/v1/sync/docs/\(domain.rawValue)", json: [
                    "base_version": version, "payload": payload.base64EncodedString(),
                ])
                bases[domain.rawValue] = Base(version: answer.version, payload: payload)
                saveState()
                note("Pushed \(domain.rawValue) v\(answer.version)")
                return
            } catch let failure as Cloud.Failure where failure.status == 409 {
                // The 409 carries the server's copy; read it again if not.
                var current = failure.body.flatMap { try? JSONDecoder().decode(Doc.self, from: $0) }
                if current?.payload == nil, current?.version != 0 {
                    current = try? await cloud.requestJSON("GET", "/v1/sync/docs/\(domain.rawValue)") as Doc
                }
                guard let current, let server = decode(T.self, base64: current.payload) else {
                    // Gone since: start over from nothing.
                    bases[domain.rawValue] = nil
                    continue
                }
                let base = self.base(domain, as: T.self)
                let local = normalized(build(base))
                let merged = merge(base, local, server)
                if merged != local { applying { apply(merged, base) } }
                bases[domain.rawValue] = Base(version: current.version, payload: try encode(server))
                saveState()
                note("Merged \(domain.rawValue) with v\(current.version) from another device")
                if merged == server { return }
                doc = merged
            }
        }
        throw Cloud.Failure(status: 409, code: "conflict", message: "\(domain.title) kept changing elsewhere — will try again")
    }

    // MARK: - open tabs

    private var tabsDomain: String? { cloud.account.map { "tabs:\($0.deviceId.uuidString.lowercased())" } }

    private func pushTabs() async {
        guard let domain = tabsDomain else { return }
        await serialized("tabs") {
            let doc = CloudApply.openTabs(device: self.cloud.deviceName)
            if let was = self.bases[domain].flatMap({ try? JSONDecoder().decode(CloudDocs.Tabs.self, from: $0.payload) }),
               was.tabs == doc.tabs, was.device == doc.device { return }
            await self.work("tabs") { try await self.putOwn(domain, doc) }
        }
    }

    /// Turning Open tabs off (or sync off): an empty list, so other Macs
    /// stop showing tabs that are no longer kept up to date.
    private func clearTabs(force: Bool = false) async {
        guard let domain = tabsDomain, cloud.isSignedIn else { return }
        let doc = CloudDocs.Tabs(device: cloud.deviceName, updated: Date().timeIntervalSince1970, tabs: [])
        await work("tabs") { try await self.putOwn(domain, doc) }
    }

    /// This device's own document: nobody else writes it, so a 409 only
    /// means the version here is stale — take the server's and go again.
    private func putOwn(_ domain: String, _ doc: CloudDocs.Tabs) async throws {
        let payload = try encode(doc)
        for _ in 0..<2 {
            do {
                let answer: Put = try await cloud.requestJSON("PUT", "/v1/sync/docs/\(domain)", json: [
                    "base_version": bases[domain]?.version ?? 0, "payload": payload.base64EncodedString(),
                ])
                bases[domain] = Base(version: answer.version, payload: payload)
                saveState()
                return
            } catch let failure as Cloud.Failure where failure.status == 409 {
                let version = failure.body.flatMap { try? JSONDecoder().decode(Doc.self, from: $0) }?.version
                bases[domain] = Base(version: version ?? 0, payload: Data())
            }
        }
    }

    /// The other devices' open tabs.
    func refreshDevices(_ known: [Meta]? = nil) async {
        guard cloud.isSignedIn, on else { return }
        let mine = tabsDomain
        await work("devices") {
            let list: [Meta]
            if let known { list = known } else { list = try await self.cloud.requestJSON("GET", "/v1/sync/docs") }
            var next: [DeviceTabs] = []
            for meta in list where meta.domain.hasPrefix("tabs:") && meta.domain != mine {
                if let have = self.otherDevices.first(where: { $0.domain == meta.domain }), have.version == meta.version {
                    next.append(have)
                    continue
                }
                guard let doc: Doc = try? await self.cloud.requestJSON("GET", "/v1/sync/docs/\(meta.domain)"),
                      let tabs = self.decode(CloudDocs.Tabs.self, base64: doc.payload) else { continue }
                next.append(DeviceTabs(domain: meta.domain, deviceId: UUID(uuidString: String(meta.domain.dropFirst(5))),
                                       name: tabs.device, updated: Date(timeIntervalSince1970: tabs.updated),
                                       version: meta.version, tabs: tabs.tabs))
            }
            self.otherDevices = next.filter { !$0.tabs.isEmpty }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        }
    }

    /// One of another Mac's tabs, here, in front.
    func open(_ tab: CloudDocs.Tabs.Open) {
        guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { return }
        _ = Windows.current.open(url, foreground: true)
    }

    // MARK: - history

    private struct Pulled: Decodable {
        struct Row: Decodable {
            var seq: Int64
            var device_id: UUID?
            var visited_at: String?
            var payload: Payload?
        }
        struct Payload: Decodable {
            var url: String?
            var title: String?
            var visited_at: Stamp?
        }
        var entries: [Row]
        var next: Int64
        var more: Bool?
    }

    /// RFC 3339, or Unix seconds (milliseconds past 1e11).
    enum Stamp: Decodable {
        case date(Date)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) {
                self = .date(Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n))
            } else if let s = try? c.decode(String.self), let d = CloudSync.date(s) {
                self = .date(d)
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a time")
            }
        }

        var date: Date { if case .date(let d) = self { return d }; return Date() }
    }

    nonisolated static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// New places visited here, oldest first, in requests the cloud takes —
    /// CloudHistory measures them, and splits and skips around what it
    /// refuses. A place last visited on another Mac (and merged in from
    /// there) isn't sent back. After a push fails, the next one waits 30 s,
    /// then twice as long each time up to 15 minutes, unless `force` (Sync
    /// now, sign-in, a switch turned on).
    func pushHistory(force: Bool = false) async {
        guard active(.history) else { return }
        if !force, let hold = historyHold, hold.until > Date() { return }
        await serialized("history-push") {
            let ok = await self.work("history") { try await self.uploadHistory() }
            self.historyPushed(ok)
        }
    }

    private func uploadHistory() async throws {
        let limits = await cloud.limitsForHistory()
        let now = Date().timeIntervalSince1970
        // A cursor in the future (an older Copper sent a visit stamped there)
        // would pass over everything visited until then.
        let through = min(cloud.sync.pushedThrough ?? 0, now)
        let visits = CloudHistoryDelete.unforgotten(CloudSync.localVisits(), forgotten)
        let plan = CloudHistory.plan(visits, after: through, known: remote, now: now, limits: limits)
        guard !plan.isEmpty else { return }
        let upload = CloudHistory.Upload(plan, limits: limits, from: through, now: now)
        var told = 0
        var refusals = 0
        /// The cursor as far as the upload says, visits stamped ahead of now
        /// remembered, and what was left out said in the log.
        func keep() {
            var prefs = cloud.sync
            prefs.pushedThrough = upload.through
            cloud.sync = prefs
            for (key, at) in upload.ahead { remote[key] = at }
            remote = remote.filter { $0.value > upload.through }
            saveState()
            for skip in upload.skipped.dropFirst(told).prefix(max(0, 5 - told)) {
                let size = skip.bytes > 0 ? ", \(skip.bytes) bytes" : ""
                note("History: left out a visit to \(skip.host) (\(skip.why)\(size))")
            }
            told = max(told, min(upload.skipped.count, 5))
        }
        defer {
            keep()
            if upload.skipped.count > 5 { note("History: \(upload.skipped.count - 5) more visits left out") }
            if upload.shortened > 0 { note("History: shortened \(upload.shortened) long title\(upload.shortened == 1 ? "" : "s") to fit the cloud's \(upload.limits.entryBytes) bytes per visit") }
            if upload.limits != limits { cloud.historyLimits = upload.limits }
            if upload.sent > 0 { note("Pushed \(upload.sent) visit\(upload.sent == 1 ? "" : "s")") }
        }
        while let entries = upload.next() {
            guard active(.history) else { return }
            do {
                let (answer, _) = try await cloud.request("POST", "/v1/sync/history", body: CloudHistory.body(entries))
                upload.accepted(rejected: CloudHistory.rejected(in: answer))
            } catch let failure as Cloud.Failure where CloudHistory.refuses(failure) {
                // The server's reason once per push; what ends up skipped is
                // said visit by visit.
                if refusals == 0 { note("History: the cloud refused \(entries.count) visit\(entries.count == 1 ? "" : "s") (\(failure.status): \(failure.message)) — finding which") }
                refusals += 1
                try upload.refused(failure)
            }
            keep()
        }
    }

    /// After a failed push: when the next one may run, and the wait before it.
    private var historyHold: (until: Date, wait: TimeInterval)?
    private var historyRetry: DispatchWorkItem?

    private func historyPushed(_ ok: Bool) {
        historyRetry?.cancel()
        historyRetry = nil
        guard !ok, active(.history) else {
            historyHold = nil
            return
        }
        let wait = min(900, max(30, (historyHold?.wait ?? 15) * 2))
        historyHold = (Date().addingTimeInterval(wait), wait)
        note("History: trying again in \(Int(wait)) s")
        // Forced: this is the wait running out (the timer's clock and the
        // wall clock needn't agree to the millisecond).
        let retry = DispatchWorkItem { [weak self] in
            Task { await self?.pushHistory(force: true) }
        }
        historyRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: retry)
    }

    /// Places other Macs visited since the last pull, merged into History —
    /// once each: a place already known within the same second is skipped.
    func pullHistory() async {
        guard active(.history), let browser else { return }
        await serialized("history-pull") {
            await self.work("history") {
                var known = Dictionary(CloudApply.visits().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                var merged = 0
                for _ in 0..<40 {
                    guard self.active(.history) else { return }
                    let since = self.cloud.sync.pulledSeq
                    let page: Pulled = try await self.cloud.requestJSON("GET", "/v1/sync/history", query: [
                        "since": String(since), "limit": "500", "exclude_device": "me",
                    ])
                    self.applying {
                        for row in page.entries {
                            guard let raw = row.payload?.url, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { continue }
                            let when = row.payload?.visited_at?.date ?? row.visited_at.flatMap(CloudSync.date) ?? Date()
                            let key = CloudApply.historyKey(url)
                            let have = known[key]
                            if let have, CloudMerge.sameVisit(have.last, when) { continue }
                            browser.history.take(url, title: row.payload?.title ?? "", count: (have?.count ?? 0) + 1, last: when)
                            let last = max(have?.last ?? when, when)
                            known[key] = CloudApply.Visit(url: url.absoluteString, key: key, title: row.payload?.title ?? have?.title ?? "",
                                                          count: (have?.count ?? 0) + 1, last: last)
                            if when >= (have?.last ?? .distantPast) { self.remote[key] = when.timeIntervalSince1970 }
                            merged += 1
                        }
                        if !page.entries.isEmpty { browser.history.settle() }
                    }
                    var prefs = self.cloud.sync
                    prefs.pulledSeq = max(since, page.next)
                    self.cloud.sync = prefs
                    self.saveState()
                    if page.more != true || page.entries.isEmpty { break }
                }
                if merged > 0 { self.note("Pulled \(merged) visit\(merged == 1 ? "" : "s") from other devices") }
            }
        }
    }

    // MARK: - deleting history on the cloud

    /// Pages forgotten in the History window this run, and when — see
    /// `CloudHistoryDelete.unforgotten`. Never written down: they were
    /// asked to be forgotten.
    private var forgotten: [String: Double] = [:]

    private static func localVisits() -> [CloudHistory.Visit] {
        CloudApply.visits().map { CloudHistory.Visit(key: $0.key, url: $0.url, title: $0.title, at: $0.last.timeIntervalSince1970) }
    }

    /// Deletes visits on the cloud — every Mac's rows, as `selector` says,
    /// found on this Mac (CloudHistoryDelete) — and leaves History here as
    /// it is. For Settings, `copper cloud-history delete` and agents.
    ///
    /// What it deletes doesn't come back:
    ///   - it runs in the history lane, after any push or pull in flight and
    ///     before the next, so neither crosses it;
    ///   - visits a push sent before it are deleted by it: they are rows on
    ///     the server by then;
    ///   - a push sends only visits newer than `pushedThrough`, which only
    ///     ever moved past visits that went up (or were left out), and a
    ///     delete never moves it back: what this Mac sent is never offered
    ///     again. Covered visits here that haven't gone up yet are put in
    ///     `remote` — "on the server already" — so the next push passes over
    ///     them too, and the cursor with them (`CloudHistoryDelete.push`);
    ///   - a pull asks only for seqs after `pulledSeq`, which a delete leaves
    ///     alone, and deleted rows are gone from the server. Rows pulled
    ///     before stay in History here, behind the push cursor or in
    ///     `remote`, so they aren't pushed back either.
    func deleteHistory(_ selector: CloudHistoryDelete.Selector) async throws -> CloudHistoryDelete.Outcome {
        try await erase(selector, why: CloudHistoryDelete.words(selector), here: .kept)
    }

    /// History.forget(): everything cleared here, so everything on the cloud
    /// too while history syncs. Fire and forget; the log says how it went.
    func historyCleared() {
        guard active(.history) else { return }
        Task { _ = try? await erase(CloudHistoryDelete.cleared, why: "cleared here", here: .cleared) }
    }

    /// A page forgotten in the History window: its rows on the cloud too,
    /// whichever Mac sent them, found by key on this Mac.
    func historyForgot(_ key: String) {
        guard active(.history), !key.isEmpty else { return }
        forgotten[key] = Date().timeIntervalSince1970
        let site = key.prefix { $0 != "/" }
        Task { _ = try? await erase(CloudHistoryDelete.forgot(key), why: "a page on \(site), forgotten here", here: .forgot) }
    }

    private func erase(_ selector: CloudHistoryDelete.Selector, why: String, here: CloudHistoryDelete.Here) async throws -> CloudHistoryDelete.Outcome {
        func failed(_ error: Error) -> Error {
            if !(error is CancellationError) {
                note("History: nothing deleted from the cloud (\(why)) — \((error as? Cloud.Failure)?.message ?? error.localizedDescription)")
            }
            return error
        }
        guard cloud.isSignedIn else { throw failed(Cloud.Failure(status: 0, code: "not_signed_in", message: "Sign in to Copper Cloud first")) }
        if cloud.deletesHistory == nil { await cloud.loadInfo() }
        guard let can = cloud.deletesHistory else {
            throw failed(Cloud.Failure(status: 0, code: "network", message: "Couldn't ask the cloud whether it can delete history — try again when it's reachable"))
        }
        guard can else { throw failed(Cloud.Failure(status: 0, code: "unsupported", message: CloudHistoryDelete.unsupported)) }
        var result: Result<CloudHistoryDelete.Outcome, Error> = .failure(CancellationError())
        await serialized("history-push") {
            await self.serialized("history-pull") {
                // History cleared here: nothing is to go up again, whether or
                // not the cloud answers.
                if here == .cleared { self.settlePush(after: selector, here: here) }
                do {
                    result = .success(try await CloudHistoryDelete.run(selector) { try await self.askHistory($0) })
                    if here == .kept { self.settlePush(after: selector, here: here) }
                } catch {
                    // Some deleted, then a failure: settled as if all were.
                    // Nothing deleted (or stopped): the push goes on as before.
                    if here == .kept, (error as? Cloud.Failure)?.code == "partial" { self.settlePush(after: selector, here: here) }
                    result = .failure(error)
                }
            }
        }
        switch result {
        case .success(let outcome):
            let visits = "\(outcome.deleted) visit\(outcome.deleted == 1 ? "" : "s")"
            let cut = outcome.cut ? " (looked through the first \(CloudHistoryDelete.pageLimit * CloudHistoryDelete.pageSize) only)" : ""
            note("History: deleted \(visits) from the cloud — \(why)\(cut)")
            return outcome
        case .failure(let error):
            throw failed(error)
        }
    }

    /// The push cursor and `remote` as CloudHistoryDelete.push says, kept.
    private func settlePush(after selector: CloudHistoryDelete.Selector, here: CloudHistoryDelete.Here) {
        let now = Date().timeIntervalSince1970
        let visits = here == .kept ? CloudSync.localVisits() : []
        let settled = CloudHistoryDelete.push(after: selector, here: here, visits: visits, through: cloud.sync.pushedThrough,
                                              remote: remote, device: cloud.account?.deviceId, now: now)
        guard settled.through != cloud.sync.pushedThrough || settled.remote != remote else { return }
        var prefs = cloud.sync
        prefs.pushedThrough = settled.through
        cloud.sync = prefs
        remote = settled.remote
        saveState()
    }

    /// One request of a delete: the answer's bytes, on the main actor only
    /// for as long as it takes to ask.
    private func askHistory(_ ask: CloudHistoryDelete.Ask) async throws -> Data {
        try await cloud.request(ask.method, "/v1/sync/history", body: ask.body, query: ask.query).0
    }

    // MARK: - what is kept between runs

    /// The last copy of each document known to be on the server and applied
    /// here — the base of every three-way merge — and the history places
    /// already on the server at their time (`remote`): merged in from
    /// elsewhere, or sent stamped ahead of now. Browsing data, so 0600 like
    /// cloud.json.
    struct Base: Codable {
        var version: Int64
        var payload: Data
    }

    private struct Saved: Codable {
        var owner: UUID?
        var docs: [String: Base] = [:]
        var remote: [String: Double] = [:]
        /// The Personal canvas switch. Kept here rather than beside the
        /// other switches in cloud.json (`Cloud.SyncPrefs` has no field for
        /// it); optional, so a file from before it reads as off.
        var canvas: Bool?
    }

    private var bases: [String: Base] = [:]
    private var remote: [String: Double] = [:]
    private var owner: UUID?
    /// See `Saved.canvas`. Off until chosen, like every other domain; not
    /// reset when another account signs in (the switches never are).
    private var canvasSwitch = false

    private static var stateFile: URL { Store.file("cloud-sync.json") }

    private func loadState() {
        guard let data = try? Data(contentsOf: CloudSync.stateFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        owner = saved.owner
        bases = saved.docs
        remote = saved.remote
        canvasSwitch = saved.canvas ?? false
    }

    private func saveState() {
        if let account { owner = account }
        guard let data = try? JSONEncoder().encode(Saved(owner: owner, docs: bases, remote: remote, canvas: canvasSwitch)) else { return }
        let file = CloudSync.stateFile
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".cloud-sync.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    private func resetState() {
        bases = [:]
        remote = [:]
        owner = account
        var prefs = cloud.sync
        prefs.pushedThrough = nil
        prefs.pulledSeq = 0
        cloud.sync = prefs
        saveState()
    }

    // MARK: - for the bench and the page

    var status: [String: Any] {
        var out: [String: Any] = [
            "on": on,
            "enabled": Domain.allCases.filter(enabled.contains).map(\.rawValue),
            "state": state.text,
            "busy": busy,
            "lastSync": lastSync.map { CloudSync.stamp($0) } ?? NSNull(),
            "versions": bases.mapValues { $0.version },
            "historyPushedThrough": cloud.sync.pushedThrough ?? NSNull(),
            "historyRetryAt": historyHold.map { CloudSync.stamp($0.until) } ?? NSNull(),
            "historyPulledSeq": cloud.sync.pulledSeq,
        ]
        out["devices"] = otherDevices.map { ["name": $0.name, "tabs": $0.tabs.count, "domain": $0.domain] }
        return out
    }

    /// The local document of a domain as it would be pushed now.
    func preview(_ domain: Domain) -> Any? {
        guard let browser else { return nil }
        let data: Data?
        switch domain {
        case .spaces: data = try? encode(CloudApply.spaces(browser, base: base(.spaces, as: CloudDocs.Spaces.self)))
        case .settings: data = try? encode(CloudApply.settings(browser))
        case .bookmarks: data = try? encode(CloudApply.bookmarks(browser))
        case .tabs: data = try? encode(CloudApply.openTabs(device: cloud.deviceName))
        case .history: data = try? JSONEncoder().encode(CloudApply.visits().suffix(20).map { ["url": $0.url, "title": $0.title] })
        case .canvas: data = try? JSONSerialization.data(withJSONObject: ["personal": syncs(.canvas) ? "room" : "this Mac only"])
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}
