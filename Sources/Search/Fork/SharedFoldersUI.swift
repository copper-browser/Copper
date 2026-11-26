import AppKit
import SwiftUI

// Shared folders on screen: a small two-people mark on a shared folder's
// header, its menu (Share Folder…, the invite, Sync Now, Stop Syncing), the
// sheet that shares one, and Add Shared Folder for the other side. The
// engine is Fork/SharedFolders.swift.

/// Beside a shared folder's name: two people, red while it isn't syncing.
struct SharedFolderMark: View {
    let group: UUID
    let tint: SpaceTint
    @ObservedObject private var shared = SharedFolders.shared

    var body: some View {
        if let b = shared.binding(of: group) {
            let health = shared.health[b.id]
            Image(systemName: "person.2.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(health?.bad == true ? Palette.danger : tint.muted)
                .padding(.leading, 5)
                .help(health?.text ?? "Shared through iCloud Drive")
                .accessibilityLabel("Shared")
        }
    }
}

/// On a folder's context menu.
struct SharedFolderMenu: View {
    let browser: Browser
    let group: TabGroup
    @ObservedObject private var shared = SharedFolders.shared

    var body: some View {
        if let b = shared.binding(of: group.id) {
            Divider()
            Button("Shared Folder…") { SharedFolderSheet.show(b.id, browser: browser) }
            Button("Copy Invite Link") { if let invite = shared.invite(for: b.id) { SettingsActions.copy(invite.link) } }
            Button("Sync Now") { Task { await shared.syncNow() } }
            Button("Stop Syncing Folder…") { SharedFolderSheet.confirmStop(b.id) }
        } else if !group.name.contains(Folders.mark) {
            Divider()
            Button("Share Folder…") { SharedFolderSheet.share(group, browser: browser) }
        }
    }
}

/// One shared folder: the two steps to share it, and how it is doing.
struct SharedFolderSheet: View {
    let id: String
    let browser: Browser
    @ObservedObject private var shared = SharedFolders.shared
    @State private var words = false
    @State private var copied = false

    @MainActor static func show(_ id: String, browser: Browser) {
        FolderPanel.show("Shared Folder", SharedFolderSheet(id: id, browser: browser))
    }

    /// Share Folder…: made, then shown. iCloud Drive off: a folder that syncs, picked.
    @MainActor static func share(_ group: TabGroup, browser: Browser, parent: URL? = nil) {
        Task {
            do {
                _ = try await SharedFolders.shared.share(group, in: browser, parent: parent)
                if let b = SharedFolders.shared.binding(of: group.id) { show(b.id, browser: browser) }
            } catch SharedFolders.Failure.noDrive {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Share Here"
                panel.message = "iCloud Drive is off on this Mac. Choose a folder that syncs (Dropbox, a shared drive) for Copper Shared."
                if panel.runModal() == .OK, let url = panel.url { share(group, browser: browser, parent: url) }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't share “\(Folders.leaf(group.name))”"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @MainActor static func confirmStop(_ id: String) {
        guard let b = SharedFolders.shared.binding(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Stop syncing this folder?"
        alert.informativeText = "The folder and its tabs stay in your sidebar, and stay shared with everyone else. Changes stop going both ways, and Copper forgets the folder's key on this Mac."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SharedFolders.shared.stop(b.id)
            FolderPanel.close()
        }
    }

    var body: some View {
        if let b = shared.binding(id), let invite = shared.invite(for: id) {
            let dir = URL(fileURLWithPath: b.path, isDirectory: true)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(Groups.shared.group(b.group).map { Folders.leaf($0.name) } ?? dir.lastPathComponent)” is shared")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Its links live sealed in \(place(dir)), under a key of its own. Someone you share it with needs both: the folder, from iCloud Drive, and the invite.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                step(1, "Share the folder in iCloud Drive", "Add people in the share sheet, or in Finder: Share › Share Folder.") {
                    ShareLink(item: dir) {
                        Text("Share in iCloud Drive…").font(.system(size: 11.5))
                    }
                    Pill("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
                step(2, "Send them the invite", "A link that opens it in Copper. Or read them the 24 words.") {
                    Pill(copied ? "Copied" : "Copy Invite Link", filled: true) {
                        SettingsActions.copy(invite.link)
                        copied = true
                    }
                    Pill(words ? "Hide Words" : "Show Words") { words.toggle() }
                }
                if words {
                    Text(invite.words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "   "))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.ink)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack(spacing: 8) {
                    let health = shared.health[id]
                    Circle().fill(health?.bad == true ? Palette.danger : Palette.accent).frame(width: 6, height: 6)
                    Text(health?.text ?? "Starting…").font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(2)
                    Spacer()
                    if health?.isHeld == true {
                        Pill("Delete for Everyone", tint: Palette.danger) { shared.letHeldThrough(id) }
                        Pill("Put Back") { shared.putHeldBack(id) }
                    } else {
                        Pill("Sync Now") { Task { await shared.syncNow() } }
                    }
                    Pill("Stop Syncing…", tint: Palette.danger) { SharedFolderSheet.confirmStop(id) }
                    Pill("Done") { FolderPanel.close() }
                }
            }
        } else {
            Text("This folder isn't shared any more.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private func place(_ dir: URL) -> String {
        let drive = SyncVault.iCloudDrive.path
        guard dir.path.hasPrefix(drive + "/") else { return dir.path }
        return "iCloud Drive › " + dir.path.dropFirst(drive.count + 1).replacingOccurrences(of: "/", with: " › ")
    }

    private func step<Buttons: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.onAccent)
                .frame(width: 18, height: 18).background(Circle().fill(Palette.accent))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { buttons() }
            }
        }
    }
}

/// Add Shared Folder: paste the invite; Copper finds the folder in iCloud Drive.
struct AddSharedFolderSheet: View {
    let browser: Browser
    @State var text: String
    @State private var busy = false
    @State private var problem: String?
    @State private var notFound = false

    @MainActor static func show(browser: Browser, text: String = "") {
        FolderPanel.show("Add Shared Folder", AddSharedFolderSheet(browser: browser, text: text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a shared folder").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Accept the iCloud Drive invitation first, then paste the invite link (or the 24 words) you were sent.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            TextField("copper://folder/join?k=…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { add(nil) }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if notFound { Pill("Choose Folder…") { choose() }.disabled(busy) }
                Spacer()
                Pill("Cancel") { FolderPanel.close() }
                Pill(busy ? "Adding…" : "Add", filled: !text.isEmpty) { add(nil) }.disabled(busy || text.isEmpty)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = SharedFolders.shared.root
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { add(url) }
    }

    private func add(_ picked: URL?) {
        guard !busy, !text.isEmpty else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await SharedFolders.shared.join(text, in: browser, picked: picked)
                FolderPanel.close()
            } catch {
                if case .notFound? = error as? SharedFolders.Failure { notFound = true }
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}

/// copper://folder/join, from another app or the field: the Add sheet, filled in.
@MainActor
enum SharedFolderJoin {
    static func handle(_ url: URL, in browser: Browser) -> Bool {
        guard url.scheme?.lowercased() == "copper", url.host()?.lowercased() == "folder" else { return false }
        AddSharedFolderSheet.show(browser: browser, text: url.absoluteString)
        return true
    }
}
