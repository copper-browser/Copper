import SwiftUI

// How live folders look in the column: at the foot of Saved, each a header
// like a folder's (its own glyph, the unread count while shut, a refresh
// button under the pointer) and its pull requests stepped in under it, a
// copper dot on the ones that changed since you opened them. A note row says
// why a folder is empty and opens the fix.

struct LiveFolderBlock: View {
    let browser: Browser
    let tint: SpaceTint
    @ObservedObject private var live = LiveFolders.shared

    var body: some View {
        let folders = live.folders(in: Spaces.shared.current(in: browser))
        if !folders.isEmpty {
            VStack(spacing: GroupedRows.gap) {
                ForEach(folders) { folder in
                    LiveFolderView(browser: browser, folder: folder, tint: tint)
                }
            }
        }
    }
}

struct LiveFolderView: View {
    let browser: Browser
    let folder: LiveFolder
    let tint: SpaceTint
    @ObservedObject private var live = LiveFolders.shared
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""

    private var colour: Color {
        guard let hue = tint.hue else { return Palette.muted }
        return Color(hue: hue, saturation: tint.dark ? 0.52 : 0.82, brightness: tint.dark ? 0.82 : 0.66)
    }

    var body: some View {
        VStack(spacing: GroupedRows.gap) {
            header
            if !folder.collapsed {
                if let problem = folder.problem {
                    note(problem, symbol: "exclamationmark.triangle.fill", ink: Palette.danger) {
                        if !live.hasToken || problem == GitHubPulls.Failure.token.text { GitHubTokenSheet.show(browser: browser) }
                        else { Task { await live.refreshAll(manual: true) } }
                    }
                } else if folder.refreshed != nil && folder.items.isEmpty {
                    note("No open pull requests", symbol: "checkmark.circle", ink: tint.muted) {}
                } else if folder.refreshed == nil {
                    note("Loading…", symbol: "arrow.triangle.2.circlepath", ink: tint.muted) {}
                }
                ForEach(folder.items) { item in
                    LiveItemRow(browser: browser, folder: folder.id, item: item, unread: folder.unread(item), tint: tint)
                        .padding(.leading, Folders.step)
                        // A folder's hair down from its glyph, as GroupedRows draws it.
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill(colour.opacity(0.2))
                                .frame(width: 1)
                                .padding(.vertical, 3)
                                .offset(x: SideBar.rowInset + 7.5)
                        }
                }
            }
        }
        .animation(Motion.settle, value: folder.collapsed)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ZStack {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colour)
                    .opacity(hovering ? 0 : 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.muted)
                    .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 16, height: 16)
            .padding(.trailing, 10)
            Text(folder.name)
                .font(.system(size: SideBar.title, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tint.ink)
            Spacer(minLength: 2)
            trailing
        }
        .padding(.leading, SideBar.rowInset)
        .frame(height: GroupedRows.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? tint.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { withAnimation(Motion.settle) { live.toggle(folder.id) } }
        .onHover { hovering = $0 }
        .contextMenu { LiveFolderMenu(browser: browser, folder: folder, rename: { draft = folder.name; renaming = true }) }
        .popover(isPresented: $renaming) {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .padding(8)
                .onSubmit { live.rename(folder.id, to: draft); renaming = false }
        }
        .help(folder.refreshed.map { "Updated \(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened))" } ?? "")
        .animation(Motion.quick, value: hovering)
    }

    @ViewBuilder
    private var trailing: some View {
        if live.refreshing {
            ProgressView().controlSize(.mini).padding(.trailing, 9)
        } else if hovering {
            Button { Task { await live.refreshAll(manual: true) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .padding(.trailing, 5)
        } else if folder.collapsed, folder.unreadCount > 0 {
            HStack(spacing: 5) {
                Text("\(folder.unreadCount)").font(.system(size: 11)).foregroundStyle(tint.muted)
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
            }
            .padding(.trailing, 10)
            .accessibilityLabel("\(folder.unreadCount) new")
        }
    }

    private func note(_ text: String, symbol: String, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(ink)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 10)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(tint.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, SideBar.rowInset)
            .frame(minHeight: GroupedRows.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Folders.step)
    }
}

/// One pull request: its title, the eye when your review is asked for, a
/// dot while it is new to you.
struct LiveItemRow: View {
    let browser: Browser
    let folder: UUID
    let item: LiveItem
    let unread: Bool
    let tint: SpaceTint
    @State private var hovering = false

    private var shown: Bool {
        guard let tab = browser.active, let address = tab.pending ?? tab.address else { return false }
        return GitHubPulls.shows(address.absoluteString, item.url)
    }

