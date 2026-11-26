import AppKit
import Combine
import Foundation

// Shared folders: a Saved folder shared with other people through a
// directory in iCloud Drive (`iCloud Drive › Copper Shared › <name>`), two
// ways and live. Ardia's model (its docs/shared-folders.md) with one change:
// the directory holds no readable links. Each share has its own 256-bit key,
// and its files are iCloud sync's sealed files (Fork/FolderSync/): random
// names, ChaChaPoly, every file bound to its path. iCloud Drive's own
// sharing (Collaborate, from the share picker) carries the directory to the
// other person; the invite — a copper://folder/join link, or the key as 24
// words — opens it. Neither alone shows a link: Apple sees sealed files, and
// an invite without the directory opens nothing.
//
// Each Mac only ever adds files, a log of its changes, and every record
// (`name`, `ln:<id>` per link) is last-writer-wins by hybrid clock — the
// replica iCloud sync already has (FolderSyncReplica.swift). A cycle reads
// what is new, merges three ways against the base (the folder as both sides
// last agreed: `SharedPlan`), applies the other side's changes to the
// sidebar, and writes this side's as one sealed log. Design and limits:
// docs/shared-folders.md.

/// What a shared folder holds, per link: its address and name as shared
/// (a tab that browses on never rewrites them), its subfolder (`Reading`,
/// `Reading › Deep`; "" at the top) and its place when it was added.
struct SharedLink: Codable, Equatable {
    var u: String
    var t: String
    var f: String
    var i: Double
}

/// An invite: the share's key, and the directory's name to look for first.
struct FolderInvite: Equatable {
    var key: Data
    var name: String?

    enum Problem: Error, Equatable, LocalizedError {
        case notInvite
        case phrase(SyncPhrase.Problem)

        var errorDescription: String? {
            switch self {
            case .notInvite: return "That isn't a Copper shared folder invite. Paste the whole copper://folder/join link, or the 24 words."
            case .phrase(let problem): return problem.errorDescription
            }
        }
    }

    var link: String {
        var parts = URLComponents()
        parts.scheme = "copper"
        parts.host = "folder"
        parts.path = "/join"
        parts.queryItems = [URLQueryItem(name: "k", value: Self.encode(key))] + (name.map { [URLQueryItem(name: "n", value: $0)] } ?? [])
        return parts.url?.absoluteString ?? ""
    }

    var words: [String] { SyncPhrase.words(for: key) }

    /// A link (anywhere in the text) or the 24 words.
    static func parse(_ text: String) throws -> FolderInvite {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.range(of: "copper://folder/", options: .caseInsensitive) {
            let link = trimmed[at.lowerBound...].split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" }).first.map(String.init) ?? ""
            guard let url = URL(string: link), let invite = from(url) else { throw Problem.notInvite }
            return invite
        }
        do {
            return FolderInvite(key: try SyncPhrase.entropy(from: trimmed), name: nil)
        } catch let problem as SyncPhrase.Problem {
            if case .count(let n) = problem, n < 12 { throw Problem.notInvite }
            throw Problem.phrase(problem)
        }
    }

    /// `copper://folder/join?k=<key>&n=<name>`, or nil.
    static func from(_ url: URL) -> FolderInvite? {
        guard url.scheme?.lowercased() == "copper", url.host()?.lowercased() == "folder", url.path == "/join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let text = items.first(where: { $0.name == "k" })?.value, let key = decode(text), key.count == 32 else { return nil }
        let name = items.first(where: { $0.name == "n" })?.value?.trimmingCharacters(in: .whitespaces)
        return FolderInvite(key: key, name: name?.isEmpty == false ? name : nil)
    }

    /// base64url, no padding.
    static func encode(_ key: Data) -> String {
        key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}

/// The three-way merge of one cycle, pure. `local` is the folder here as
/// records, `base` the records as both sides last agreed, `remote` the
/// directory's. What changed here goes out (`ops`); what changed only there
/// comes in (`apply`); `base` is what both will say after.
enum SharedPlan {
    struct Change: Equatable {
        var key: String
        var value: String?
    }

