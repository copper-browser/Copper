import AppKit
import SwiftUI

// The Canvas door at the foot of the sidebar, beside Bookmarks and
// Extensions, and the card it opens: Personal, Invitations (invites waiting
// for your answer, with Join and Decline), the canvases you made, the ones
// shared with you, and New canvas. Each
// row opens its canvas in a tab; its context menu renames, invites, lists
// members, leaves or deletes. Sharing needs Copper Cloud — signed out, the
// card says so in one line and everything cloud-shaped stays out of sight.

@MainActor
final class CanvasUI: ObservableObject {
    static let shared = CanvasUI()

    enum Mode: Equatable {
        case list
        case new
        case rename(String)
        case invite(String)
        case share(String)
        case members(String)
        case delete(String)
    }

    @Published var popoverOpen = false {
        didSet {
            if popoverOpen, !oldValue { Canvases.shared.refreshSoon() }
            if !popoverOpen { mode = .list; note = nil; doorWindow = nil }
        }
    }

    /// The window whose door the card hangs from — one card, in one window.
    /// Every window's door used to be bound to `popoverOpen` itself, so with
    /// two windows open both presented the card; a press in one was a press
    /// outside the other, whose transient popover closed on it and took the
    /// flag — and the card under the pointer — down before the release
    /// reached the row. The card closed and nothing opened: no canvas could be
    /// opened from the door while a second window was open. Nil: the window
    /// in front (a card opened by ⌘K, a menu, the bench).
    @Published private(set) var doorWindow: ObjectIdentifier?

    /// Whether `browser`'s door is the one showing the card.
    func showsDoor(in browser: Browser) -> Bool {
        popoverOpen && (doorWindow ?? ObjectIdentifier(Windows.current)) == ObjectIdentifier(browser)
    }

    /// The card, from `browser`'s door (the one in front when nil); it leaves
    /// any other window's door.
    func openDoor(in browser: Browser?) {
        doorWindow = ObjectIdentifier(browser ?? Windows.current)
        popoverOpen = true
    }

    /// `browser`'s door pressed: its card closes if it is the one up, else
    /// opens there.
    func toggleDoor(in browser: Browser) {
        if showsDoor(in: browser) { popoverOpen = false } else { openDoor(in: browser) }
    }

    /// What `browser`'s door hands its popover: shown only there, and a
    /// dismissal there (Escape, a click outside it) closes only its own card.
    func door(in browser: Browser) -> Binding<Bool> {
        Binding(
            get: { self.showsDoor(in: browser) },
            set: { open in
                if open { self.openDoor(in: browser) } else if self.showsDoor(in: browser) { self.popoverOpen = false }
            }
        )
    }
    @Published var mode: Mode = .list {
        didSet {
            // The Share sheet's state lives as long as the sheet does.
            if case .share(let id) = mode {
                if share?.canvasId != id { share = CanvasShareModel(canvasId: id) }
            } else if share != nil {
                share = nil
            }
        }
    }
    /// A line under the list after something worked or didn't.
    @Published var note: String?
    /// The open Share sheet's state (CanvasShare.swift), made with the mode.
    private(set) var share: CanvasShareModel?

    /// Settings › Cloud — looked up by name, so this builds whether or not
    /// the Cloud page is in this build; without it, Settings opens as it was.
    static func openCloudSettings(in browser: Browser) {
        if let page = SettingsPanel.Page(rawValue: "cloud") { browser.openSettings(page) } else { browser.tuning = true }
    }

    /// The card drawn off screen at its own size, for `bench canvas ui picture`.
    ///
    /// Built fresh and drawn off screen, so whatever the card's own views
    /// fetch on appear (members, the people search) is a `.task` that has
    /// only just been scheduled when layout first settles — a bare
    /// `cacheDisplay` right after `layoutSubtreeIfNeeded` would always catch
    /// it before the network round trip lands and draw those rows empty.
    /// Async so the caller can let the run loop turn: re-measuring a fixed
    /// handful of times over ~900 ms gives a same-machine fetch room to
    /// finish and the view room to re-render with it before the final
    /// capture.
    static func picture(browser: Browser, dark: Bool) async -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: CanvasPopover(browser: browser)
            .padding(16)
            .background(Color(nsColor: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: picture)
        return picture
    }

