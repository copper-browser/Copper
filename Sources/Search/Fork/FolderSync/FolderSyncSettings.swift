import AppKit
import SwiftUI

// Settings › Cloud › iCloud sync, above Copper Cloud. Off: Turn On Sync (a
// new phrase, then the Recovery Kit) or Enter Recovery Phrase (join the Macs
// already syncing), and the folder. On: how it's doing, what syncs, the other
// Macs and their tabs, the phrase behind Touch ID, and Stop Syncing. Dia's
// words where Dia has them (Ardia's docs/sync.md › UX).

struct ICloudSyncPage: View {
    let browser: Browser
    @ObservedObject private var sync = FolderSync.shared
    /// The words, while they're on screen: right after Turn On Sync, or
    /// after Show Words got past Touch ID.
    @State private var words: [String]?
    @State private var fresh = false
    @State private var entering = false
    @State private var phrase = ""
    @State private var busy = false
    @State private var problem: String?

    init(browser: Browser, kit: [String]? = nil) {
        self.browser = browser
        _words = State(initialValue: kit)
        _fresh = State(initialValue: kit != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("iCloud sync")
            Card {
                if sync.on { onLines } else { offLines }
            }
            if let words { kit(words) }
            if sync.on {
                if sync.held != nil { heldCard }
                Caption("What syncs").padding(.top, 10)
                Card {
                    ForEach(Array(FolderSync.Domain.allCases.enumerated()), id: \.element) { index, domain in
                        if index > 0 { Rule() }
                        Line(domain.title, domain.detail) {
                            Switch(on: Binding(get: { sync.enabled.contains(domain) }, set: { sync.set(domain, $0) }))
                        }
                    }
                }
                if !sync.peers.isEmpty { devices }
            }
        }
        .settingsAnchor("icloud.sync", card: true)
    }

    // MARK: - off

    private var holdsData: Bool { SyncVault.holdsData(sync.folder) }
    private var driveOff: Bool { sync.folder == SyncVault.defaultFolder && !Store.testing && !SyncVault.iCloudDriveOn }

