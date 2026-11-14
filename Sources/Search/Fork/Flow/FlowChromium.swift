import Foundation
import SQLite3

/// Root-aware copies of the small Chromium readers Flow needs for a selected
/// folder. Chromium's upstream `Source.files` discovers profiles through
/// Login Data; a read-only fallback copy may deliberately contain only the
/// session, history and bookmark files, so those paths are walked directly.
enum FlowChromium {
    static func bookmarks(in source: FlowSource) -> FlowBookmarks.Read {
        let profiles = source.profiles.map { source.root.appendingPathComponent($0, isDirectory: true) }
        return FlowBookmarks.bookmarks(in: profiles)
    }

    static func places(in source: FlowSource, limit: Int = Int.max) -> [Chromium.Place] {
        guard source.rootOverride != nil else { return Chromium.places(in: source.readerSource, limit: limit) }
        var out: [Chromium.Place] = []
        for profile in source.profiles {
            let file = source.root.appendingPathComponent(profile, isDirectory: true)
                .appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: file.path),
                  let rows = try? placeRows(in: file, limit: limit)
            else { continue }
            out += rows
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    /// How many places `places(in:)` would bring, without reading them:
    /// `SELECT COUNT(*)` over the same rows, for the preview's hint.
    static func placeCount(in source: FlowSource) -> Int {
        historyFiles(in: source).reduce(0) { total, file in
            total + ((try? count("SELECT COUNT(*) FROM urls WHERE hidden = 0 AND visit_count > 0", in: file)) ?? 0)
        }
    }

    /// How many saved passwords the Login Data files `Chromium.read` reads
    /// hold — counted, not decrypted, so it needs no key.
    static func loginCount(in source: FlowSource) -> Int {
        source.readerSource.files.reduce(0) { total, file in
            total + ((try? count("SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0 AND length(password_value) > 0",
                                 in: file)) ?? 0)
        }
    }

    /// The History files `places(in:)` reads: beside each profile's Login
    /// Data for the browser's own folder (Chromium.places), in each profile
    /// for a selected copy.
    private static func historyFiles(in source: FlowSource) -> [URL] {
        let files: [URL]
        if source.rootOverride == nil {
            files = source.readerSource.files.map { $0.deletingLastPathComponent().appendingPathComponent("History") }
        } else {
            files = source.profiles.map {
                source.root.appendingPathComponent($0, isDirectory: true).appendingPathComponent("History")
            }
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func count(_ query: String, in file: URL) throws -> Int {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-count-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var database: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Chromium.Place] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-history-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_close(database) }

        let query = """
        SELECT url, title, visit_count, last_visit_time FROM urls
        WHERE hidden = 0 AND visit_count > 0
        ORDER BY last_visit_time DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_finalize(statement) }

        var out: [Chromium.Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: raw))
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0
                ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600)
                : Date()
            out.append(Chromium.Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }
}

extension Browser {
    /// Same bookmark merge as the normal importer, rooted at Flow's selected
    /// copy when there is one. The file is read, and the merge worked out,
    /// off the main actor; only the swap of the top level happens here, so a
    /// large bookmarks file doesn't stall the window. Answers with the read
    /// itself and how many of its sites are new here, so the summary can
    /// tell "none" from "couldn't read the file" from "already here".
    @MainActor
    /// A read already in hand (Safari's), merged as a direct read is:
    /// re-imports replace only the roots the person left alone. Returns how
    /// many of its sites weren't here before.
    func takeBookmarks(_ found: FlowBookmarks.Read, from name: String) async -> Int {
        let before = bookmarks.roots
        let new = await Task.detached(priority: .userInitiated) {
            FlowBookmarks.addresses(found.nodes).subtracting(FlowBookmarks.addresses(before)).count
        }.value
        await FlowBookmarks.takeInBackground(found, from: name, into: bookmarks)
        let count = FlowBookmarks.count(found.nodes)
        // Fork (move-in-polish): with Move in up, its summary says this; no toast under it.
        if !Flow.shared.open { announce(count == 0 ? "No bookmarks in \(name)" : "\(count) bookmarks from \(name)") }
        return new
    }

    func bringBookmarks(from source: FlowSource) async -> (read: FlowBookmarks.Read, new: Int) {
        let before = bookmarks.roots
        let (found, new) = await Task.detached(priority: .userInitiated) { () -> (FlowBookmarks.Read, Int) in
            let found = FlowChromium.bookmarks(in: source)
            return (found, FlowBookmarks.addresses(found.nodes).subtracting(FlowBookmarks.addresses(before)).count)
        }.value
        await FlowBookmarks.takeInBackground(found, from: source.name, into: bookmarks)
        let count = FlowBookmarks.count(found.nodes)
        // Fork (move-in-polish): with Move in up, its summary says this; no toast under it.
        if !Flow.shared.open { announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)") }
        guard source.rootOverride == nil, count > 0 else { return (found, new) }
        let urls = FlowBookmarks.urls(found.nodes)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source.readerSource, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return (found, new)
    }
}