    struct Result: Equatable {
        var ops: [SyncOp] = []
        var apply: [Change] = []
        var base: [String: String] = [:]
        /// Links that left this Mac all at once, held back rather than
        /// deleted for everyone (`brake`).
        var held: [String] = []
    }

    /// More than three links gone here in one go, and more than half the
    /// folder: what a lost session or a flattened sidebar looks like, not a
    /// person tidying. Held until they say.
    static func brake(deleted: Int, of total: Int) -> Bool { deleted > 3 && deleted * 2 > total }

    static func plan(local: [String: String], base: [String: String], remote: [String: String], letThrough: Bool = false) -> Result {
        var out = Result(base: remote)
        let keys = Set(local.keys).union(base.keys).union(remote.keys).sorted()
        let gone = keys.filter { $0.hasPrefix("ln:") && local[$0] == nil && base[$0] != nil && remote[$0] != nil }
        let links = base.keys.filter { $0.hasPrefix("ln:") }.count
        let holding = !letThrough && brake(deleted: gone.count, of: links)
        for key in keys {
            let here = local[key], was = base[key], there = remote[key]
            // A folder's name is never deleted: none there yet is files still on their way.
            if key == "name", there == nil, was != nil { out.base[key] = was; continue }
            if here != was {
                if holding, gone.contains(key) {
                    out.held.append(key)
                    out.base[key] = was
                    continue
                }
                if here != there { out.ops.append(SyncOp(k: key, h: "", v: here)) }
                out.base[key] = here
            } else if there != was {
                out.apply.append(Change(key: key, value: there))
            }
        }
        // The name first: links filed into subfolders follow the folder's name.
        out.apply.sort { ($0.key == "name" ? 0 : 1, $0.key) < ($1.key == "name" ? 0 : 1, $1.key) }
        return out
    }
}

@MainActor
final class SharedFolders: ObservableObject {
    static let shared = SharedFolders()
    nonisolated static let scopeID = "folder"
    nonisolated static let directory = "Copper Shared"
    nonisolated static let service = "Copper Shared Folder"
    nonisolated static let io = DispatchQueue(label: "copper.shared-folders", qos: .utility)

    struct Binding: Codable, Equatable, Identifiable {
        /// The share's chain folder name: the same on every Mac in it.
        var id: String
        /// The folder in the sidebar here.
        var group: UUID
        var space: UUID
        var path: String
        var owner: Bool
        var device: String
        var seq = 0
        var clock: SyncClock
        var replica = SyncReplica()
        var base: [String: String] = [:]
        /// Files read, by name.
        var files: [String] = []
        var pending: SyncFile?
        var pendingName: String?
        var lastSync: Double?
        var added: Double
    }

    enum Health: Equatable {
        case updating, updated, waiting(Int), missing, failed(String), held(Int)

        var text: String {
            switch self {
            case .updating: return "Updating…"
            case .updated: return "Up to date"
            case .waiting(let n): return "Waiting for \(n) file\(n == 1 ? "" : "s") from iCloud"
            case .missing: return "The shared folder is missing from iCloud Drive"
            case .failed(let why): return "Not syncing: \(why)"
            case .held(let n): return "\(n) links left this Mac at once — held"
            }
        }

        var isHeld: Bool {
            if case .held = self { return true }
            return false
        }

        var bad: Bool {
            switch self {
            case .missing, .failed, .held: return true
            default: return false
            }
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noDrive, keychain, already, notFound(String?), folder(String), invite(FolderInvite.Problem)

        var errorDescription: String? {
            switch self {
            case .noDrive: return "iCloud Drive is off on this Mac. Turn it on in System Settings, or choose another folder that syncs."
            case .keychain: return "Copper couldn't keep the folder's key in the keychain."
            case .already: return "This shared folder is already in your sidebar."
            case .notFound(let name):
                return "Copper couldn't find \(name.map { "“\($0)”" } ?? "the shared folder") in iCloud Drive. Accept the iCloud invitation first and give it a moment to download, or choose the folder."
            case .folder(let why): return "Copper couldn't use that folder: \(why)"
            case .invite(let problem): return problem.errorDescription
            }
        }
    }

    @Published private(set) var bindings: [Binding] = []
    @Published private(set) var health: [String: Health] = [:]
    @Published private(set) var damaged: [String: Int] = [:]
    private(set) var log: [String] = []