    @ViewBuilder
    private var offLines: some View {
        // The sentence gets the whole width; the two buttons go under it.
        Line(sync.status == .reset ? "Not syncing" : "Sync · Off", offDetail) { EmptyView() }
        HStack(spacing: 8) {
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if holdsData {
                Pill("Turn On Sync") { turnOn() }.disabled(busy || driveOff)
                Pill("Enter Recovery Phrase…", filled: true) { entering = true }.disabled(busy)
            } else {
                Pill("Enter Recovery Phrase…") { entering = true }.disabled(busy)
                Pill("Turn On Sync", filled: !driveOff) { turnOn() }.disabled(busy || driveOff)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, -4)
        if entering {
            Rule()
            join
        }
        if let problem, !entering {
            Rule()
            Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.danger)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        Rule()
        Line("Sync folder", driveOff
             ? "iCloud Drive is off. Turn it on in System Settings › Apple Account › iCloud, or choose another folder — Dropbox, a NAS or a USB drive work too."
             : sync.folder.path) {
            HStack(spacing: 8) {
                if driveOff { Pill("iCloud Settings…") { openICloudSettings() } }
                Pill("Choose…") { chooseFolder() }
            }
        }
    }

    private var offDetail: String {
        if sync.status == .reset { return "This device is out of sync. Sync may have been reset from another device. Everything on this Mac stays as it is." }
        if holdsData { return "This folder already has synced data. Enter your recovery phrase to sync this Mac with the others." }
        return "End-to-end encrypted through your own iCloud Drive. No account and no server: a 24-word recovery phrase is the only key."
    }

    private var join: some View {
        let count = SyncPhrase.tokens(phrase).count
        return VStack(alignment: .leading, spacing: 8) {
            Text("Enter your 24-word recovery phrase to sync with another device.")
                .font(.system(size: 12)).foregroundStyle(Palette.ink)
            TextField("", text: $phrase, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(3...5)
                .autocorrectionDisabled()
                .background(alignment: .topLeading) {
                    if phrase.isEmpty {
                        Text("Enter your 24-word recovery phrase").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.muted).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Recovery phrase")
                .padding(.horizontal, 8).padding(.vertical, 6)
                .settingsField()
                .onSubmit(connect)
            HStack(spacing: 8) {
                Text(count > SyncPhrase.count ? "too many words" : "\(count)/\(SyncPhrase.count) words")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(count > SyncPhrase.count ? Palette.danger : Palette.muted)
                if let problem { Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Pill("Cancel") { entering = false; phrase = ""; problem = nil }
                Pill(busy ? "Connecting…" : "Connect", filled: count == SyncPhrase.count) { connect() }
                    .disabled(busy || count != SyncPhrase.count)
            }
            Text("Checked against the sync folder: \(sync.folder.path)")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func turnOn() {
        busy = true
        problem = nil
        Task {
            do {
                words = try await sync.turnOn()
                fresh = true
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }

    private func connect() {
        guard SyncPhrase.tokens(phrase).count == SyncPhrase.count, !busy else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await sync.join(phrase: phrase)
                phrase = ""
                entering = false
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SyncVault.iCloudDrive
        panel.message = "Choose the folder your Macs sync through. Every Mac picks the same one."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sync.choose(folder: url)
    }

    private func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings*iCloud") { NSWorkspace.shared.open(url) }
    }

    // MARK: - on

    @ViewBuilder
    private var onLines: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Line("Sync · On", statusLine(now: context.date)) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Pill("Sync Now") { Task { await sync.syncNow() } }.disabled(sync.status == .updating)
                }
            }
        }
        Rule()
        Line("Recovery phrase", "The only way into your synced data. Enter it on another Mac to sync it, or scan its code.") { EmptyView() }
        HStack(spacing: 8) {
            Spacer()
            if words == nil { Pill("Show Words") { reveal() } }
            Pill("Save Recovery Kit…") { Task { if let w = await sync.phrase(reason: "save your Copper recovery kit") { SyncKit.save(w, folder: sync.folder) } } }
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, -4)
        Rule()
        Line("Sync folder", sync.folder.path) {
            Pill("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sync.folder]) }
        }
        Rule()
        Line("Stop syncing this Mac", "Your other Macs stop seeing this one. Everything on this Mac stays as it is.") {
            Pill("Stop Syncing…", tint: Palette.danger) { stop() }
        }
    }

    private var dot: Color {
        switch sync.status {
        case .updated: return .green
        case .offline, .failed, .reset: return Palette.danger
        default: return .orange
        }
    }

    private func statusLine(now: Date) -> String {
        var line: String
        switch sync.status {
        case .off: line = "off"
        case .starting: line = "starting up"
        case .updating: line = sync.joining ? "looking for your other Macs' data…" : "updating"
        case .updated: line = "updated " + ago(sync.lastSync, now: now)
        case .offline: line = "offline — the sync folder isn't there (a drive unplugged, or iCloud Drive off)"
        case .failed(let why): line = why
        case .reset: line = "This device is out of sync."
        }
        if case .failed = sync.status, let last = sync.lastSync { line += " · last synced " + ago(last, now: now) }
        if sync.waiting > 0 { line += " · waiting for \(sync.waiting) file\(sync.waiting == 1 ? "" : "s") to download" }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    private func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "just now" }
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    private func reveal() {
        Task { if let w = await sync.phrase(reason: "show your Copper recovery phrase") { words = w; fresh = false } }
    }

    private func stop() {
        let alert = NSAlert()
        alert.messageText = "Stop Syncing This Device?"
        alert.informativeText = "Your other Macs will stop seeing this one, and its open tabs leave them. Everything on this Mac stays as it is. To sync again you'll need your recovery phrase."
        let delete = NSButton(checkboxWithTitle: "Also delete the synced data from the folder — every Mac stops syncing. I understand this cannot be undone.", target: nil, action: nil)
        delete.frame = NSRect(x: 0, y: 0, width: 300, height: 36)
        alert.accessoryView = delete
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let deleting = delete.state == .on
        words = nil
        Task { await sync.stop(deleting: deleting) }
    }

    // MARK: - the kit

    private func kit(_ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(fresh ? "Save your Recovery Kit" : "Recovery phrase").padding(.top, 10)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    if fresh {
                        Text("Your Recovery Kit contains all you need to recover your data should you lose access to this device. Save a copy to another device or to the cloud — you'll need it if you lose access to this one.")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        // Down the columns, as the printed kit reads.
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            ForEach(0..<8, id: \.self) { row in
                                GridRow {
                                    ForEach(0..<3, id: \.self) { column in
                                        let i = column * 8 + row
                                        HStack(spacing: 5) {
                                            Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 16, alignment: .trailing)
                                            Text(i < words.count ? words[i] : "").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Palette.ink)
                                        }
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        if let code = SyncKit.qr(words, side: 96) {
                            Image(nsImage: code).interpolation(.none).resizable().frame(width: 96, height: 96)
                                .accessibilityLabel("QR code of the recovery phrase")
                        }
                    }
                    HStack(spacing: 8) {
                        Pill("Copy Words") { SyncKit.copy(words) }
                        Pill("Save as Text…") { SyncKit.save(words, folder: sync.folder, asText: true) }
                        Spacer()
                        Pill(fresh ? "Close" : "Hide") { self.words = nil }
                        if fresh { Pill("Save…", filled: true) { SyncKit.save(words, folder: sync.folder) } }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    // MARK: - held, devices

    private var heldCard: some View {
        let outgoing: Bool = { if case .outgoing? = sync.held { return true }; return false }()
        return Card {
            Line(sync.held?.text ?? "", outgoing
                 ? "Sync it to every Mac, or put this Mac back to what the others have."
                 : "Accept it here, or keep this Mac's tabs and send them back.") {
                HStack(spacing: 8) {
                    Pill(outgoing ? "Undo Here" : "Keep Mine") { Task { await sync.keepHeldBack() } }
                    Pill(outgoing ? "Sync It" : "Accept", filled: true) { Task { await sync.letHeldThrough() } }
                }
            }
        }
        .padding(.top, 10)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Devices").padding(.top, 10)
            Card {
                ForEach(Array(sync.peers.enumerated()), id: \.element.id) { index, peer in
                    if index > 0 { Rule() }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Line(peer.name, "\(peer.tabs.count) open tab\(peer.tabs.count == 1 ? "" : "s") · last synced \(ago(peer.seen, now: context.date))") {
                            Menu("Tabs") {
                                ForEach(Array(peer.tabs.prefix(30).enumerated()), id: \.offset) { _, tab in
                                    Button(tab.title.isEmpty ? tab.url : tab.title) { sync.open(tab) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(peer.tabs.isEmpty)
                        }
                    }
                }
            }
        }
    }
}