    /// "New canvas…" from ⌘K or the menu: the card, at its name field — or,
    /// with no sidebar to hang it from, an untitled canvas straight away.
    func openShare(_ id: String, in browser: Browser? = nil) {
        guard Canvases.shared.entry(id) != nil else { return }
        openDoor(in: browser)
        mode = .share(id)
    }

    func newCanvas(in browser: Browser) {
        if browser.prefs.sidebar, !browser.folded {
            openDoor(in: browser)
            mode = .new
        } else {
            Task {
                if let entry = try? await Canvases.shared.create(named: "Untitled canvas") {
                    CanvasHost.show(entry.id, in: browser)
                }
            }
        }
    }
}

/// The door. A dot on it while any canvas has someone else in it.
struct CanvasDoor: View {
    @ObservedObject var browser: Browser
    let tint: SpaceTint
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var presence = CanvasPresence.shared
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var chat = CanvasChat.shared // Fork (canvas chat): mentions of you

    private var others: Int { presence.peers.values.reduce(0, +) }
    private var mentioned: Int { chat.mentions.count }
    /// Invites waiting for an answer: a dot in ink, until they are answered.
    private var waiting: Int { canvases.invites.count }

    private var help: String {
        var parts = ["Canvas"]
        if mentioned > 0 { parts.append("\(mentioned) mention\(mentioned == 1 ? "" : "s") of you") }
        if waiting > 0 { parts.append("\(waiting) invitation\(waiting == 1 ? "" : "s")") }
        if others > 0 { parts.append(CanvasRow.live(others)) }
        return parts.joined(separator: " · ") + "   ⌘⇧O"
    }

