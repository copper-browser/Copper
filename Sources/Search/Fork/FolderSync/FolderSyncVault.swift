import Foundation

// The sync folder on disk: `<folder>/<chain>/<scope>/<file>.cps`. Reads and
// writes go through NSFileCoordinator, so iCloud Drive (or Dropbox) never
// hands over half a file or sees one half-written: a file is written whole in
// a temporary folder on the same volume and moved in. Files iCloud hasn't
// brought down yet (`.<name>.icloud` stubs, or dataless files) are reported
// as waiting, and asked for. Never on the main thread.

struct SyncVault: Sendable {
    let folder: URL
    let chain: String
    let scope: String

    var chainFolder: URL { folder.appendingPathComponent(chain, isDirectory: true) }
    var scopeFolder: URL { chainFolder.appendingPathComponent(scope, isDirectory: true) }

    struct Listing: Sendable {
        /// Files here in full, by name.
        var ready: [String: URL] = [:]
        /// Files still on their way down.
        var waiting: [String] = []
    }

    func list() throws -> Listing {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let items = try FileManager.default.contentsOfDirectory(at: scopeFolder, includingPropertiesForKeys: keys, options: [])
        var out = Listing()
        let suffix = "." + SyncKeys.suffix
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(suffix + ".icloud") {
                // An iCloud stub: ".<name>.cps.icloud".
                let real = String(name.dropFirst().dropLast(".icloud".count))
                out.waiting.append(real)
                try? FileManager.default.startDownloadingUbiquitousItem(at: scopeFolder.appendingPathComponent(real))
                continue
            }
            guard name.hasSuffix(suffix), !name.hasPrefix(".") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                out.waiting.append(name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            out.ready[name] = url
        }
        return out
    }

    func read(_ url: URL) throws -> Data {
        var failure: NSError?
        var out: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &failure) { at in
            out = Result { try Data(contentsOf: at) }
        }
        if let failure { throw failure }
        return try out.get()
    }

    /// Whole, under its final name, or not at all.
    func write(_ data: Data, as name: String) throws {
        try FileManager.default.createDirectory(at: scopeFolder, withIntermediateDirectories: true)
        let target = scopeFolder.appendingPathComponent(name)
        let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: scopeFolder, create: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent(name)
        try data.write(to: staged)
        var failure: NSError?
        var moved: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &failure) { at in
            do { try FileManager.default.moveItem(at: staged, to: at) } catch { moved = error }
        }
        if let failure { throw failure }
        if let moved { throw moved }
    }

    /// Gone already is fine.
    func remove(_ name: String) {
        let target = scopeFolder.appendingPathComponent(name)
        var failure: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forDeleting, error: &failure) { at in
            try? FileManager.default.removeItem(at: at)
        }
    }

    /// Delete My Sync Data: this phrase's whole folder.
    func removeChain() throws {
        var failure: NSError?
        var gone: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: chainFolder, options: .forDeleting, error: &failure) { at in
            do { try FileManager.default.removeItem(at: at) } catch { gone = error }
        }
        if let failure { throw failure }
        if let gone { throw gone }
    }

    func chainExists() -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: chainFolder.path, isDirectory: &folder) && folder.boolValue
    }

    /// Whether `folder` holds anyone's sync data (a phrase's folder, or its
    /// iCloud stub).
    static func holdsData(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { SyncKeys.isTag($0) || ($0.hasPrefix(".") && $0.hasSuffix(".icloud") && SyncKeys.isTag(String($0.dropFirst().dropLast(7)))) }
    }

    /// iCloud Drive's own folder, and the sync folder's default place in it.
    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// A test world never defaults to iCloud Drive: its own folder, unless
    /// it is given one (`bench icloud folder PATH`).
    static var defaultFolder: URL {
        Store.testing ? Store.file("Sync Folder") : iCloudDrive.appendingPathComponent("Copper", isDirectory: true)
    }

    /// Is iCloud Drive on: its folder is there.
    static var iCloudDriveOn: Bool { FileManager.default.isWritableFile(atPath: iCloudDrive.path) }
}
