import AppKit
import Combine
import Foundation
import Security
import SystemConfiguration

// iCloud sync: end to end encrypted, with no server and no account. Every Mac
// reads and writes sealed files in a folder the person picks — iCloud Drive ›
// Copper by default — and whatever syncs that folder carries them between
// Macs. A 24-word recovery phrase is the key (FolderSyncPhrase.swift,
// FolderSyncCrypto.swift). It sits beside Copper Cloud (Fork/Cloud/), which
// it never edits: it reads this Mac's state and writes merged state back
// through the same calls Copper Cloud uses (CloudApply), and merges by the
// same rules (CloudMerge). Design and limits: docs/icloud-sync.md.
//
// A cycle — 3 s after an edit here, 1 s after the folder changes, every 20 s
// otherwise, and on Sync Now:
//   1. the phrase's folder is still there (gone: reset from another Mac);
//   2. a batch saved but not yet written goes out first, unchanged;
//   3. new files are read into the replica (FolderSyncReplica.swift);
//   4. per domain, as Copper Cloud does it: the base (what was last synced),
//      this Mac's copy and the folder's copy merge three ways; the result is
//      applied here and what differs from the folder's copy goes out as one
//      log of records (FolderSyncRecords.swift);
//   5. now and then a snapshot, and files it covers are cleared away.
//
// What syncs: spaces and kept tabs, the settings allowlist, bookmarks,
// history, each Mac's open tabs (to look at, never opened by themselves) and
// the list of Web Store extensions. Never passwords.

@MainActor
final class FolderSync: ObservableObject {
    static let shared = FolderSync()
    nonisolated static let scopeID = "main"

    enum Domain: String, CaseIterable, Codable, Identifiable {
        case spaces, settings, bookmarks, tabs, history, extensions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .spaces: return "Spaces and kept tabs"
            case .settings: return "Settings"
            case .bookmarks: return "Bookmarks"
            case .tabs: return "Open tabs"
            case .history: return "History"
            case .extensions: return "Extensions"
            }
        }

        var detail: String {
            switch self {
            case .spaces: return "Your spaces and their pinned and Saved tabs, folders included. Today's tabs stay on this Mac."
            case .settings: return "How Copper looks and behaves. Never passwords, paths or keys."
            case .bookmarks: return "The whole bookmarks tree."
            case .tabs: return "Your other Macs can see the tabs open here. Nothing opens by itself."
            case .history: return "Places you visited in the last 90 days."
            case .extensions: return "Extensions from the Chrome Web Store install on your other Macs. Their settings stay put."
            }
        }

        var symbol: String {
            switch self {
            case .spaces: return "square.stack"
            case .settings: return "slider.horizontal.3"
            case .bookmarks: return "bookmark"
            case .tabs: return "macbook.and.iphone"
            case .history: return "clock.arrow.circlepath"
            case .extensions: return "puzzlepiece.extension"
            }
        }

        var kind: SyncRecords.Kind {
            switch self {
            case .spaces: return .spaces
            case .settings: return .settings
            case .bookmarks: return .bookmarks
            case .tabs: return .tabs
            case .history: return .history
            case .extensions: return .extensions
            }
        }
    }

    enum Status: Equatable {
        case off, starting, updating, updated, offline, failed(String), reset
    }

    /// Another Mac in the chain.
    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        let seen: Date?
        let tabs: [CloudDocs.Tabs.Open]
    }

    // MARK: - what is kept

    struct Meta: Codable, Equatable {
        var kind: String
        var device: String
        var seq: Int?
        var vv: [String: Int]?
        /// When the writer wrote it, and when this Mac first read it (ms).
        var at: Double
        var seen: Double
        var size: Int
    }

    struct Saved: Codable {
        var on = false
        var folder: String?
        var device = ""
        var enabled: [Domain] = Domain.allCases
        /// Joined with a phrase: nothing goes out until another Mac's files
        /// have been read, so this Mac's defaults never beat the synced ones.
        var joining = false
        var joinedAt: Double?
        var seq = 0
        /// A batch saved here before it was written to the folder.
        var pending: SyncFile?
        var pendingName: String?
        var replica = SyncReplica()
        /// What this Mac held after the last publish or apply, per record.
        var base: [String: String] = [:]
        /// Domains synced at least once (their base means something).
        var based: [Domain] = []
        var files: [String: Meta] = [:]
        /// Files that didn't open, and since when (ms).
        var damaged: [String: Double] = [:]
        var clock = SyncClock(device: "")
        var lastSnapshot: Double?
        var lastSync: Double?
        /// Extensions removed on another Mac that stay installed here.
        var extIgnored: [String] = []
        /// The Web Store extensions installed here at the last cycle.
        var extSeen: [String]?
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var on = false
    @Published private(set) var enabled: Set<Domain> = Set(Domain.allCases)
    @Published private(set) var folder: URL = SyncVault.defaultFolder
    @Published private(set) var lastSync: Date?
    @Published private(set) var waiting = 0
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var joining = false
    /// Spaces held for the person, either way (Copper Cloud's brake, and
    /// its words: `CloudSync.Hold`).
    @Published private(set) var held: CloudSync.Hold?
    @Published private(set) var log: [String] = []

    private(set) var state = Saved()
    private var keys: SyncKeys?
    private weak var browser: Browser?
    private var started = false
    private var bag: Set<AnyCancellable> = []
    private var dataWatcher: DispatchSourceFileSystemObject?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var stamps: [String: Date] = [:]
    private var timer: DispatchWorkItem?
    private var ticker: Timer?
    private var running = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Domains changed here since their last cycle.
    private var dirty: Set<Domain> = Set(Domain.allCases)
    private var applyingRemote = false
    private var letThrough = false
    private var installing: Set<String> = []
    private var failedInstalls: Set<String> = []
    /// When Touch ID last let the phrase out.
    private var proved: Date?

    nonisolated static let io = DispatchQueue(label: "copper.folder-sync", qos: .utility)
    private static var stateFile: URL { Store.file("folder-sync.json") }

    private init() {
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            FolderSync.io.sync {}
        }
    }

    func note(_ text: String) {
        log.append("\(Self.clock.string(from: Date()))  \(text)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if Headless.on { Headless.log("icloud: \(text)") }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// This Mac's name, as the others list it. A test world says which.
    nonisolated static var deviceName: String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        return Store.world.map { "\(name) (\($0))" } ?? name
    }

    func syncs(_ domain: Domain) -> Bool { on && enabled.contains(domain) }
}

