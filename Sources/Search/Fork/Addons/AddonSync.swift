import Foundation

// Asking the linked Copper Cloud which addons apply to the person signed in,
// and keeping what it answers (contract §6.2–6.3). Modelled on
// CloudIntelligence: started once at launch (MCP.start), asked again when
// the link or the account changes, when the event stream says `addons`, when
// Copper looks for its own update (launch, every six hours, Check for
// Updates — the Updates.check hook) and every six hours of its own.
//
// An answer is turned into a plan (AddonState.swift). A slot whose addon was
// turned off, unassigned or replaced by nothing goes back to its own view at
// once; new settings for the same bundle reach the page at once. A new addon
// or version is downloaded through the same authenticated, pinned client as
// everything else Cloud-shaped, verified, and kept in staging — then offered
// the way a new Copper is (the sidebar pill, Settings › Updates, ⌘K) and
// installed only when the person says so, with no relaunch.
//
// Cloud.request takes no headers of its own, so there is no If-None-Match:
// the answer's `revision` is compared instead, and an unchanged revision
// changes nothing. The list is small; the bundles, the part that costs, are
// only fetched when the revision says something changed.

@MainActor
final class AddonSync: ObservableObject {
    static let shared = AddonSync()

    static let interval: TimeInterval = 6 * 60 * 60

    @Published private(set) var state: AddonState
    @Published private(set) var checking = false
    /// What the last ask came to, in a word or two: `never`, `ok`,
    /// `unchanged`, `none (404)`, `offline`, `error (500)`, `not signed in`.
    @Published private(set) var lastOutcome = "never"
    /// The last thing that went wrong, as a sentence; nil once a check works.
    @Published private(set) var lastError: String?
    @Published private(set) var lastAsked: Date?
    /// `COPPER_ADDONS_DEV_DIR` (or the bench's `addons dev`): a folder that
    /// takes its manifest's slot ahead of anything installed.
    @Published private(set) var development: AddonInstalled?
    @Published private(set) var developmentProblem: String?
    /// Remind Me Later on the pill: the staged bundle (SHA-256) it was said
    /// about. Not saved — a new launch, or another bundle, brings it back.
    @Published var snoozed: String?
    /// The last few things that happened, newest last, for the bench.
    private(set) var log: [String] = []

    let store: AddonStore

    private var started = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var inFlight: Task<Void, Never>?
    private var offline = false
    private var developmentLoads = 0

    private init() {
        store = AddonStore(root: Store.file("addons"))
        state = store.load()
    }

    private var cloud: Cloud { Cloud.shared }

    /// `link URL|user id` while linked and signed in; nil otherwise.
    private var identity: String? {
        if fake != nil { return AddonSync.fakeSource }
        guard let link = cloud.link, let account = cloud.account else { return nil }
        return "\(link.url.absoluteString)|\(account.userId.uuidString.lowercased())"
    }

    /// The bench's stand-in for a cloud (test worlds only): `resolved` is
    /// read as the answer of `GET /v1/addons` on every check (so a test can
    /// rewrite it between checks), and a bundle is `bundles/<sha256>.json`.
    /// Everything after the two reads — plan, verify, stage, the pill,
    /// Install — is the real path.
    struct Fake {
        var resolved: URL
        var bundles: URL
    }

    static let fakeSource = "bench"
    var fake: Fake? {
        didSet { if fake != nil { state.revision = "" } }
    }

    /// A cloud GET, or the fake's file for it.
    private func get(_ path: String, sha: String? = nil) async throws -> Data {
        if let fake {
            let file = sha.map { fake.bundles.appendingPathComponent("\($0).json") } ?? fake.resolved
            guard let data = try? Data(contentsOf: file) else {
                throw Cloud.Failure(status: 404, code: "not_found", message: "\(file.path) is not there")
            }
            return data
        }
        return try await cloud.request("GET", path).0
    }

    // MARK: - starting

