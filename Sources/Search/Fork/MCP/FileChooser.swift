import AppKit
import WebKit

// browser_file_upload: an agent answers a page's file chooser without a panel
// on anybody's screen.
//
// WebKit asks for files through `runOpenPanelWith` (Dialogs.swift), whose one
// hook lands here first. Two orders work, per tab:
//
//   armed    — browser_file_upload with paths before the click: the next
//              chooser that tab opens (within two minutes) gets them.
//   pending  — the Playwright order: the click opens the chooser, the call
//              after it answers. A chooser on a tab an agent is driving (hung
//              backstage, or a call in flight on it) is held, not shown, and
//              the call's answer says so; nobody answering within a minute
//              cancels it, as the page would see from Cancel.
//
// A chooser the user opens on their own tab, with no agent at it, is their
// own system panel, as before. Paths are checked before anything reaches the
// page: every one must exist, and a folder only where the input takes folders.

@MainActor
enum FileChooser {
    struct Armed { let urls: [URL]; let at: Date }
    struct Pending {
        let token = UUID()
        let multiple: Bool
        let directories: Bool
        let finish: ([URL]?) -> Void
    }

    static let armedFor: TimeInterval = 120
    static let heldFor: TimeInterval = 60

    private static var armed: [UUID: Armed] = [:]
    private(set) static var pending: [UUID: Pending] = [:]
    /// Tabs with an agent call in flight → how many.
    private static var busy: [UUID: Int] = [:]

    // MARK: - the page asks (Dialogs.swift)

    /// True when the chooser was answered or held here; false leaves it to
    /// the system panel.
    static func answer(_ web: WKWebView, _ parameters: WKOpenPanelParameters, _ done: @escaping ([URL]?) -> Void) -> Bool {
        guard let tab = AgentTabs.all.first(where: { $0.built === web }) else { return false }
        if let ready = armed.removeValue(forKey: tab.id), Date().timeIntervalSince(ready.at) < armedFor {
            done(parameters.allowsMultipleSelection ? ready.urls : Array(ready.urls.prefix(1)))
            return true
        }
        guard Dialogs.unattended(web) || busy[tab.id, default: 0] > 0 else { return false }
        pending.removeValue(forKey: tab.id)?.finish(nil)
        let held = Pending(multiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories, finish: done)
        pending[tab.id] = held
        DispatchQueue.main.asyncAfter(deadline: .now() + heldFor) {
            MainActor.assumeIsolated {
                guard pending[tab.id]?.token == held.token else { return }
                pending.removeValue(forKey: tab.id)?.finish(nil)
            }
        }
        return true
    }

    // MARK: - around every agent call (Tools.call)

    static func began(_ tab: UUID?) -> UUID? {
        if let tab { busy[tab, default: 0] += 1 }
        return tab
    }

    static func ended(_ tab: UUID?) {
        guard let tab else { return }
        busy[tab, default: 1] -= 1
        if busy[tab] ?? 0 <= 0 { busy[tab] = nil }
    }

    /// Told on the answer of whichever call left a chooser open.
    static func note(_ tab: UUID?, name: String) -> [Tools.Content] {
        guard let tab, pending[tab] != nil, name != "browser_file_upload" else { return [] }
        return [.text("### File chooser\nThe page opened a file chooser — call browser_file_upload with paths (absolute) to choose files, or with none to cancel.")]
    }

    // MARK: - the tool

    nonisolated static var tool: [String: Any] { [
        "name": "browser_file_upload",
        "description": "Choose files for the page's file chooser on your tab. After a click opened one, answers it; before the click, arms the next one the tab opens. Omit paths to cancel.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths of the files to upload; omit to cancel the chooser"] as [String: Any],
                "reason": Tools.reasonProperty,
                "tab": Tools.tabProperty,
            ] as [String: Any],
            "required": [String](),
        ] as [String: Any],
    ] }

    static func call(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        let tab = try Tools.current(browser)
        let paths = args["paths"] as? [String] ?? []
        if paths.isEmpty {
            if let held = pending.removeValue(forKey: tab.id) { held.finish(nil); return [.text("Cancelled the file chooser.")] }
            if armed.removeValue(forKey: tab.id) != nil { return [.text("Disarmed: the next file chooser on this tab opens as usual.")] }
            return [.text("No file chooser is open on this tab, and none was armed.")]
        }
        let held = pending[tab.id]
        let urls = try checked(paths, directories: held?.directories ?? false)
        guard let held else {
            armed[tab.id] = Armed(urls: urls, at: Date())
            return [.text("Armed: the next file chooser this tab opens (within \(Int(armedFor / 60)) min) gets \(names(urls)). Now click the file input.")]
        }
        if urls.count > 1, !held.multiple { throw Tools.Failure(text: "this file input takes one file; \(urls.count) given") }
        pending[tab.id] = nil
        held.finish(urls)
        // The page hears `change` on its next turn.
        try await Task.sleep(nanoseconds: 150_000_000)
        return [.text("Uploaded \(names(urls)). \(Tools.pageLine(tab))")]
    }

    /// Every path absolute (or ~), existing, and a file unless folders are taken.
    nonisolated static func checked(_ paths: [String], directories: Bool, files: FileManager = .default) throws -> [URL] {
        try paths.map { raw in
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw Tools.Failure(text: "\(raw): give an absolute path") }
            var folder: ObjCBool = false
            guard files.fileExists(atPath: path, isDirectory: &folder) else { throw Tools.Failure(text: "\(raw): no such file") }
            if folder.boolValue, !directories { throw Tools.Failure(text: "\(raw) is a folder; this input takes files") }
            return URL(fileURLWithPath: path)
        }
    }

    private static func names(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: ", ")
    }
}