    var body: some View {
        Door(icon: "scribble.variable", help: help,
             size: 28, ink: tint.ink, glow: tint.hover, glyph: 14) {
            ui.toggleDoor(in: browser)
        }
        .overlay(alignment: .topTrailing) {
            if others > 0 || waiting > 0 || mentioned > 0 {
                // A mention of you is the accent dot; live people the green; an invite alone, the space's ink.
                Circle().fill(mentioned > 0 ? CanvasChatColors.mention : others > 0 ? Color.green : tint.ink).frame(width: 6, height: 6).offset(x: -4, y: 4)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(mentioned > 0 ? "Canvas, \(mentioned) mention\(mentioned == 1 ? "" : "s") of you" : waiting > 0 ? "Canvas, \(waiting) invitation\(waiting == 1 ? "" : "s")" : "Canvas")
        .popover(isPresented: ui.door(in: browser), arrowEdge: .top) {
            CanvasPopover(browser: browser)
        }
        .animation(Motion.quick, value: others)
        .animation(Motion.quick, value: waiting)
    }
}

/// The card.
struct CanvasPopover: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var presence = CanvasPresence.shared
    @ObservedObject private var cloud = Cloud.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            switch ui.mode {
            case .list, .new:
                list
            case .rename(let id):
                if let entry = canvases.entry(id) { CanvasNameForm(title: "Rename canvas", subject: entry.name, action: "Rename", start: entry.name) { name in
                    try await canvases.rename(id, to: name)
                    ui.note = "Renamed to “\(Canvases.clean(name))”"
                } }
            case .invite(let id):
                if let entry = canvases.entry(id) { CanvasInviteForm(entry: entry) }
            case .share(let id):
                if let entry = canvases.entry(id), let model = ui.share { CanvasShareSheet(entry: entry, model: model) }
            case .members(let id):
                if let entry = canvases.entry(id) { CanvasMembers(entry: entry) }
            case .delete(let id):
                if let entry = canvases.entry(id) { CanvasDeleteConfirm(entry: entry, browser: browser) }
            }
        }
        .frame(width: 320)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        // The bench's hand on a row (`canvas ui click`, DoorHand): where the
        // card sits in its popover's window, and the rows within it.
        .coordinateSpace(name: DoorHand.space)
        .background(DoorHand.Probe(browser: browser))
        .animation(Motion.settle, value: ui.mode)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if ui.mode != .list && ui.mode != .new {
                Button { ui.mode = .list } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .help("Back")
                .accessibilityLabel("Back to canvases")
            }
            Text("Canvas").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 6)
            if canvases.busy { ProgressView().controlSize(.mini) }
            Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var status: String {
        if let account = cloud.account, canvases.cloudReady { return account.displayName.isEmpty ? account.email : account.displayName }
        return "On this Mac"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    CanvasRow(entry: canvases.personal, browser: browser)
                    if !canvases.invites.isEmpty {
                        CanvasSection(title: "Invitations")
                        ForEach(canvases.invites) { invite in CanvasInviteRow(invite: invite, browser: browser) }
                    }
                    let mine = canvases.mine
                    if !mine.isEmpty {
                        CanvasSection(title: "My canvases")
                        ForEach(mine) { entry in CanvasRow(entry: entry, browser: browser) }
                    }
                    let shared = canvases.sharedWithMe
                    if !shared.isEmpty {
                        CanvasSection(title: "Shared with me")
                        ForEach(shared) { entry in CanvasRow(entry: entry, browser: browser) }
                    }
                    signedOut
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            if let note = ui.note ?? canvases.problem {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(canvases.problem != nil && ui.note == nil ? Color.orange : Palette.muted)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if ui.mode == .new {
                CanvasNameForm(title: nil, subject: nil, action: "Create", start: "") { name in
                    let entry = try await canvases.create(named: name)
                    ui.popoverOpen = false
                    CanvasHost.show(entry.id, in: browser)
                }
            } else {
                footer
            }
        }
    }

    /// Shared canvases of an account that isn't signed in: their copy here
    /// opens offline while nobody is signed in; with another account signed
    /// in they are only counted — one account never sees another's boards.
    @ViewBuilder private var signedOut: some View {
        let away = canvases.signedOut
        if !away.isEmpty {
            CanvasSection(title: "Signed out")
            if cloud.account == nil {
                CanvasExplain(text: "Kept on this Mac. They open offline and keep your changes; sign in at Settings › Cloud to see others' changes and send yours.")
                ForEach(away) { entry in CanvasRow(entry: entry, browser: browser) }
            } else {
                CanvasExplain(text: "\(away.count) shared canvas\(away.count == 1 ? " is" : "es are") kept on this Mac for another account. Sign in as that account to open \(away.count == 1 ? "it" : "them").")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { ui.mode = .new } label: {
                Label("New canvas", systemImage: "plus").font(.system(size: 12.5)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .help(canvases.cloudReady ? "A shared canvas on your cloud — invite people to it" : "A canvas on this Mac")
            if !canvases.cloudReady {
                Button {
                    ui.popoverOpen = false
                    CanvasUI.openCloudSettings(in: browser)
                } label: {
                    (Text("Share canvases and see each other live: ") + Text("Settings › Cloud").underline())
                        .font(.system(size: 11))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The card's own buttons, drawn the same in a key window, a window behind
/// and a picture: outlined, filled in ink (the one you came to press), or
/// filled red (it destroys something).
struct CanvasButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, destructive }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: kind == .plain ? .regular : .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(kind == .plain ? Palette.ink : kind == .primary ? Palette.onAccent : Color.white) // Fork (ui-system)
            .padding(.horizontal, 11)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(kind == .plain ? Palette.ground : kind == .primary ? Palette.accent : Color(nsColor: .systemRed)))
            .overlay(Capsule().strokeBorder(kind == .plain ? Palette.faint : .clear, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// One line under a section heading, wrapping, in the muted voice.
private struct CanvasExplain: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }
}

/// The canvas a form or a confirmation is about, whole: a long name wraps
/// instead of being cut off where the decision is made.
struct CanvasSubject: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
            .textSelection(.enabled)
            .accessibilityLabel("Canvas: \(name)")
    }
}

/// A form's short title — what is being done, never the name it is done to.
struct CanvasFormTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct CanvasSection: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold)) // Fork (uitype): 11 pt floor for labels
            .tracking(0.4)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One canvas: a click opens it (switching to its tab if it has one).
struct CanvasRow: View {
    let entry: Canvases.Entry
    @ObservedObject var browser: Browser
    @ObservedObject private var presence = CanvasPresence.shared
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var sync = CloudSync.shared
    @ObservedObject private var chat = CanvasChat.shared
    @State private var hovering = false

    private var peers: Int { presence.peers[entry.id] ?? 0 }
    private var mentioned: Int { chat.mentionCount(entry.id) }
    private var isOpen: Bool { CanvasHost.tab(showing: entry.id, in: browser) != nil }
    private var isFront: Bool { CanvasHost.active(in: browser) == entry.id }
    /// Shared, but its account isn't the one signed in: an offline copy.
    private var away: Bool { entry.isShared && entry.account != Canvases.account }

    /// "1 collaborator live", "3 collaborators live" — people, not tabs.
    static func live(_ count: Int) -> String { "\(count) collaborator\(count == 1 ? "" : "s") live" }

    private var glyph: String {
        if entry.isPersonal { return "person.crop.square" }
        if entry.isShared { return "person.2" }
        return "scribble.variable"
    }

    /// "Synced" only once the room has answered; before that it is
    /// connecting, and with Personal's sync off it is simply on this Mac.
    private var detail: String {
        if entry.isPersonal {
            guard canvases.cloudReady, sync.syncs(.canvas) else { return "Private · on this Mac" }
            if presence.synced.contains(entry.id) { return "Private · synced" }
            if presence.open.contains(entry.id) { return "Private · connecting…" }
            // Its room comes up with its page: nothing is moving right now.
            return "Private · sync on"
        }
        if entry.isShared {
            if away { return "Offline · changes saved on this Mac" }
            if presence.open.contains(entry.id), !presence.synced.contains(entry.id) {
                return canvases.cloudReady ? "Shared · connecting…" : "Offline · changes saved on this Mac"
            }
            if !entry.isOwner, let owner = entry.owner, !owner.isEmpty { return "From \(owner)" }
            let members = entry.members ?? 1
            return members > 1 ? "Shared · \(members) members" : "Shared · just you so far"
        }
        return "On this Mac"
    }

    var body: some View {
        Button {
            ui.popoverOpen = false
            CanvasHost.show(entry.id, in: browser)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isFront ? Palette.ground : Palette.wash))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: isFront ? .semibold : .regular))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if mentioned > 0 {
                    // Fork (canvas chat): unread mentions of you in its chat.
                    Text(mentioned > 1 ? "@\(mentioned)" : "@")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(CanvasChatColors.mention, in: Capsule())
                        .help("\(mentioned) mention\(mentioned == 1 ? "" : "s") of you in its chat")
                }
                if peers > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(peers)").font(.system(size: 11).monospacedDigit())
                    }
                    .foregroundStyle(Palette.muted)
                    .help(CanvasRow.live(peers))
                }
                if isOpen {
                    // The tab's state, as a mark: the one in front, or one open behind.
                    Image(systemName: isFront ? "checkmark" : "macwindow")
                        .font(.system(size: 10.5, weight: isFront ? .semibold : .regular))
                        .foregroundStyle(isFront ? Palette.ink : Palette.muted)
                        .frame(width: 16)
                        .help(isFront ? "The tab in front" : "Open in a tab — click to switch to it")
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFront ? Palette.wash : hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DoorHand.space)) } action: { DoorHand.rows[entry.id] = $0 }
        .onHover { hovering = $0 }
        .help(entry.name)
        .accessibilityLabel(accessibility)
        .contextMenu { menu }
    }

    private var accessibility: String {
        var parts = [entry.name, detail]
        if peers > 0 { parts.append(CanvasRow.live(peers)) }
        if isFront { parts.append("the tab in front") } else if isOpen { parts.append("open in a tab") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { ui.popoverOpen = false; CanvasHost.show(entry.id, in: browser) }
        Button("Open in Background") { CanvasHost.show(entry.id, in: browser, foreground: false) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CanvasLinks.url(entry.id).absoluteString, forType: .string)
        }
        if !entry.isPersonal && !away {
            Divider()
            if entry.isOwner { Button("Rename…") { ui.mode = .rename(entry.id) }.disabled(entry.isShared && !canvases.cloudReady) }
            Button("Share…") { ui.mode = .share(entry.id) }
            if entry.isShared && canvases.cloudReady {
                Button("Members…") { ui.mode = .members(entry.id) }
            }
            Divider()
            if entry.isShared && !entry.isOwner {
                Button("Leave…") { ui.mode = .delete(entry.id) }.disabled(!canvases.cloudReady)
            } else {
                Button("Delete…") { ui.mode = .delete(entry.id) }.disabled(entry.isShared && !canvases.cloudReady)
            }
        }
    }
}