    private var testRoot: String?
    private weak var browser: Browser?
    private var started = false
    private var keyCache: [String: SyncKeys] = [:]
    /// Per share, which link each tab here is, for this run.
    private var tabKeys: [String: [Tab.ID: String]] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchWorkItem?
    private var due: Date?
    private var ticker: Timer?
    private var running = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var applying = false
    private var letThrough: Set<String> = []
    private var bag: Set<AnyCancellable> = []

    private struct File: Codable {
        var bindings: [Binding]
        var root: String?
    }

    private static var stateFile: URL { Store.file("shared-folders.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.stateFile), let saved = try? JSONDecoder().decode(File.self, from: data) {
            bindings = saved.bindings
            testRoot = saved.root
        }
    }

    /// 0600, atomic, off the main thread.
    private func save() {
        let copy = File(bindings: bindings, root: testRoot)
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

    func note(_ text: String) {
        log.append(text)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if Headless.on { Headless.log("shared folders: \(text)") }
    }

    nonisolated static func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in io.async { done.resume(returning: body()) } }
    }

    // MARK: - where

    /// Where shared folders are made and looked for: iCloud Drive. A test
    /// world never touches it: a folder of its own, or `bench shared root`.
    var root: URL {
        guard Store.testing else { return SyncVault.iCloudDrive }
        return URL(fileURLWithPath: testRoot ?? Store.file("iCloud Drive (test)").path, isDirectory: true)
    }

    var driveOn: Bool { Store.testing || SyncVault.iCloudDriveOn }

    func setTestRoot(_ path: String) {
        guard Store.testing else { return }
        testRoot = path
        save()
    }

    func binding(_ id: String) -> Binding? { bindings.first { $0.id == id } }
    func binding(of group: UUID) -> Binding? { bindings.first { $0.group == group } }

    private func keysFor(_ id: String) -> SyncKeys? {
        if let have = keyCache[id] { return have }
        guard let entropy = FolderSecrets.load(service: Self.service, account: id), entropy.count == 32 else { return nil }
        let keys = SyncKeys(entropy: entropy)
        keyCache[id] = keys
        return keys
    }

    func invite(for id: String) -> FolderInvite? {
        guard let b = binding(id), let key = FolderSecrets.load(service: Self.service, account: id), key.count == 32 else { return nil }
        return FolderInvite(key: key, name: URL(fileURLWithPath: b.path).lastPathComponent)
    }

    private func vaultFor(_ b: Binding, _ keys: SyncKeys) -> SyncVault {
        SyncVault(folder: URL(fileURLWithPath: b.path, isDirectory: true), chain: keys.chain, scope: keys.scope(Self.scopeID))
    }

