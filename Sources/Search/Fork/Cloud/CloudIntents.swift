import Foundation

// What the person changed by hand on this Mac in the spaces document since
// the cloud last took it: kept tabs filed, unfiled, saved, unsaved, pinned,
// unpinned, moved or removed, and folders dissolved. Only these may differ
// from the synced copy in what this Mac sends (`CloudMerge.intended`); the
// rest of its live state says nothing, so a Mac whose state drifted can't
// undo another's folders.
//
// Recorded where the edit is made (Groups, Sections, Spaces) and never
// while a document from elsewhere is being applied (`quietly`). A tab is
// noted twice: by the key it was kept under before the edit, resolved
// there and then, and by its id, which becomes the key it is kept under
// after, the next time the document is built. Kept in cloud-intents.json
// beside cloud-sync.json, so an edit made offline still goes out later.
// Each note carries a tick; what the server took, or overruled, as of a
// tick is let go (`clear(through:)`).

@MainActor
final class CloudIntents {
    static let shared = CloudIntents()

    private(set) var tick = 0
    /// Kept-tab keys changed here, by the tick each was last changed at.
    private(set) var keys: [String: Int] = [:]
    /// Folders dissolved here.
    private(set) var folders: [UUID: Int] = [:]
    /// Tabs changed since the document was last built, to key then.
    // shortcut: not saved across a relaunch (tab ids aren't); their old key, resolved when noted, is.
    private var tabs: [Tab.ID: Int] = [:]
    /// The tick of a bulk change the person already said yes to — a folder
    /// dissolved or closed from its menu, a space deleted — which the brake
    /// lets through (CloudSync).
    private(set) var confirmed: Int?
    private var quiet = 0
    private var saving = false

    private struct File: Codable {
        var keys: [String]
        var folders: [UUID]
        var confirmed: Bool
    }

    private static var file: URL { Store.file("cloud-intents.json") }

    private init() {
        guard let data = try? Data(contentsOf: CloudIntents.file),
              let saved = try? JSONDecoder().decode(File.self, from: data) else { return }
        keys = Dictionary(saved.keys.map { ($0, 0) }, uniquingKeysWith: { a, _ in a })
        folders = Dictionary(saved.folders.map { ($0, 0) }, uniquingKeysWith: { a, _ in a })
        confirmed = saved.confirmed ? 0 : nil
    }

    // MARK: - noting

    /// A kept tab's filing or keeping is about to change by hand. Before the
    /// change, so the key it is kept under now can still be found.
    func touched(_ tab: Tab) {
        guard quiet == 0 else { return }
        tick += 1
        tabs[tab.id] = tick
        if let key = CloudApply.key(of: tab, base: CloudSync.shared.spacesBase) { keys[key] = tick }
        save()
    }

    func touched(_ tabs: [Tab]) { tabs.forEach(touched) }

    /// A folder dissolved here (its tabs are noted by the caller).
    func dissolved(_ folder: UUID) {
        guard quiet == 0 else { return }
        tick += 1
        folders[folder] = tick
        save()
    }

    /// Keep mine (CloudSync): these keys stay as they are here.
    func keep(_ keys: [String]) {
        tick += 1
        for key in keys { self.keys[key] = tick }
        save()
    }

    /// A bulk change the person asked for in so many words.
    func confirm() {
        guard quiet == 0 else { return }
        confirmed = tick
        save()
    }

    /// Edits that aren't the person's: a document from elsewhere applied.
    func quietly(_ body: () -> Void) {
        quiet += 1
        defer { quiet -= 1 }
        body()
    }

    // MARK: - the document

    /// The document has been built: the tabs noted since take the keys they
    /// are kept under now. One no longer kept was noted by its old key.
    func resolve(_ keyFor: [Tab.ID: String]) {
        guard !tabs.isEmpty else { return }
        for (id, at) in tabs { if let key = keyFor[id] { keys[key] = max(keys[key] ?? 0, at) } }
        tabs = [:]
        save()
    }

    /// The server took a document built at `mark`, or kept its own over it:
    /// what was noted by then has been said.
    func clear(through mark: Int) {
        let before = (keys.count, folders.count, confirmed)
        keys = keys.filter { $0.value > mark }
        folders = folders.filter { $0.value > mark }
        if let at = confirmed, at <= mark { confirmed = nil }
        if before != (keys.count, folders.count, confirmed) { save() }
    }

    /// Another account, or Undo here: nothing noted counts any more.
    func reset() {
        keys = [:]
        folders = [:]
        tabs = [:]
        confirmed = nil
        save()
    }

    /// Several notes in a row are one write.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let me = CloudIntents.shared
                me.saving = false
                let saved = File(keys: Array(me.keys.keys).sorted(), folders: Array(me.folders.keys), confirmed: me.confirmed != nil)
                guard let data = try? JSONEncoder().encode(saved) else { return }
                try? data.write(to: CloudIntents.file, options: .atomic)
            }
        }
    }
}
