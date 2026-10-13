import AppKit
import Foundation

/// Whether Copper may read another browser's folder, and the one place a
/// person can change that.
///
/// Since macOS 15 another app's data under ~/Library/Application Support is
/// protected (TCC's "App Data" service, kTCCServiceSystemPolicyAppDataDetailed
/// on macOS 26/27). Chrome's folder is one of those; Arc's, at the time of
/// writing, is not. That service never shows a prompt: tccd logs "does not
/// allow prompting; recording denied" and the read fails with EPERM. What it
/// does do is record the request, which puts Copper in
/// Privacy & Security › Files & Folders, where one switch lets it in. Full
/// Disk Access also lets it in.
enum FlowAccess {
    enum State: Equatable, CustomStringConvertible {
        case readable
        case locked
        case missing

        var description: String {
            switch self {
            case .readable: return "readable"
            case .locked: return "locked"
            case .missing: return "missing"
            }
        }
    }

    /// One listing of the folder: what macOS answers for it. Listing
    /// another app's folder is the request macOS records (and, for Chrome,
    /// refuses), so this runs only once a person has opened Move in.
    static func state(of root: URL) -> State {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return .readable
        } catch let error as NSError {
            if denied(error) { return .locked }
            return .missing
        }
    }

    static func denied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return denied(underlying) }
        return false
    }

    /// The apps whose "installed but never opened" state the picker shows.
    /// Any other browser with no folder is simply not listed.
    static let bundles: [String: String] = [
        "Chrome": "com.google.Chrome",
    ]

    /// Whether the browser's app is on this Mac. A test run answers from
    /// `flow.installed` (comma-separated names) when that is set, so a
    /// fixture can stand in for "installed, never opened".
    static func installed(_ name: String) -> Bool {
        if Store.testing, let names = Store.settings.string(forKey: "flow.installed") {
            return names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(name)
        }
        guard let bundle = bundles[name] else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    /// Privacy & Security › Files & Folders, where Copper is listed once it
    /// has asked. Full Disk Access is the fallback page if that anchor is
    /// ever renamed; both let Copper in.
    static let privacyPages = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
    ]

    /// Opens the first page System Settings takes. A test run opens nothing
    /// (it would bring System Settings up in front of whoever is at the Mac)
    /// and answers with the page it would have opened.
    /// Privacy & Security › Full Disk Access, the one switch that opens
    /// Safari's files; the older pane's address as the fallback.
    static let fullDiskPages = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    ]

    /// A record tccd made for an earlier Copper signed differently (an
    /// ad-hoc build's cdhash, before the stable certificate) never matches
    /// this one: every read logs "Failed to match existing code requirement",
    /// is recorded denied, and the switch in System Settings falls back off
    /// each time the person turns it on. While the folder is locked the record
    /// grants nothing, so forget it and list the folder once: tccd records a
    /// fresh entry under the running signature, and that switch sticks.
    /// Only Copper's own entry for this one service is touched.
    static func renewRecord(for root: URL) {
        guard !Store.testing, let bundle = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "SystemPolicyAppDataDetailed", bundle]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Copper: Flow could not renew the App Data record: %@", error.localizedDescription)
            return
        }
        _ = state(of: root)
    }

    @discardableResult
    static func openPrivacySettings(fullDisk: Bool = false) -> String {
        let pages = fullDisk ? fullDiskPages : privacyPages
        if Store.testing { return pages[0] }
        for text in pages {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return text }
        }
        return ""
    }

    /// For `bench flow access`: every file the move reads, and what macOS
    /// says about each, with the error it gives. Reads metadata and the
    /// first bytes only.
    static func report(root: URL) -> [String: Any] {
        func probe(_ url: URL) -> String {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: url) } catch let error as NSError {
                if denied(error) { return "denied (\(code(error)))" }
                return FileManager.default.fileExists(atPath: url.path) ? "error \(code(error))" : "absent"
            }
            defer { try? handle.close() }
            let bytes = (try? handle.read(upToCount: 16)) ?? Data()
            return "readable (\(bytes.count) bytes read)"
        }
        func list(_ url: URL) -> String {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return "listable (\(names.count) entries)"
            } catch let error as NSError {
                if denied(error) { return "denied (\(code(error)))" }
                return "absent (\(code(error)))"
            }
        }
        var rows: [String: Any] = ["root": root.path, "list": list(root), "Local State": probe(root.appendingPathComponent("Local State"))]
        let profiles = FlowChromeTabs.profiles(at: root)
        rows["profiles"] = profiles
        let probeProfiles = profiles.isEmpty ? ["Default"] : profiles
        for profile in probeProfiles {
            let folder = root.appendingPathComponent(profile, isDirectory: true)
            var items: [String: String] = ["(folder)": list(folder)]
            for name in ["Preferences", "Bookmarks", "History", "Login Data", "Cookies", "Web Data"] {
                items[name] = probe(folder.appendingPathComponent(name))
            }
            items["Sessions/"] = list(folder.appendingPathComponent("Sessions"))
            items["Extensions/"] = list(folder.appendingPathComponent("Extensions"))
            items["Local Storage/"] = list(folder.appendingPathComponent("Local Storage/leveldb"))
            rows[profile] = items
        }
        return rows
    }

    private static func code(_ error: NSError) -> String {
        var parts = ["\(error.domain) \(error.code)"]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
        }
        return parts.joined(separator: " / ")
    }
}