/// An invite waiting for your answer: Join (accepts and opens the canvas)
/// or Decline. It stays listed until it is answered — "Not now" on the
/// pill only puts the pill away.
private struct CanvasInviteRow: View {
    let invite: Canvases.Invite
    @ObservedObject var browser: Browser
    @ObservedObject private var ui = CanvasUI.shared
    /// Which answer is on its way, if one is.
    @State private var working: Bool?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
                VStack(alignment: .leading, spacing: 1) {
                    Text(invite.canvasName)
                        .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text((invite.from.isEmpty ? "Invited you" : "From \(invite.from)") + (invite.nudgedAt != nil ? " · reminded you" : ""))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 11)).foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let working {
                    ProgressView().controlSize(.mini)
                    Text(working ? "Joining…" : "Declining…").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Button("Decline") { answer(false) }
                    .buttonStyle(CanvasButtonStyle(kind: .plain))
                    .disabled(working != nil)
                Button("Join") { answer(true) }
                    .buttonStyle(CanvasButtonStyle(kind: .primary))
                    .disabled(working != nil)
                    .help("Join “\(invite.canvasName)” and open it")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invitation to \(invite.canvasName)\(invite.from.isEmpty ? "" : " from \(invite.from)")")
    }

    /// The row stays until the server has said yes: a failure is said here,
    /// in the row, and both buttons come back.
    private func answer(_ accept: Bool) {
        working = accept
        failure = nil
        Task {
            do {
                // An invite that had gone (404) has left the list by now:
                // a quiet line, never an error in a row that is no more.
                let outcome = try await Canvases.shared.answer(invite, accept: accept)
                ui.note = outcome == .closed ? Canvases.closedInvite
                    : accept ? "Joined “\(invite.canvasName)”" : "Declined “\(invite.canvasName)”"
                if accept, outcome != .closed, let entry = Canvases.shared.entry(invite.canvasId) {
                    ui.popoverOpen = false
                    CanvasHost.show(entry.id, in: browser, foreground: true)
                }
            } catch {
                failure = Canvases.explain(error)
            }
            working = nil
        }
    }
}