// MARK: - saved state

extension FolderSync {
    private func load() {
        if let data = try? Data(contentsOf: Self.stateFile), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            state = saved
        }
        if state.device.isEmpty { state.device = Self.freshDevice() }
        if state.clock.device != state.device { state.clock = SyncClock(device: state.device) }
        on = state.on
        enabled = Set(state.enabled)
        folder = state.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SyncVault.defaultFolder
        joining = state.joining
        lastSync = state.lastSync.map { Date(timeIntervalSince1970: $0 / 1000) }
        status = on ? .starting : .off
    }

    /// A device's sync id: 12 base32 letters, new each time sync is turned on.
    static func freshDevice() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(SyncKeys.base32(Data(bytes)).prefix(12))
    }

    /// 0600, atomic, off the main thread — after anything queued before it
    /// on the same queue, so a batch is on disk here before it goes out.
    func save() {
        let copy = state
        let file = Self.stateFile
        Self.io.async {
            guard let data = try? JSONEncoder().encode(copy) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = file.appendingPathExtension("tmp")
            FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
            guard (try? data.write(to: temporary)) != nil else { return }
            Darwin.rename(temporary.path, file.path)
        }
    }

    /// Work for the IO queue, awaited.
    nonisolated static func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in io.async { done.resume(returning: body()) } }
    }

    var vault: SyncVault? {
        keys.map { SyncVault(folder: folder, chain: $0.chain, scope: $0.scope(Self.scopeID)) }
    }
}

// MARK: - starting, and watching for changes

extension FolderSync {
    /// Once, for the first window, after its session is back.
    func start(for browser: Browser) {
        guard browser.primary, !started else { return }
        started = true
        self.browser = browser
        browser.prefs.objectWillChange.sink { [weak self] in self?.changed(.settings) }.store(in: &bag)
        Sections.shared.$archive.dropFirst().sink { [weak self] _ in self?.changed(.settings) }.store(in: &bag)
        browser.bookmarks.objectWillChange.sink { [weak self] in self?.changed(.bookmarks) }.store(in: &bag)
        Spaces.shared.objectWillChange.sink { [weak self] in self?.changed(.spaces) }.store(in: &bag)
        Groups.shared.objectWillChange.sink { [weak self] in self?.changed(.spaces) }.store(in: &bag)
        if #available(macOS 15.4, *) {
            Extensions.shared.$installed.dropFirst().sink { [weak self] _ in self?.changed(.extensions) }.store(in: &bag)
        }
        watchData()
        guard on else { return }
        resume(after: 3) // a moment after launch, not during it
    }

    /// The data folder, for the session's and history's writes (when tabs,
    /// pins, spaces or visits moved): only modification times are read.
    private func watchData() {
        let fd = Darwin.open(Store.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.dataChanged() } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        dataWatcher = source
        for name in ["session.json", "windows.json", "history.json"] { stamps[name] = Self.modified(name) }
    }

    private static func modified(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Store.file(name).path))?[.modificationDate] as? Date
    }

    private func dataChanged() {
        for name in ["session.json", "windows.json", "history.json"] {
            let now = Self.modified(name)
            guard now != stamps[name] else { continue }
            stamps[name] = now
            if name == "history.json" { changed(.history) } else { changed(.spaces); changed(.tabs) }
        }
    }

    /// The sync folder: another Mac's file arriving is a write to it.
    private func watchFolder() {
        folderWatcher?.cancel()
        folderWatcher = nil
        guard let vault else { return }
        let fd = Darwin.open(vault.scopeFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend, .link], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule(1) } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        folderWatcher = source
    }

    /// Something of this domain changed here.
    private func changed(_ domain: Domain) {
        guard !applyingRemote else { return }
        dirty.insert(domain)
        guard on, enabled.contains(domain) else { return }
        schedule(3)
    }

    /// A cycle in `seconds`, unless one is due sooner.
    func schedule(_ seconds: Double) {
        guard on else { return }
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.cycle() } }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Sync on (at launch, after turning on or joining): the key, the
    /// folder's watch, a cycle now and every 20 s.
    private func resume(after delay: Double) {
        guard on else { return }
        if keys == nil, let entropy = SyncKeyStore.load() { keys = SyncKeys(entropy: entropy) }
        guard keys != nil else {
            status = .failed("Not syncing — enter your recovery phrase")
            return
        }
        watchFolder()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { FolderSync.shared.schedule(0) }
        }
        schedule(delay)
    }

    private func pause() {
        ticker?.invalidate()
        ticker = nil
        timer?.cancel()
        folderWatcher?.cancel()
        folderWatcher = nil
    }
}