    var body: some View {
        let shown = self.shown
        HStack(spacing: 0) {
            Image(systemName: item.review ? "eye" : "arrow.triangle.pull")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.muted)
                .frame(width: 16, height: 16)
                .padding(.trailing, 10)
            Text(item.title)
                .font(.system(size: SideBar.title))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.draft ? tint.muted : tint.ink)
            Spacer(minLength: 4)
            if unread {
                Circle().fill(Palette.accent).frame(width: 6, height: 6).padding(.trailing, 10)
                    .accessibilityLabel("New")
            }
        }
        .padding(.leading, SideBar.rowInset)
        .frame(height: GroupedRows.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(shown ? tint.pill : hovering ? tint.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { LiveFolders.shared.open(item, in: folder, browser: browser) }
        .onHover { hovering = $0 }
        .help("\(item.repo) #\(item.number)\(item.author.isEmpty ? "" : " · \(item.author)")\(item.draft ? " · draft" : "")\(item.review ? " · your review is requested" : "")")
        .contextMenu {
            Button("Open") { LiveFolders.shared.open(item, in: folder, browser: browser) }
            Button("Open in Background") { LiveFolders.shared.open(item, in: folder, browser: browser, background: true) }
            Button("Copy Link") { SettingsActions.copy(item.url) }
            if unread { Button("Mark as Read") { LiveFolders.shared.markRead(item, in: folder) } }
        }
        .animation(Motion.quick, value: hovering)
    }
}

struct LiveFolderMenu: View {
    let browser: Browser
    let folder: LiveFolder
    let rename: () -> Void
    @ObservedObject private var live = LiveFolders.shared

    var body: some View {
        Button("Refresh") { Task { await live.refreshAll(manual: true) } }
        if folder.unreadCount > 0 { Button("Mark All as Read") { live.markAllRead(folder.id) } }
        Menu("Show") {
            ForEach(LiveFolder.Show.allCases, id: \.self) { show in
                Button { live.set(folder.id, show: show) } label: {
                    if folder.show == show { Label(show.title, systemImage: "checkmark") } else { Text(show.title) }
                }
            }
        }
        Button("Rename…", action: rename)
        Button(folder.collapsed ? "Expand" : "Collapse") { live.toggle(folder.id) }
        Divider()
        Button(live.hasToken ? "GitHub Token…" : "Add GitHub Token…") { GitHubTokenSheet.show(browser: browser) }
        Button("Remove Live Folder", role: .destructive) { live.remove(folder.id) }
    }
}

/// Connect GitHub: paste a token, or take GitHub CLI's sign-in.
struct GitHubTokenSheet: View {
    let browser: Browser?
    @ObservedObject private var live = LiveFolders.shared
    @State private var token = ""
    @State private var busy = false
    @State private var problem: String?

    @MainActor static func show(browser: Browser?) {
        FolderPanel.show("GitHub", GitHubTokenSheet(browser: browser))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect GitHub").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("The folder lists your open pull requests and the ones waiting for your review, and checks every few minutes. It needs a GitHub token, kept in your keychain and sent only to GitHub.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let login = live.login, live.hasToken {
                Text("Connected as \(login).").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
            }
            SecureField("ghp_… or github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit { connect() }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Pill("Make a Token…") {
                    if let browser { _ = browser.open(GitHubPulls.tokenPage, foreground: true) } else { SettingsActions.open(GitHubPulls.tokenPage) }
                }
                if GitHubPulls.cliInstalled { Pill("Use GitHub CLI") { useCLI() }.disabled(busy) }
                Spacer()
                if live.hasToken { Pill("Disconnect", tint: Palette.danger) { live.disconnect() } }
                Pill("Cancel") { FolderPanel.close() }
                Pill(busy ? "Checking…" : "Connect", filled: !token.isEmpty) { connect() }.disabled(busy || token.isEmpty)
            }
        }
    }

    private func connect() {
        guard !token.isEmpty, !busy else { return }
        run(token)
    }

    private func useCLI() {
        busy = true
        problem = nil
        Task {
            let found = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: GitHubPulls.cliToken()) }
            }
            guard let found else {
                busy = false
                problem = "GitHub CLI isn't signed in. Run gh auth login in Terminal, or paste a token."
                return
            }
            run(found)
        }
    }

    private func run(_ given: String) {
        busy = true
        problem = nil
        Task {
            do {
                try await live.connect(given)
                FolderPanel.close()
            } catch {
                problem = (error as? GitHubPulls.Failure)?.text ?? error.localizedDescription
            }
            busy = false
        }
    }
}