/// A name, asked for in place: New canvas and Rename.
private struct CanvasNameForm: View {
    let title: String?
    /// The canvas being renamed, whole, under the title.
    var subject: String? = nil
    let action: String
    let start: String
    let done: (String) async throws -> Void
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var canvases = Canvases.shared
    @State private var name = ""
    @State private var working = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { CanvasFormTitle(text: title) }
            if let subject { CanvasSubject(name: subject) }
            TextField("Canvas name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .disabled(working)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2) }
            if title == nil {
                Text(canvases.cloudReady ? "Shared on your cloud — invite people once it's made." : "On this Mac. Sign in at Settings › Cloud to share.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { ui.mode = .list }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            name = start
            DispatchQueue.main.async { focused = true }
        }
    }

    private func submit() {
        guard !working, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        working = true
        failure = nil
        Task {
            do {
                try await done(name)
                if ui.mode != .list { ui.mode = .list }
            } catch {
                failure = Canvases.explain(error)
            }
            working = false
        }
    }
}

private struct CanvasInviteForm: View {
    let entry: Canvases.Entry
    @ObservedObject private var ui = CanvasUI.shared
    @State private var email = ""
    @State private var working = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CanvasFormTitle(text: "Invite to canvas")
            CanvasSubject(name: entry.name)
            TextField("name@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .focused($focused)
                .onSubmit(submit)
                .disabled(working)
            Text("They'll see it under Invitations once they sign in to the same cloud.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2) }
            HStack {
                Spacer()
                Button("Cancel") { ui.mode = .list }
                    .keyboardShortcut(.cancelAction)
                Button("Send Invite", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !email.contains("@"))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        guard !working, email.contains("@") else { return }
        working = true
        failure = nil
        Task {
            do {
                let address = email.trimmingCharacters(in: .whitespaces)
                let outcome = try await Canvases.shared.invite(entry.id, email: address)
                ui.note = Canvases.inviteLine(outcome, email: address, canvas: entry.name)
                ui.mode = .list
            } catch {
                failure = Canvases.explain(error)
            }
            working = false
        }
    }
}

private struct CanvasMembers: View {
    let entry: Canvases.Entry
    @State private var members: [Canvases.Member] = []
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CanvasFormTitle(text: "Members")
                CanvasSubject(name: entry.name)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            if loading {
                ProgressView().controlSize(.small).padding(14)
            } else if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).padding(14)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(members) { member in
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: CanvasColors.stable(member.id)))
                                    .frame(width: 22, height: 22)
                                    .overlay(Text(String(member.name.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.name.isEmpty ? member.email : member.name).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                                    if !member.email.isEmpty, member.email != member.name {
                                        Text(member.email).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(member.role.capitalized).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
        .task {
            do { members = try await Canvases.shared.members(entry.id) } catch { failure = Canvases.explain(error) }
            loading = false
        }
    }
}

private struct CanvasDeleteConfirm: View {
    let entry: Canvases.Entry
    @ObservedObject var browser: Browser
    @ObservedObject private var ui = CanvasUI.shared
    @State private var working = false
    @State private var failure: String?
    @FocusState private var cancelFocused: Bool

    private var leaving: Bool { entry.isShared && !entry.isOwner }

    /// What goes, said plainly: there is no undo and no bin to restore from.
    private var consequence: String {
        if leaving { return "It stays for everyone else. Someone will have to invite you again." }
        if entry.isShared { return "Permanently deletes this canvas and everything on it, for every member. This can't be undone." }
        return "Permanently deletes this canvas and everything on it from this Mac. This can't be undone."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CanvasFormTitle(text: leaving ? "Leave canvas" : "Delete canvas")
            CanvasSubject(name: entry.name)
            Text(consequence)
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2) }
            HStack(spacing: 8) {
                Spacer()
                if working { ProgressView().controlSize(.mini) }
                // Cancel is where the keyboard starts and what Escape does;
                // Return confirms nothing here.
                Button("Cancel") { ui.mode = .list }
                    .buttonStyle(CanvasButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button(role: .destructive) { run() } label: {
                    Text(leaving ? "Leave canvas" : "Delete canvas")
                }
                .buttonStyle(CanvasButtonStyle(kind: .destructive))
                .disabled(working)
                .accessibilityHint(consequence)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { DispatchQueue.main.async { cancelFocused = true } }
    }

    private func run() {
        working = true
        Task {
            do {
                if leaving { try await Canvases.shared.leave(entry.id) } else { try await Canvases.shared.delete(entry.id) }
                ui.note = leaving ? "Left “\(entry.name)”" : "Deleted “\(entry.name)”"
                ui.mode = .list
            } catch {
                failure = Canvases.explain(error)
            }
            working = false
        }
    }
}

private extension Color {
    /// `#rrggbb`.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