// MARK: - turning on, joining, stopping

extension FolderSync {
    enum SetupFailure: Error, LocalizedError {
        case keychain, folder(String), mismatch, already

        var errorDescription: String? {
            switch self {
            case .keychain: return "Copper couldn't keep the key in the keychain."
            case .folder(let why): return "Copper couldn't use that folder: \(why)"
            case .mismatch: return "This recovery phrase doesn’t match the synced data in this folder."
            case .already: return "Sync is already on."
            }
        }
    }

    /// Pick where the files go, while sync is off.
    func choose(folder: URL) {
        guard !on else { return }
        self.folder = folder
        state.folder = folder.path
        save()
    }

    /// Turn On Sync: a new phrase, a new chain in the folder. Returns the
    /// words, once, for the recovery kit.
    @discardableResult
    func turnOn() async throws -> [String] {
        guard !on else { throw SetupFailure.already }
        let entropy = SyncPhrase.fresh()
        let keys = SyncKeys(entropy: entropy)
        let vault = SyncVault(folder: folder, chain: keys.chain, scope: keys.scope(Self.scopeID))
        let made: String? = await Self.offMain {
            do { try FileManager.default.createDirectory(at: vault.scopeFolder, withIntermediateDirectories: true); return nil }
            catch { return error.localizedDescription }
        }
        if let made { throw SetupFailure.folder(made) }
        guard SyncKeyStore.save(entropy) else { throw SetupFailure.keychain }
        begin(keys, joining: false)
        note("Sync on, new phrase, in \(folder.path)")
        return SyncPhrase.words(for: entropy)
    }

    /// Enter Recovery Phrase: join the chain in this folder.
    func join(phrase: String) async throws {
        guard !on else { throw SetupFailure.already }
        let entropy = try SyncPhrase.entropy(from: phrase)
        let keys = SyncKeys(entropy: entropy)
        let vault = SyncVault(folder: folder, chain: keys.chain, scope: keys.scope(Self.scopeID))
        let there = await Self.offMain { vault.chainExists() }
        guard there else { throw SetupFailure.mismatch }
        guard SyncKeyStore.save(entropy) else { throw SetupFailure.keychain }
        begin(keys, joining: true)
        note("Joined with the recovery phrase, in \(folder.path)")
    }

    private func begin(_ keys: SyncKeys, joining: Bool) {
        self.keys = keys
        let device = Self.freshDevice()
        state = Saved(on: true, folder: folder.path, device: device, enabled: Array(enabled.isEmpty ? Set(Domain.allCases) : enabled),
                      joining: joining, joinedAt: Date().timeIntervalSince1970 * 1000, clock: SyncClock(device: device))
        on = true
        self.joining = joining
        status = .starting
        held = nil
        peers = []
        dirty = Set(Domain.allCases)
        save()
        resume(after: 0.2)
    }

    /// Stop Syncing: this Mac's name and tabs leave the others; everything
    /// here stays. `deleting` also removes this phrase's folder — the other
    /// Macs then stop, keeping their data.
    func stop(deleting: Bool) async {
        guard on else { return }
        let vault = self.vault
        if !deleting, vault != nil {
            // Last words: this device and its tabs, gone from the others.
            var ops: [SyncOp] = []
            for key in ["dev:\(state.device)", "tabs:\(state.device)"] where state.replica.records[key]?.v != nil {
                ops.append(SyncOp(k: key, h: "", v: nil))
            }
            if !ops.isEmpty { _ = await publish(ops) }
        }
        if deleting, let vault {
            let failure: String? = await Self.offMain { do { try vault.removeChain(); return nil } catch { return error.localizedDescription } }
            note(failure.map { "Couldn't delete the sync data: \($0)" } ?? "Deleted the sync data in the folder")
        }
        finish(.off, "Sync off")
    }

    /// Sync ends here: the key is forgotten, local data stays.
    private func finish(_ end: Status, _ why: String) {
        pause()
        SyncKeyStore.forget()
        keys = nil
        let folder = state.folder
        state = Saved()
        state.folder = folder
        state.device = Self.freshDevice()
        state.clock = SyncClock(device: state.device)
        state.enabled = Array(enabled)
        on = false
        joining = false
        held = nil
        peers = []
        waiting = 0
        lastSync = nil
        status = end
        save()
        note(why)
    }