    /// A directory name from a folder's: no `/` or `:`, no leading dot.
    nonisolated static func safeName(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = String(clean.prefix(100))
        return clean.isEmpty ? "Shared Folder" : clean
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    /// `<base>/<name>`, or `<name> 2`… when taken, with the share's own
    /// folders inside it.
    nonisolated static func makeDirectory(in base: URL, named name: String, chain: String, scope: String) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for n in 1...200 {
            let dir = base.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: dir.path) else { continue }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(chain).appendingPathComponent(scope), withIntermediateDirectories: true)
            return dir
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// The directory holding this share: by the invite's name first, then
    /// two levels of the root — where iCloud puts a folder someone shared
    /// with you, and where Copper makes them.
    nonisolated static func find(chain: String, name: String?, in root: URL) -> URL? {
        func holds(_ dir: URL) -> Bool { isDirectory(dir.appendingPathComponent(chain)) }
        if let name {
            for dir in [root.appendingPathComponent(name), root.appendingPathComponent(directory).appendingPathComponent(name)] where holds(dir) { return dir }
        }
        let files = FileManager.default
        func children(_ dir: URL) -> [URL] {
            ((try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter(isDirectory)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var budget = 4000
        for top in children(root) {
            if holds(top) { return top }
            for inner in children(top) {
                budget -= 1
                if budget < 0 { return nil }
                if holds(inner) { return inner }
            }
        }
        return nil
    }
}

// MARK: - starting, sharing, joining, stopping

extension SharedFolders {
    /// Once, for the first window, after its session is back: a folder's
    /// links are only ever read once its tabs are.
    func start(for browser: Browser) {
        guard browser.primary, !started else { return }
        started = true
        self.browser = browser
        Groups.shared.objectWillChange.sink { [weak self] in self?.changedHere() }.store(in: &bag)
        Spaces.shared.objectWillChange.sink { [weak self] in self?.changedHere() }.store(in: &bag)
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { SharedFolders.shared.schedule(0) }
        }
        for b in bindings { watch(b) }
        schedule(3)
    }

    private func changedHere() {
        guard !applying, !bindings.isEmpty else { return }
        schedule(3)
    }

    /// A cycle in `seconds`, unless one is due sooner.
    func schedule(_ seconds: Double) {
        guard browser != nil, !bindings.isEmpty else { return }
        let when = Date().addingTimeInterval(seconds)
        // Never later: a sidebar that keeps changing must not push the cycle off for ever.
        if timer != nil, let due, due <= when { return }
        timer?.cancel()
        due = when
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.due = nil
            }
            Task { await self?.cycleAll() }
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Another Mac's file arriving is a write to the scope folder.
    private func watch(_ b: Binding) {
        watchers[b.id]?.cancel()
        watchers[b.id] = nil
        guard let keys = keysFor(b.id) else { return }
        let fd = Darwin.open(vaultFor(b, keys).scopeFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend, .link], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule(1) } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watchers[b.id] = source
    }

    private func spaceHere(of group: UUID, in browser: Browser) -> UUID {
        let spaces = Spaces.shared
        if let tab = Groups.shared.members(of: group, in: browser).first, let space = spaces.spaceID(of: tab) { return space }
        if let space = Groups.shared.group(group)?.space, spaces.all.contains(where: { $0.id == space }) { return space }
        return spaces.current(in: browser)
    }

    /// Share Folder: a new directory with a new key, this folder's links
    /// written into it. `parent` is where `Copper Shared` goes when iCloud
    /// Drive is off. Shared already: the same invite again.
    func share(_ group: TabGroup, in browser: Browser, parent: URL? = nil) async throws -> FolderInvite {
        if let b = binding(of: group.id), let again = invite(for: b.id) { return again }
        guard parent != nil || driveOn else { throw Failure.noDrive }
        if self.browser == nil { start(for: Windows.main) }
        let base = (parent ?? root).appendingPathComponent(Self.directory, isDirectory: true)
        let name = Self.safeName(Folders.leaf(group.name))
        let entropy = SyncPhrase.fresh()
        let keys = SyncKeys(entropy: entropy)
        let scope = keys.scope(Self.scopeID)
        let made: Result<URL, CocoaError> = await Self.offMain {
            do { return .success(try Self.makeDirectory(in: base, named: name, chain: keys.chain, scope: scope)) }
            catch { return .failure(CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])) }
        }
        let dir: URL
        switch made {
        case .success(let at): dir = at
        case .failure(let error): throw Failure.folder(error.localizedDescription)
        }
        guard FolderSecrets.save(entropy, service: Self.service, account: keys.chain) else { throw Failure.keychain }
        bind(keys, group: group.id, space: spaceHere(of: group.id, in: browser), path: dir.path, owner: true, base: [:])
        note("Shared “\(group.name)” in \(dir.path)")
        await syncNow()
        return FolderInvite(key: entropy, name: dir.lastPathComponent)
    }