    /// Once, at launch (MCP.start). Idempotent.
    func start() {
        guard !started else { return }
        started = true
        // The bundle an install replaced was kept until now.
        store.collect(keeping: state)
        if Store.testing, let folder = ProcessInfo.processInfo.environment["COPPER_ADDONS_DEV_DIR"], !folder.isEmpty {
            useDevelopment(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true))
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AddonSync.shared.cloudChanged() }
        })
        observers.append(center.addObserver(forName: Cloud.event, object: nil, queue: .main) { note in
            let type = (note.userInfo?["event"] as? [String: Any])?["type"] as? String
            MainActor.assumeIsolated {
                if type == "addons" {
                    AddonSync.shared.refresh(force: true, why: "the cloud said addons changed")
                } else if type == "open" {
                    // The stream (re)connected: an `addons` event may have
                    // been missed meanwhile. Not forced, so a flapping
                    // connection doesn't become a stream of asks.
                    AddonSync.shared.refresh(force: false, why: "the event stream reconnected")
                }
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: AddonSync.interval, repeats: true) { _ in
            MainActor.assumeIsolated { AddonSync.shared.refresh(force: false, why: "six hours") }
        }
        timer?.tolerance = 15 * 60
        // A few seconds after launch, as Copper's own update check: session
        // restore and the first window draw come first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            AddonSync.shared.refresh(force: true, why: "launch")
        }
        publish()
    }

    /// Copper looked for its own update (Updates.check): addons too. The
    /// automatic checks skip an ask made in the last few minutes; Check for
    /// Updates always asks.
    func updatesChecked(force: Bool) {
        refresh(force: force, why: force ? "Check for Updates" : "update check")
    }

    /// Ask now. `force: false` skips an ask made in the last five minutes.
    func refresh(force: Bool, why: String = "asked") {
        guard identity != nil, inFlight == nil else { return }
        if !force, let lastAsked, Date().timeIntervalSince(lastAsked) < 5 * 60 { return }
        inFlight = Task { @MainActor in
            await self.fetch(why: why)
            self.inFlight = nil
        }
    }

    /// The same ask, awaited (the bench, Settings' button).
    func check() async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard identity != nil else {
            lastOutcome = "not signed in"
            return
        }
        let task = Task { @MainActor in await self.fetch(why: "asked") }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func cloudChanged() {
        guard let identity else { return }
        if identity != state.owner {
            refresh(force: true, why: "signed in")
        } else if offline, cloud.reachable {
            refresh(force: true, why: "back online")
        }
    }

    // MARK: - asking

    private func fetch(why: String) async {
        guard let identity, let host = fake != nil ? AddonSync.fakeSource : cloud.link?.host else {
            lastOutcome = "not signed in"
            return
        }
        checking = true
        defer { checking = false }
        lastAsked = Date()
        let resolved: AddonResolvedSet
        do {
            let data = try await get("/v1/addons")
            guard self.identity == identity else { return }
            guard let set = AddonResolvedSet.parse(data) else {
                lastOutcome = "error (unreadable)"
                lastError = "The cloud's list of addons didn't read"
                return
            }
            resolved = set
        } catch let failure as Cloud.Failure {
            guard self.identity == identity else { return }
            if failure.status == 404 {
                // A cloud from before addons: none apply.
                resolved = .empty
            } else {
                // Offline, refused, or the server having a moment: what is
                // installed stays, and the next tick asks again.
                offline = failure.status == 0
                lastOutcome = failure.status == 0 ? "offline" : "error (\(failure.status))"
                lastError = failure.message
                note("Couldn't ask \(host) for addons: \(failure.message)")
                return
            }
        } catch {
            offline = true
            lastOutcome = "offline"
            return
        }
        offline = false
        // Another person on this Mac: their addons, planned from scratch.
        if state.owner != identity {
            state.owner = identity
            state.revision = ""
        }
        state.lastCheck = AddonTime.text(Date())
        for addon in resolved.addons where !addon.runsHere {
            let why = AddonSlot(rawValue: addon.slot) == nil ? "a slot this Copper doesn't know (\(addon.slot))"
                : (addon.bridge > Addons.bridge ? "bridge \(addon.bridge), newer than this Copper's" : "not made for the Mac")
            note("Skipped \(addon.id) \(addon.version): \(why)")
        }
        if !resolved.revision.isEmpty, resolved.revision == state.revision {
            lastOutcome = "unchanged"
            lastError = nil
            save()
            return
        }
        let plan = AddonPlan.make(state, resolved)
        apply(plan, resolved)
        var failed: String?
        for want in plan.stage {
            do {
                try await stage(want, from: host)
            } catch {
                failed = "\(want.name) \(want.version): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                note("Couldn't get \(want.id) \(want.version): \(failed ?? "")")
            }
        }
        guard self.identity == identity else { return }
        if let failed {
            lastOutcome = "error (download)"
            lastError = failed
        } else {
            // Only an answer applied in full is remembered: a failed
            // download is tried again on the next check.
            state.revision = resolved.revision
            lastOutcome = resolved.revision.isEmpty && resolved.addons.isEmpty ? "none" : "ok"
            lastError = nil
        }
        if !plan.isEmpty { note("Checked (\(why)): \(describe(plan))") }
        save()
        publish()
    }

    /// Removals and settings, which never wait for a click.
    private func apply(_ plan: AddonPlan, _ resolved: AddonResolvedSet) {
        for slot in plan.remove {
            if let gone = state.installed[slot.rawValue] { note("\(gone.name) left the \(slot.name)") }
            state.installed[slot.rawValue] = nil
        }
        for slot in plan.settings {
            guard let want = resolved.addon(for: slot) else { continue }
            state.installed[slot.rawValue]?.settings = AddonJSON(want.settings)
        }
        for slot in plan.dropPending {
            if let waiting = state.pending(slot) { try? FileManager.default.removeItem(at: store.url(waiting.dir)) }
            state.setPending(nil, for: slot)
        }
        if !plan.remove.isEmpty || !plan.settings.isEmpty || !plan.dropPending.isEmpty {
            save()
            publish()
        }
    }

    /// Download, verify, keep in staging, offer.
    private func stage(_ want: AddonResolved, from host: String) async throws {
        guard let slot = AddonSlot(rawValue: want.slot) else { return }
        let path = store.stagingPath(want.sha256)
        let file = store.url(path)
        let bundle: AddonBundle
        if let kept = try? Data(contentsOf: file),
           let verified = try? AddonBundle.verify(kept, sha256: want.sha256, id: want.id, version: want.version, slot: want.slot) {
            // Already here (the same bundle, its settings changed): no download.
            bundle = verified
        } else {
            let bytes = try await get(want.bundlePath, sha: want.sha256)
            bundle = try AddonBundle.verify(bytes, sha256: want.sha256, id: want.id, version: want.version, slot: want.slot)
            try AddonStore.writeAtomically(bytes, to: file, mode: 0o600)
        }
        var entry = AddonInstalled(want, dir: path, source: host)
        entry.adopt(bundle.manifest)
        state.setPending(entry, for: slot)
        note("\(entry.name) \(entry.version) is ready to install in the \(slot.name)")
    }

    // MARK: - what the slot shows

    /// The addon a slot shows now, or nil for its own view.
    func active(_ slot: AddonSlot) -> AddonInstalled? {
        if let development, development.slot == slot.rawValue { return development }
        return state.active(slot)
    }

    /// Installed addons, then staged ones not yet installed, in slot order.
    var installedList: [AddonInstalled] { AddonSlot.allCases.compactMap { state.installed[$0.rawValue] } }
    var pendingList: [AddonInstalled] { AddonSlot.allCases.compactMap { state.pending($0) } }

    /// What waits for Install, unless the person turned that addon off here.
    var offered: AddonInstalled? {
        pendingList.first { !state.disabled.contains($0.id) }
    }

    /// The words every update surface uses for it: "**<name> <version>**
    /// for the Agent sidebar" (contract §6.3).
    static func offer(_ entry: AddonInstalled) -> String {
        "\(entry.name) \(entry.version) for the \(AddonSlot(rawValue: entry.slot)?.name ?? entry.slot)"
    }

    func folder(of entry: AddonInstalled) -> URL { store.url(entry.dir) }

    func isEnabled(_ id: String) -> Bool { !state.disabled.contains(id) }

    // MARK: - what the person does

    /// Install what is staged — every slot's, or one. Nil, or what went wrong.
    @discardableResult
    func install(_ only: AddonSlot? = nil) -> String? {
        var problem: String?
        for slot in AddonSlot.allCases where only == nil || only == slot {
            guard let waiting = state.pending(slot) else { continue }
            do {
                let bytes = try Data(contentsOf: store.url(waiting.dir))
                let bundle = try AddonBundle.verify(bytes, sha256: waiting.sha256, id: waiting.id, version: waiting.version, slot: waiting.slot)
                let dir = store.bundleDir(waiting.id, waiting.sha256)
                try bundle.write(to: store.url(dir))
                var installed = waiting
                installed.dir = dir
                installed.installedAt = AddonTime.text(Date())
                installed.adopt(bundle.manifest)
                state.installed[slot.rawValue] = installed
                state.setPending(nil, for: slot)
                try? FileManager.default.removeItem(at: store.url(waiting.dir))
                note("Installed \(installed.name) \(installed.version) in the \(slot.name)")
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problem = "Couldn't install \(waiting.name) \(waiting.version): \(why)"
                note(problem ?? "")
                // A staged file that no longer verifies is no use: dropped,
                // and the next check fetches it again.
                try? FileManager.default.removeItem(at: store.url(waiting.dir))
                state.setPending(nil, for: slot)
                state.revision = ""
            }
        }
        save()
        publish()
        return problem
    }

    /// "Use in Agent sidebar": off keeps the addon installed but shows the
    /// slot's own view.
    func setEnabled(_ id: String, _ on: Bool) {
        guard state.disabled.contains(id) == on else { return }
        if on { state.disabled.removeAll { $0 == id } } else { state.disabled.append(id) }
        note("\(id) \(on ? "turned on" : "turned off") on this Mac")
        save()
        publish()
    }

    /// Remove: on this Mac, until the cloud next changes something.
    func remove(_ id: String) {
        for slot in AddonSlot.allCases {
            if state.installed[slot.rawValue]?.id == id { state.installed[slot.rawValue] = nil }
            if let waiting = state.pending(slot), waiting.id == id {
                try? FileManager.default.removeItem(at: store.url(waiting.dir))
                state.setPending(nil, for: slot)
            }
        }
        note("Removed \(id) on this Mac")
        save()
        publish()
    }

    /// A served-format bundle file from disk, staged as if the cloud had
    /// sent it (the bench's self-test lane, test worlds only).
    func stage(file: URL, settings: [String: Any]? = nil) throws -> AddonInstalled {
        let bytes = try Data(contentsOf: file)
        let bundle = try AddonBundle.parse(bytes)
        guard let slot = bundle.manifest.knownSlot else { throw AddonProblem(code: "slot", message: "unknown slot \(bundle.manifest.slot)") }
        let path = store.stagingPath(bundle.sha256)
        try AddonStore.writeAtomically(bytes, to: store.url(path), mode: 0o600)
        var entry = AddonInstalled(id: bundle.manifest.id, version: bundle.manifest.version, sha256: bundle.sha256, dir: path,
                                   settings: AddonJSON(settings ?? bundle.manifest.defaultSettings), installedAt: AddonTime.text(Date()),
                                   name: bundle.manifest.name, slot: slot.rawValue, entry: bundle.manifest.entry,
                                   bridge: bundle.manifest.bridge ?? 1, hosts: [], capabilities: [], source: "bench")
        entry.adopt(bundle.manifest)
        state.setPending(entry, for: slot)
        note("Staged \(entry.name) \(entry.version) from \(file.lastPathComponent)")
        save()
        publish()
        return entry
    }

    /// A folder to run in its manifest's slot ahead of anything installed,
    /// or nil to stop. Test worlds and development builds only.
    func useDevelopment(_ folder: URL?) {
        guard let folder else {
            development = nil
            developmentProblem = nil
            publish()
            return
        }
        do {
            let manifest = try AddonManifest.parse(Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            try manifest.validate()
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifest.entry).path) else {
                throw AddonProblem(code: "entry", message: "the entry \(manifest.entry) is not in \(folder.path)")
            }
            developmentLoads += 1
            var entry = AddonInstalled(id: manifest.id, version: manifest.version, sha256: "development-\(developmentLoads)",
                                       dir: folder.standardizedFileURL.path, settings: AddonJSON(manifest.defaultSettings),
                                       installedAt: AddonTime.text(Date()), name: manifest.name, slot: manifest.slot,
                                       entry: manifest.entry, bridge: manifest.bridge ?? 1, hosts: [], capabilities: [],
                                       source: AddonInstalled.developmentSource)
            entry.adopt(manifest)
            if (manifest.bridge ?? 1) > Addons.bridge { throw AddonProblem(code: "bridge", message: "it needs bridge \(manifest.bridge ?? 1)") }
            development = entry
            developmentProblem = nil
            note("Running \(manifest.name) from \(folder.path)")
        } catch {
            development = nil
            developmentProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            note("COPPER_ADDONS_DEV_DIR: \(developmentProblem ?? "")")
        }
        publish()
    }

    // MARK: - keeping

    private func save() {
        do { try store.save(state) } catch { note("Couldn't save state.json: \(error.localizedDescription)") }
    }

    /// Every slot web view and every update surface sees the change.
    private func publish() {
        AddonSlotHost.sync()
        objectWillChange.send()
    }

    /// What a slot's page went through (a load failure, a crash), in the same log.
    func noteFromHost(_ text: String) { note(text) }

    private func note(_ text: String) {
        log.append("\(AddonTime.text(Date())) \(text)")
        if log.count > 60 { log.removeFirst(log.count - 60) }
        CloudLog.note("Addons: \(text)")
    }

    private func describe(_ plan: AddonPlan) -> String {
        var parts: [String] = []
        if !plan.remove.isEmpty { parts.append("removed \(plan.remove.map(\.rawValue).joined(separator: ", "))") }
        if !plan.settings.isEmpty { parts.append("new settings for \(plan.settings.map(\.rawValue).joined(separator: ", "))") }
        if !plan.stage.isEmpty { parts.append("staged \(plan.stage.map { "\($0.id) \($0.version)" }.joined(separator: ", "))") }
        if !plan.dropPending.isEmpty { parts.append("dropped staged \(plan.dropPending.map(\.rawValue).joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    var status: [String: Any] {
        func row(_ e: AddonInstalled) -> [String: Any] {
            ["id": e.id, "name": e.name, "version": e.version, "slot": e.slot, "sha256": e.sha256, "dir": e.dir,
             "source": e.source, "enabled": isEnabled(e.id), "entry": e.entry, "capabilities": e.capabilities, "hosts": e.hosts,
             "settings": e.settings.any]
        }
        var active: [String: Any] = [:]
        for slot in AddonSlot.allCases { active[slot.rawValue] = self.active(slot).map(row) ?? NSNull() }
        return [
            "folder": store.root.path,
            "linked": cloud.isLinked, "signedIn": cloud.isSignedIn, "cloud": cloud.link?.host ?? "",
            "revision": state.revision, "lastCheck": state.lastCheck ?? "", "outcome": lastOutcome, "error": lastError ?? "",
            "checking": checking,
            "installed": installedList.map(row), "pending": pendingList.map(row), "disabled": state.disabled,
            "active": active, "development": development.map(row) ?? NSNull(), "developmentProblem": developmentProblem ?? "",
            "offered": offered.map(AddonSync.offer) ?? NSNull(),
            "hosts": AddonSlotHost.describe(),
            "log": Array(log.suffix(20)),
        ]
    }
}

extension AddonInstalled {
    /// What the verified manifest says wins over what the list said: the
    /// bundle's bytes are the ones checked.
    mutating func adopt(_ manifest: AddonManifest) {
        name = manifest.name
        entry = manifest.entry
        bridge = manifest.bridge ?? bridge
        hosts = manifest.hosts
        capabilities = manifest.capabilities
    }
}