    func set(_ domain: Domain, _ value: Bool) {
        var next = enabled
        if value { next.insert(domain) } else { next.remove(domain) }
        guard next != enabled else { return }
        enabled = next
        state.enabled = Domain.allCases.filter(next.contains)
        dirty.insert(domain)
        save()
        note("\(domain.title): \(value ? "on" : "off")")
        schedule(0.2)
    }

    /// The phrase, for the kit and Show Words: Touch ID (or the login
    /// password) first, good for a minute.
    func phrase(reason: String) async -> [String]? {
        guard on, let entropy = SyncKeyStore.load() else { return nil }
        if let proved, Date().timeIntervalSince(proved) < 60 { return SyncPhrase.words(for: entropy) }
        let ok = await withCheckedContinuation { done in Vault.prove(reason) { done.resume(returning: $0) } }
        guard ok else { return nil }
        proved = Date()
        return SyncPhrase.words(for: entropy)
    }

    /// The phrase without asking — for the bench in a test world only.
    func testPhrase() -> [String]? {
        guard Store.testing, on, let entropy = SyncKeyStore.load() else { return nil }
        return SyncPhrase.words(for: entropy)
    }
}


// MARK: - the cycle

extension FolderSync {
    /// What one look at the folder found.
    struct Pulled: Sendable {
        var files: [(name: String, file: SyncFile, size: Int)] = []
        var listed: Set<String> = []
        var waiting: [String] = []
        var damaged: [String] = []
        var offline: String?
    }

    /// Every file not read yet, opened. Off the main thread.
    nonisolated static func pull(_ vault: SyncVault, _ keys: SyncKeys, known: Set<String>) -> Pulled {
        var out = Pulled()
        let listing: SyncVault.Listing
        do { listing = try vault.list() } catch {
            out.offline = error.localizedDescription
            return out
        }
        out.listed = Set(listing.ready.keys).union(listing.waiting)
        out.waiting = listing.waiting.filter { !known.contains($0) }
        for (name, url) in listing.ready where !known.contains(name) {
            guard let sealed = try? vault.read(url),
                  let json = try? keys.open(sealed, chain: vault.chain, scope: vault.scope, file: name),
                  let file = try? JSONDecoder().decode(SyncFile.self, from: json) else {
                out.damaged.append(name)
                continue
            }
            out.files.append((name, file, sealed.count))
        }
        return out
    }