    /// Add Shared Folder: the invite's key, its directory found (or the
    /// one picked), a new folder in this space's Saved filled from it.
    @discardableResult
    func join(_ text: String, in browser: Browser, picked: URL? = nil) async throws -> Binding {
        let invite: FolderInvite
        do { invite = try FolderInvite.parse(text) } catch { throw Failure.invite(error as? FolderInvite.Problem ?? .notInvite) }
        let keys = SyncKeys(entropy: invite.key)
        guard binding(keys.chain) == nil else { throw Failure.already }
        if self.browser == nil { start(for: Windows.main) }
        let root = self.root
        let found: URL? = await Self.offMain {
            if let picked { return Self.isDirectory(picked.appendingPathComponent(keys.chain)) ? picked : nil }
            return Self.find(chain: keys.chain, name: invite.name, in: root)
        }
        guard let dir = found else { throw Failure.notFound(invite.name ?? picked?.lastPathComponent) }
        guard FolderSecrets.save(invite.key, service: Self.service, account: keys.chain) else { throw Failure.keychain }
        // Named for the directory until the folder's own name is read; its
        // base says so, so that name comes in rather than going out.
        let name = invite.name ?? dir.lastPathComponent
        let space = Spaces.shared.current(in: browser)
        let group = Groups.shared.adding(named: name, hue: nil)
        Groups.shared.imported(group.id, collapsed: false, space: space, slot: nil)
        bind(keys, group: group.id, space: space, path: dir.path, owner: false, base: ["name": SyncRecords.encode(["n": name])])
        note("Joined “\(name)” in \(dir.path)")
        await syncNow()
        return binding(keys.chain) ?? bindings.last!
    }

    private func bind(_ keys: SyncKeys, group: UUID, space: UUID, path: String, owner: Bool, base: [String: String]) {
        keyCache[keys.chain] = keys
        let device = FolderSync.freshDevice()
        let b = Binding(id: keys.chain, group: group, space: space, path: path, owner: owner, device: device,
                        clock: SyncClock(device: device), base: base, added: Date().timeIntervalSince1970)
        bindings.removeAll { $0.id == b.id }
        bindings.append(b)
        health[b.id] = .updating
        save()
        watch(b)
    }

    /// Stop Syncing Folder: the folder and its tabs stay here, the
    /// directory stays with everyone else; only the binding and key go.
    func stop(_ id: String, why: String = "Stopped syncing") {
        guard let b = binding(id) else { return }
        watchers[id]?.cancel()
        watchers[id] = nil
        FolderSecrets.forget(service: Self.service, account: id)
        keyCache[id] = nil
        tabKeys[id] = nil
        health[id] = nil
        letThrough.remove(id)
        bindings.removeAll { $0.id == id }
        save()
        note("\(why): \(URL(fileURLWithPath: b.path).lastPathComponent)")
    }

    /// The links held by the brake: gone for everyone, as they are here.
    func letHeldThrough(_ id: String) {
        letThrough.insert(id)
        schedule(0)
    }

    /// The links held by the brake: back here, from the directory.
    func putHeldBack(_ id: String) {
        guard let i = bindings.firstIndex(where: { $0.id == id }) else { return }
        let local = currentLocal(bindings[i])
        for key in bindings[i].base.keys where key.hasPrefix("ln:") && local[key] == nil { bindings[i].base[key] = nil }
        save()
        schedule(0)
    }

    private func currentLocal(_ b: Binding) -> [String: String] {
        guard let browser, let top = Groups.shared.group(b.group) else { return [:] }
        return local(b, top: top, browser: browser).records
    }
}

// MARK: - the cycle

extension SharedFolders {
    /// Sync Now: every shared folder, awaited — after the cycle running.
    func syncNow() async {
        if running {
            again = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        await cycleAll()
    }

    func cycleAll() async {
        if running { again = true; return }
        running = true
        repeat {
            again = false
            for id in bindings.map(\.id) { await cycle(id) }
        } while again
        running = false
        let done = waiters
        waiters = []
        done.forEach { $0.resume() }
    }

    private func cycle(_ id: String) async {
        guard let browser, let start = binding(id) else { return }
        guard let keys = keysFor(id) else { health[id] = .failed("its key is missing — add it again with the invite"); return }
        guard Groups.shared.group(start.group) != nil else { return stop(id, why: "Unbound: the folder left the sidebar") }
        let vault = vaultFor(start, keys)
        if health[id] == nil || health[id] == .missing { health[id] = .updating }

        // 1. The directory, still there.
        guard await Self.offMain({ vault.chainExists() }) else { health[id] = .missing; return }

        // 2. A batch saved but not written goes out first, unchanged.
        if let pending = binding(id)?.pending, let name = binding(id)?.pendingName {
            if let failure = await Self.write(pending, as: name, vault: vault, keys: keys) { health[id] = .failed(failure); return }
            update(id) { $0.pending = nil; $0.pendingName = nil; $0.files.append(name) }
        }

        // 3. What is new.
        let known = Set(binding(id)?.files ?? [])
        let pulled = await Self.offMain { FolderSync.pull(vault, keys, known: known) }
        if let offline = pulled.offline { health[id] = .failed(offline); return }
        guard var b = binding(id) else { return }
        // Read again after the wait: a folder ungrouped meanwhile must not
        // read as every link deleted.
        guard let top = Groups.shared.group(b.group) else { return stop(id, why: "Unbound: the folder left the sidebar") }
        take(pulled, into: &b)

        // 4. Three ways: what changed here goes out, what changed there comes in.
        let here = local(b, top: top, browser: browser)
        let remote = b.replica.live { $0 == "name" || $0.hasPrefix("ln:") }
        var plan = SharedPlan.plan(local: here.records, base: b.base, remote: remote, letThrough: letThrough.contains(id))
        letThrough.remove(id)
        let failed = apply(plan.apply, old: b.base, binding: b, top: top, tabs: here.tabs, browser: browser)
        for key in failed { plan.base[key] = b.base[key] } // tried again next cycle, never read as deleted here
        b.base = plan.base
        set(b)
        if !plan.held.isEmpty { note("Held \(plan.held.count) links that left this Mac at once") }

        // 5. Out, as one log.
        if !plan.ops.isEmpty {
            guard await publish(plan.ops, id: id, vault: vault, keys: keys) else { return }
        }
        health[id] = !plan.held.isEmpty ? .held(plan.held.count) : pulled.waiting.isEmpty ? .updated : .waiting(pulled.waiting.count)
        // Written only when something moved: a quiet cycle every 20 s writes nothing.
        if binding(id) != start {
            update(id) { $0.lastSync = Date().timeIntervalSince1970 }
            save()
        }
    }

    private func update(_ id: String, _ change: (inout Binding) -> Void) {
        guard let i = bindings.firstIndex(where: { $0.id == id }) else { return }
        change(&bindings[i])
    }

    private func set(_ b: Binding) {
        guard let i = bindings.firstIndex(where: { $0.id == b.id }) else { return }
        bindings[i] = b
    }

    private func take(_ pulled: FolderSync.Pulled, into b: inout Binding) {
        var changed = 0
        for (name, file, _) in pulled.files.sorted(by: { ($0.file.kind == "snapshot" ? 0 : 1) < ($1.file.kind == "snapshot" ? 0 : 1) }) {
            for op in file.ops ?? [] { b.clock.observe(op.h) }
            for record in (file.records ?? [:]).values { b.clock.observe(record.h) }
            changed += (file.kind == "snapshot" ? b.replica.ingest(snapshot: file) : b.replica.ingest(log: file)).count
            b.files.append(name)
        }
        // Gone from the directory: forgotten, so the list stays the folder's.
        b.files = b.files.filter { pulled.listed.contains($0) }
        damaged[b.id] = pulled.damaged.count
        if !pulled.files.isEmpty { note("Read \(pulled.files.count) file\(pulled.files.count == 1 ? "" : "s"), \(changed) change\(changed == 1 ? "" : "s")") }
    }

    /// Sealed and written; nil, or why not.
    nonisolated static func write(_ file: SyncFile, as name: String, vault: SyncVault, keys: SyncKeys) async -> String? {
        await offMain {
            do {
                let sealed = try keys.seal(try JSONEncoder().encode(file), chain: vault.chain, scope: vault.scope, file: name)
                try vault.write(sealed, as: name)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// Ops stamped and saved here as the pending batch, then written.
    // shortcut: one sealed log per change and no snapshots, so a busy folder's directory only grows; add FolderSync's compaction when one passes ~500 files.
    private func publish(_ ops: [SyncOp], id: String, vault: SyncVault, keys: SyncKeys) async -> Bool {
        guard var b = binding(id) else { return false }
        b.seq += 1
        let stamped = ops.map { SyncOp(k: $0.k, h: b.clock.tick(), v: $0.v) }
        let file = SyncFile.log(device: b.device, seq: b.seq, ops: stamped)
        b.replica.ingest(log: file)
        let name = SyncKeys.freshName()
        b.pending = file
        b.pendingName = name
        set(b)
        save()
        if let failure = await Self.write(file, as: name, vault: vault, keys: keys) {
            health[id] = .failed(failure)
            note("Couldn't write: \(failure)")
            return false
        }
        update(id) { $0.pending = nil; $0.pendingName = nil; $0.files.append(name) }
        note("Wrote \(stamped.count) change\(stamped.count == 1 ? "" : "s")")
        return true
    }
}

// MARK: - the folder here, as records, and back

extension SharedFolders {
    /// The folder and the folders inside it, by their path below it.
    private func family(of top: TabGroup) -> [UUID: String] {
        var out: [UUID: String] = [:]
        // shortcut: a nested folder is matched by name, so another space's folder of the same nested name would count; key subfolders by id if that bites.
        for group in Groups.shared.all where group.id == top.id || Folders.below(group.name, top.name) {
            out[group.id] = group.id == top.id ? "" : String(group.name.dropFirst(top.name.count + Folders.mark.count))
        }
        return out
    }

    /// This Mac's side: a record per link and the folder's name, and which
    /// tab each link is. A tab keeps its link across a run; after a launch
    /// it finds it again by address, then by site in the same subfolder. A
    /// link keeps the address and name it was shared with — browsing in its
    /// tab never rewrites it.
    func local(_ b: Binding, top: TabGroup, browser: Browser) -> (records: [String: String], tabs: [String: Tab]) {
        let groups = Groups.shared
        let paths = family(of: top)
        var seen = Set<Tab.ID>()
        let candidates: [(tab: Tab, url: URL, f: String)] = (browser.tabs + Spaces.shared.everyTab).compactMap { tab in
            guard seen.insert(tab.id).inserted, tab.pin == nil, !tab.shy, !tab.bench,
                  let group = groups.membership[tab.id], let f = paths[group],
                  let url = tab.pending ?? tab.address, url.scheme?.hasPrefix("http") == true else { return nil }
            return (tab, url, f)
        }
        var shared: [String: SharedLink] = [:]
        for (key, value) in b.base where key.hasPrefix("ln:") {
            if let link = SyncRecords.decode(SharedLink.self, value) { shared[key] = link }
        }
        let known = tabKeys[b.id] ?? [:]
        var used = Set<String>()
        var keyFor: [Tab.ID: String] = [:]
        for item in candidates {
            if let key = known[item.tab.id], !used.contains(key) { keyFor[item.tab.id] = key; used.insert(key) }
        }
        let sortedShared = shared.sorted { $0.key < $1.key }
        // By site only on the first look this run, when no tab is known yet:
        // later, a link closed and another added on the same site at once
        // would otherwise swap identities.
        for exact in tabKeys[b.id] == nil ? [true, false] : [true] {
            for item in candidates where keyFor[item.tab.id] == nil {
                let match = sortedShared.first { key, link in
                    guard !used.contains(key) else { return false }
                    if exact { return link.u == item.url.absoluteString }
                    return link.f == item.f && URL(string: link.u)?.host()?.lowercased() == item.url.host()?.lowercased()
                }
                if let match { keyFor[item.tab.id] = match.key; used.insert(match.key) }
            }
        }
        var next = shared.values.map(\.i).max() ?? 0
        var records: [String: String] = ["name": SyncRecords.encode(["n": Folders.leaf(top.name)])]
        var tabs: [String: Tab] = [:]
        for item in candidates {
            let key = keyFor[item.tab.id] ?? "ln:" + String(SyncKeys.freshName().prefix(16))
            keyFor[item.tab.id] = key
            tabs[key] = item.tab
            if let was = shared[key] {
                records[key] = SyncRecords.encode(SharedLink(u: was.u, t: was.t, f: item.f, i: was.i))
            } else {
                next += 1
                let title = item.tab.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.tab.title
                records[key] = SyncRecords.encode(SharedLink(u: item.url.absoluteString, t: title, f: item.f, i: next))
            }
        }
        tabKeys[b.id] = keyFor
        return (records, tabs)
    }

    /// The other side's changes, here: the name, links added (asleep, in
    /// their subfolder), moved, re-addressed, deleted. Returns the keys it
    /// couldn't apply, so they are tried again rather than read as deleted.
    private func apply(_ changes: [SharedPlan.Change], old: [String: String], binding b: Binding, top: TabGroup,
                       tabs: [String: Tab], browser: Browser) -> Set<String> {
        guard !changes.isEmpty else { return [] }
        var failed = Set<String>()
        applying = true
        defer { applying = false }
        CloudIntents.shared.quietly {
            var creates: [(key: String, link: SharedLink)] = []
            for change in changes {
                if change.key == "name" {
                    guard let value = change.value, let name = SyncRecords.decode([String: String].self, value)?["n"],
                          !name.isEmpty, name != Folders.leaf(top.name), let now = Groups.shared.group(top.id) else { continue }
                    let parent = now.name.dropLast(Folders.leaf(now.name).count)
                    Groups.shared.rename(top.id, to: String(parent) + name)
                    continue
                }
                let tab = tabs[change.key]
                guard let value = change.value, let link = SyncRecords.decode(SharedLink.self, value) else {
                    if let tab { drop(tab, browser: browser) }
                    continue
                }
                guard let tab else { creates.append((change.key, link)); continue }
                let was = old[change.key].flatMap { SyncRecords.decode(SharedLink.self, $0) }
                if was?.u != link.u, let url = URL(string: link.u), url.scheme?.hasPrefix("http") == true {
                    if tab.asleep { tab.restore(url: url, title: link.t) } else { tab.go(to: url) }
                }
                if was?.f != link.f, let top = Groups.shared.group(b.group) { place(tab, in: folder(link.f, under: top), top: top, browser: browser) }
            }
            for (key, link) in creates.sorted(by: { $0.link.i != $1.link.i ? $0.link.i < $1.link.i : $0.key < $1.key }) {
                guard let url = URL(string: link.u), url.scheme?.hasPrefix("http") == true,
                      let top = Groups.shared.group(b.group),
                      let tab = Spaces.shared.cloudOpen(url, title: link.t, pin: nil, in: spaceHere(of: b.group, in: browser), browser: browser) else {
                    failed.insert(key)
                    continue
                }
                tabKeys[b.id, default: [:]][tab.id] = key
                place(tab, in: folder(link.f, under: top), top: top, browser: browser)
            }
        }
        if !changes.isEmpty { note("Applied \(changes.count) change\(changes.count == 1 ? "" : "s") from the folder") }
        return failed
    }

    /// A link deleted there: its tab goes, unless it is the one on screen —
    /// then it stays, out of the folder.
    private func drop(_ tab: Tab, browser: Browser) {
        if Windows.all.contains(where: { $0.activeID == tab.id }) {
            Groups.shared.remove(tab)
        } else {
            Spaces.shared.cloudClose(tab, browser: browser)
        }
    }

    /// The subfolder at `path` below `top`, made if it isn't there.
    private func folder(_ path: String, under top: TabGroup) -> TabGroup {
        guard !path.isEmpty else { return top }
        var parent = top
        for part in path.components(separatedBy: Folders.mark) where !part.isEmpty {
            let name = parent.name + Folders.mark + part
            parent = Groups.shared.all.first { $0.name == name } ?? Groups.shared.createInside(parent, named: part) ?? parent
        }
        return parent
    }

    /// Filed, and moved beside the rest of its folder in the row on screen
    /// (a parked space's row is gathered when it is next restored).
    private func place(_ tab: Tab, in group: TabGroup, top: TabGroup, browser: Browser) {
        let groups = Groups.shared
        groups.cloudFile(tab, in: group.id)
        guard let here = browser.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let family = Set(self.family(of: top).keys)
        let rows = browser.tabs.enumerated().filter { $0.element.id != tab.id && $0.element.pin == nil }
        let anchor = rows.last { groups.membership[$0.element.id] == group.id }?.offset
            ?? rows.last { groups.membership[$0.element.id].map { family.contains($0) } ?? false }?.offset
        guard let anchor else { return }
        let target = anchor < here ? anchor + 1 : anchor
        if target != here { browser.move(tab, to: target) }
    }
}