    /// Sync Now: a cycle, awaited — after the one running, if any.
    func syncNow() async {
        guard on else { return }
        if running {
            again = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        await cycle()
    }

    func cycle() async {
        guard on, let keys, let vault, browser != nil else { return }
        if running { again = true; return }
        running = true
        defer {
            running = false
            let done = waiters
            waiters = []
            if again {
                again = false
                Task { await self.cycle(); done.forEach { $0.resume() } }
            } else {
                done.forEach { $0.resume() }
            }
        }
        if status != .starting { status = .updating }

        // 1. The phrase's folder.
        let (folderThere, chainThere) = await Self.offMain { (FileManager.default.fileExists(atPath: vault.folder.path), vault.chainExists()) }
        guard on else { return }
        guard folderThere else { status = .offline; return }
        if !chainThere {
            // Gone after this Mac had synced: another Mac deleted the data.
            guard state.files.isEmpty && state.seq == 0 && !state.joining else {
                finish(.reset, "The sync data is gone from the folder — sync was reset from another device")
                return
            }
            _ = await Self.offMain { try? FileManager.default.createDirectory(at: vault.scopeFolder, withIntermediateDirectories: true) }
        }

        // 2. A batch saved before it was written.
        if let pending = state.pending, let name = state.pendingName {
            guard await write(pending, as: name, vault: vault, keys: keys) != nil else { return }
            state.pending = nil
            state.pendingName = nil
            save()
        }

        // 3. Read what is new.
        let known = Set(state.files.keys)
        let pulled = await Self.offMain { Self.pull(vault, keys, known: known) }
        guard on else { return }
        if let offline = pulled.offline { status = .offline; note("Folder: \(offline)"); return }
        let changed = take(pulled)

        // Joining: wait for another Mac's files, all of them, before a word.
        if state.joining {
            let others = state.files.values.contains { $0.device != state.device }
            let waited = Date().timeIntervalSince1970 * 1000 - (state.joinedAt ?? 0) > 86_400_000
            if (others && waiting == 0 && state.damaged.isEmpty) || waited {
                state.joining = false
                joining = false
                dirty = Set(Domain.allCases)
                note("Found the other Macs' data")
            } else {
                status = .updating
                refreshPeers()
                save()
                return
            }
        }

        // 4. Each domain: publish what changed here, apply what changed there.
        let kinds = Set(changed.compactMap(SyncRecords.kind(of:)))
        let mark = CloudIntents.shared.tick
        var ops: [SyncOp] = []
        var spacesWent = false
        for domain in [Domain.settings, .spaces, .bookmarks, .history, .tabs, .extensions] {
            guard dirty.contains(domain) || kinds.contains(domain.kind) else { continue }
            dirty.remove(domain)
            guard enabled.contains(domain) else {
                if domain == .tabs { ops += retireTabs() }
                continue
            }
            ops += run(domain, changed: changed)
            if domain == .spaces, held == nil, !CloudSync.shared.active(.spaces) { spacesWent = true }
        }
        ops += ownDevice()

        // 5. Out, as one log. The hand edits behind the spaces it carried have
        // been said, as when Copper Cloud's server takes a document.
        if !ops.isEmpty { guard await publish(ops) else { return } }
        if spacesWent { CloudIntents.shared.clear(through: mark) }

        // 6. Now and then, a snapshot.
        await compact(vault: vault, keys: keys)

        let now = Date()
        lastSync = now
        state.lastSync = now.timeIntervalSince1970 * 1000
        status = .updated
        refreshPeers()
        save()
    }

    /// Files read, into the replica. Returns the keys whose value changed.
    private func take(_ pulled: Pulled) -> Set<String> {
        var changed = Set<String>()
        let now = Date().timeIntervalSince1970 * 1000
        // Snapshots first: a log they cover is then a no-op.
        for (name, file, size) in pulled.files.sorted(by: { ($0.file.kind == "snapshot" ? 0 : 1) < ($1.file.kind == "snapshot" ? 0 : 1) }) {
            for op in file.ops ?? [] { state.clock.observe(op.h) }
            for record in (file.records ?? [:]).values { state.clock.observe(record.h) }
            if file.kind == "snapshot" { changed.formUnion(state.replica.ingest(snapshot: file)) }
            else { changed.formUnion(state.replica.ingest(log: file)) }
            state.files[name] = Meta(kind: file.kind, device: file.device, seq: file.seq, vv: file.vv, at: file.at, seen: now, size: size)
            state.damaged[name] = nil
        }
        for name in pulled.damaged where state.damaged[name] == nil { state.damaged[name] = now }
        // Gone from the folder: compacted away by some Mac.
        for name in Array(state.files.keys) where !pulled.listed.contains(name) { state.files[name] = nil }
        for name in Array(state.damaged.keys) where !pulled.listed.contains(name) { state.damaged[name] = nil }
        // A damaged file holds nothing back after a day; it is still read
        // every cycle, and applied if it ever opens.
        let stuck = state.damaged.filter { now - $0.value < 86_400_000 }.count
        waiting = pulled.waiting.count + stuck
        if !pulled.files.isEmpty { note("Read \(pulled.files.count) file\(pulled.files.count == 1 ? "" : "s"), \(changed.count) change\(changed.count == 1 ? "" : "s")") }
        return changed
    }

    /// Ops stamped, saved here as the pending batch, then written. False
    /// when the folder didn't take it (it goes again next cycle).
    @discardableResult
    func publish(_ ops: [SyncOp]) async -> Bool {
        guard let keys, let vault else { return false }
        state.seq += 1
        let stamped = ops.map { SyncOp(k: $0.k, h: state.clock.tick(), v: $0.v) }
        let file = SyncFile.log(device: state.device, seq: state.seq, ops: stamped)
        _ = state.replica.ingest(log: file)
        let name = SyncKeys.freshName()
        state.pending = file
        state.pendingName = name
        save()
        guard let size = await write(file, as: name, vault: vault, keys: keys) else { return false }
        state.pending = nil
        state.pendingName = nil
        let now = Date().timeIntervalSince1970 * 1000
        state.files[name] = Meta(kind: "log", device: state.device, seq: file.seq, vv: nil, at: file.at, seen: now, size: size)
        save()
        note("Wrote \(stamped.count) change\(stamped.count == 1 ? "" : "s")")
        return true
    }

    /// Sealed and written; its size, or nil when the folder refused it.
    private func write(_ file: SyncFile, as name: String, vault: SyncVault, keys: SyncKeys) async -> Int? {
        let done: Result<Int, Error> = await Self.offMain {
            Result {
                let sealed = try keys.seal(try JSONEncoder().encode(file), chain: vault.chain, scope: vault.scope, file: name)
                try vault.write(sealed, as: name)
                return sealed.count
            }
        }
        switch done {
        case .success(let size): return size
        case .failure(let error):
            status = .offline
            note("Couldn't write to the folder: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - domains

extension FolderSync {
    private func run(_ domain: Domain, changed: Set<String>) -> [SyncOp] {
        guard let browser else { return [] }
        switch domain {
        case .spaces:
            // One sync at a time owns the spaces: Copper Cloud's keys and
            // intents are kept against its own copy.
            if CloudSync.shared.active(.spaces) {
                note("Spaces sync through Copper Cloud — left to it")
                return []
            }
            return document(domain, records: SyncRecords.records, doc: SyncRecords.spaces,
                            build: { CloudApply.spaces(browser, base: $0) },
                            merge: CloudMerge.spaces,
                            apply: { CloudApply.apply(spaces: $0, base: $1, in: browser) },
                            brake: { CloudMerge.losses(from: $0, to: $1) })
        case .settings:
            return document(domain, records: SyncRecords.records, doc: SyncRecords.settings,
                            build: { _ in CloudApply.settings(browser) },
                            merge: CloudMerge.settings,
                            apply: { doc, _ in CloudApply.apply(settings: doc, in: browser) })
        case .bookmarks:
            return document(domain, records: SyncRecords.records, doc: SyncRecords.bookmarks,
                            build: { _ in CloudApply.bookmarks(browser) },
                            merge: CloudMerge.bookmarks,
                            apply: { doc, _ in CloudApply.apply(bookmarks: doc, in: browser) })
        case .history:
            return history(changed: changed, browser: browser)
        case .tabs:
            return openTabs()
        case .extensions:
            return extensions(changed: changed)
        }
    }

    /// Copper Cloud's three-way merge, with the folder's records as the
    /// server: the base (records as last synced), this Mac's copy and the
    /// folder's. What the merge makes is applied here; whatever of it the
    /// folder doesn't say yet goes out.
    private func document<T: Equatable>(
        _ domain: Domain,
        records: (T) -> [String: String],
        doc: ([String: String]) -> T,
        build: (T?) -> T,
        merge: (T?, T, T) -> T,
        apply: (T, T?) -> Void,
        brake: ((T, T) -> CloudMerge.Losses)? = nil
    ) -> [SyncOp] {
        let mine = SyncRecords.of(domain.kind)
        let server = state.replica.live(mine)
        let based = state.based.contains(domain)
        let serverDoc = doc(server)
        let baseDoc = based ? doc(state.base.filter { mine($0.key) }) : nil
        let local = doc(records(build(baseDoc)))
        let merged: T
        if let baseDoc, local == baseDoc { merged = serverDoc } else { merged = doc(records(merge(baseDoc, local, serverDoc))) }
        // The brake, both ways: what would unfile or remove more than a
        // handful of kept tabs on every Mac (unless the person asked for it
        // by name), or here from another Mac, or drop a folder that holds
        // some, waits for the person. The base stays where it was.
        if based, let brake, !letThrough {
            let out = brake(serverDoc, merged), into = brake(local, merged)
            let hold: CloudSync.Hold? = out.big && CloudIntents.shared.confirmed == nil ? .outgoing(out)
                : into.big ? .incoming(into, version: 0, payload: Data()) : nil
            if let hold {
                if held != hold { note("Held spaces: \(hold.text)") }
                held = hold
                dirty.insert(domain)
                return []
            }
        }
        if domain == .spaces { held = nil }
        if merged != local { applying { apply(merged, baseDoc) } }
        let out = records(merged)
        var ops: [SyncOp] = []
        for (key, value) in out where server[key] != value { ops.append(SyncOp(k: key, h: "", v: value)) }
        for key in server.keys where out[key] == nil { ops.append(SyncOp(k: key, h: "", v: nil)) }
        state.base = state.base.filter { !mine($0.key) }.merging(out) { $1 }
        if !based { state.based.append(domain) }
        if merged != local { note("Applied \(domain.rawValue) from the other Macs") }
        return ops
    }

    /// Writing another Mac's changes here doesn't count as an edit.
    private func applying(_ body: () -> Void) {
        applyingRemote = true
        CloudIntents.shared.quietly(body)
        applyingRemote = false
    }

    /// Visits: a record per place. Applying takes the later visit and the
    /// higher count (`History.take`), so Macs settle on the union; a page
    /// forgotten here stays forgotten here, and isn't deleted elsewhere.
    private func history(changed: Set<String>, browser: Browser) -> [SyncOp] {
        let mine = SyncRecords.of(.history)
        let fresh = !state.based.contains(.history)
        var ops: [SyncOp] = []
        var published = Set<String>()
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        for visit in CloudApply.visits() where visit.last >= cutoff {
            let key = "h:" + visit.key
            let value = SyncRecords.encode(SyncRecords.Place(u: visit.url, t: visit.title, n: visit.count, l: visit.last.timeIntervalSince1970.rounded(), p: visit.profiles))
            guard state.base[key] != value else { continue }
            state.base[key] = value
            if state.replica.records[key]?.v != value {
                ops.append(SyncOp(k: key, h: "", v: value))
                published.insert(key)
            }
        }
        let remote = fresh ? Set(state.replica.records.keys.filter(mine)) : changed.filter(mine)
        var took = 0
        applying {
            for key in remote where !published.contains(key) {
                guard let value = state.replica.records[key]?.v, value != state.base[key],
                      let place = SyncRecords.decode(SyncRecords.Place.self, value), let url = URL(string: place.u) else { continue }
                browser.history.take(url, title: place.t, count: place.n, last: Date(timeIntervalSince1970: place.l), profiles: place.p)
                state.base[key] = value
                took += 1
            }
            if took > 0 { browser.history.settle() }
        }
        if fresh { state.based.append(.history) }
        if took > 0 { note("Took \(took) visit\(took == 1 ? "" : "s") from the other Macs") }
        return ops
    }

    /// This Mac's open tabs, for the others to look at: one record, its own.
    private func openTabs() -> [SyncOp] {
        let key = "tabs:\(state.device)"
        let doc = CloudApply.openTabs(device: Self.deviceName)
        let tabs = doc.tabs.prefix(100).map { CloudDocs.Tabs.Open(url: $0.url, title: $0.title, space: $0.space, active: nil) }
        let value = SyncRecords.encode(SyncRecords.Tabs(n: Self.deviceName, tabs: Array(tabs)))
        guard state.replica.records[key]?.v != value else { return [] }
        return [SyncOp(k: key, h: "", v: value)]
    }

    /// Open tabs turned off: the others stop showing this Mac's.
    private func retireTabs() -> [SyncOp] {
        let key = "tabs:\(state.device)"
        return state.replica.records[key]?.v == nil ? [] : [SyncOp(k: key, h: "", v: nil)]
    }

    /// This Mac, by name.
    private func ownDevice() -> [SyncOp] {
        let key = "dev:\(state.device)"
        let value = SyncRecords.encode(SyncRecords.Device(n: Self.deviceName))
        return state.replica.records[key]?.v == value ? [] : [SyncOp(k: key, h: "", v: value)]
    }

    /// Web Store extensions as a set. Installed here and not in the folder:
    /// it goes out. Gone from here since the last cycle: `removed`, a live
    /// record. In the folder and not here: installed from the Web Store,
    /// as Move in installs a list it was given (the switch is the consent).
    /// Removed elsewhere: never uninstalled here, and not sent back.
    private func extensions(changed: Set<String>) -> [SyncOp] {
        guard #available(macOS 15.4, *) else { return [] }
        let store = Extensions.shared
        let mine = SyncRecords.of(.extensions)
        let installed = Dictionary(store.installed.filter(\.fromStore).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Fork (ardia profiles): where each runs goes with it. A change read
        // from the folder this cycle is taken here before anything goes out.
        var scopes = Dictionary(store.installed.filter(\.fromStore).map { ($0.id, $0.profiles) }, uniquingKeysWith: { a, _ in a })
        let seen = Set(state.extSeen ?? [])
        var ignored = Set(state.extIgnored).subtracting(Set(installed.keys).subtracting(seen)) // installed again here: counts again
        var ops: [SyncOp] = []
        func record(_ id: String) -> SyncRecords.Ext? { state.replica.records["ext:\(id)"]?.v.flatMap { SyncRecords.decode(SyncRecords.Ext.self, $0) } }
        if state.extSeen != nil {
            for key in changed.filter(mine) {
                let id = String(key.dropFirst(4))
                guard let have = record(id), have.removed != true, let here = scopes[id], here != have.p else { continue }
                store.setProfiles(id, have.p)
                scopes[id] = have.p
            }
        }
        // Removed elsewhere, still here from before: stays, and isn't sent
        // back. (Joining is a union: what this Mac has goes out.)
        if state.extSeen != nil {
            for (id, _) in installed where seen.contains(id) && record(id)?.removed == true { ignored.insert(id) }
        }
        for (id, name) in installed where !ignored.contains(id) {
            if let have = record(id), have.removed != true, have.p == scopes[id] ?? nil { continue }
            ops.append(SyncOp(k: "ext:\(id)", h: "", v: SyncRecords.encode(SyncRecords.Ext(n: name, p: scopes[id] ?? nil))))
        }
        if state.extSeen != nil {
            for id in seen where installed[id] == nil {
                guard let have = record(id), have.removed != true, !installing.contains(id) else { continue }
                ops.append(SyncOp(k: "ext:\(id)", h: "", v: SyncRecords.encode(SyncRecords.Ext(n: have.n, removed: true))))
            }
        }
        let published = Set(ops.map(\.k))
        let remote = state.extSeen == nil ? Set(state.replica.records.keys.filter(mine)) : changed.filter(mine)
        for key in remote where !published.contains(key) {
            let id = String(key.dropFirst(4))
            guard let have = record(id), have.removed != true, installed[id] == nil,
                  !installing.contains(id), !failedInstalls.contains(id) else { continue }
            install(id, name: have.n, profiles: have.p)
        }
        state.extIgnored = Array(ignored).sorted()
        state.extSeen = Array(installed.keys).sorted()
        return ops
    }

    @available(macOS 15.4, *)
    private func install(_ id: String, name: String, profiles: [String]? = nil) {
        installing.insert(id)
        note("Installing \(name) from the Web Store")
        Task {
            let landed = await Extensions.shared.installAgreed(id: id, enabled: true, profiles: profiles)
            installing.remove(id)
            if landed { state.extSeen = ((state.extSeen ?? []) + [id]).sorted() } else { failedInstalls.insert(id) }
            note(landed ? "Installed \(name)" : "Couldn't install \(name) — try again from Settings › Extensions")
        }
    }
}

// MARK: - compaction

extension FolderSync {
    /// A snapshot when no snapshot has been written in 10 minutes and the
    /// logs it would newly cover number more than 40 and either reach 400 or
    /// weigh a quarter of the last snapshot (with no snapshot yet, 40 are
    /// enough). Then files it covers go, once they're an hour old here. A
    /// cycle that writes none clears the logs this Mac's newest snapshot
    /// covers. A snapshot is only ever removed by one that covers it, just
    /// written, so a Mac joining later always finds one whole.
    private func compact(vault: SyncVault, keys: SyncKeys) async {
        let now = Date().timeIntervalSince1970 * 1000
        let hour = 3_600_000.0
        let snapshots = state.files.values.filter { $0.kind == "snapshot" }
        func covered(_ meta: Meta, by vv: [String: Int]?) -> Bool {
            guard let seq = meta.seq, let vv else { return false }
            return (vv[meta.device] ?? 0) >= seq
        }
        let loose = state.files.values.filter { meta in
            meta.kind == "log" && state.replica.has(meta.device, meta.seq ?? 0) && !snapshots.contains { covered(meta, by: $0.vv) }
        }
        let biggest = snapshots.map(\.size).max() ?? 0
        let lately = max(snapshots.map(\.at).max() ?? 0, state.lastSnapshot ?? 0)
        let due = snapshots.isEmpty
            ? loose.count > 40
            : loose.count > 40 && (loose.count >= 400 || loose.map(\.size).reduce(0, +) >= biggest / 4) && now - lately > 600_000

        var gone: [String] = []
        if due {
            state.replica.records = state.replica.kept()
            let file = SyncFile(kind: "snapshot", device: state.device, at: now, vv: state.replica.vv, records: state.replica.records)
            let name = SyncKeys.freshName()
            guard let size = await write(file, as: name, vault: vault, keys: keys) else { return }
            state.files[name] = Meta(kind: "snapshot", device: state.device, seq: nil, vv: file.vv, at: now, seen: now, size: size)
            state.lastSnapshot = now
            note("Wrote a snapshot of \(file.records?.count ?? 0) records")
            let vv = file.vv ?? [:]
            gone = state.files.filter { other, meta in
                guard other != name, now - meta.seen > hour else { return false }
                if meta.kind == "log" { return covered(meta, by: vv) }
                return (meta.vv ?? [:]).allSatisfy { (vv[$0.key] ?? 0) >= $0.value }
            }.map(\.key)
        } else if let newest = snapshots.filter({ $0.device == state.device }).max(by: { $0.at < $1.at }) {
            gone = state.files.filter { _, meta in meta.kind == "log" && now - meta.seen > hour && covered(meta, by: newest.vv) }.map(\.key)
        }
        guard !gone.isEmpty else { return }
        let doomed = gone
        _ = await Self.offMain { for name in doomed { vault.remove(name) } }
        for name in gone { state.files[name] = nil }
        note("Cleared \(gone.count) file\(gone.count == 1 ? "" : "s") a snapshot covers")
    }
}

// MARK: - the other Macs, and the brake

extension FolderSync {
    func refreshPeers() {
        var seen: [String: Double] = [:]
        for meta in state.files.values { seen[meta.device] = max(seen[meta.device] ?? 0, meta.at) }
        let devices = state.replica.live { $0.hasPrefix("dev:") }
        peers = devices.compactMap { key, value -> Peer? in
            let id = String(key.dropFirst(4))
            guard id != state.device, let device = SyncRecords.decode(SyncRecords.Device.self, value) else { return nil }
            let tabs = state.replica.records["tabs:\(id)"]?.v.flatMap { SyncRecords.decode(SyncRecords.Tabs.self, $0) }?.tabs ?? []
            return Peer(id: id, name: device.n, seen: seen[id].map { Date(timeIntervalSince1970: $0 / 1000) }, tabs: tabs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One of another Mac's tabs, here, in front.
    func open(_ tab: CloudDocs.Tabs.Open) {
        guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { return }
        _ = Windows.current.open(url, foreground: true)
    }

    /// Sync it: what was held goes out, once.
    func letHeldThrough() async {
        guard held != nil else { return }
        letThrough = true
        dirty.insert(.spaces)
        note("Held spaces let through")
        await syncNow()
        letThrough = false
    }

    /// Undo Here (held going out): this Mac takes the folder's spaces, and
    /// its own edits go. Keep Mine (held coming in): the tabs another Mac
    /// would take away stay, noted as this Mac's own, and go out again.
    func keepHeldBack() async {
        guard let hold = held, let browser else { return }
        held = nil
        let mine = SyncRecords.of(.spaces)
        let server = state.replica.live(mine)
        switch hold {
        case .outgoing:
            let base = state.based.contains(.spaces) ? SyncRecords.spaces(state.base.filter { mine($0.key) }) : nil
            applying { CloudApply.apply(spaces: SyncRecords.spaces(server), base: base, in: browser) }
            CloudIntents.shared.reset()
            note("Held spaces undone here")
        case .incoming(let losses, _, _):
            CloudIntents.shared.keep(losses.unfiled + losses.removed)
            note("Kept this Mac's spaces")
        }
        state.base = state.base.filter { !mine($0.key) }.merging(server) { $1 }
        dirty.insert(.spaces)
        save()
        await syncNow()
    }

    /// For the page and the bench: how many records of each kind.
    var counts: [String: Int] {
        var out: [String: Int] = [:]
        for (key, record) in state.replica.records where record.v != nil {
            out[SyncRecords.kind(of: key)?.rawValue ?? "other", default: 0] += 1
        }
        return out
    }
}
