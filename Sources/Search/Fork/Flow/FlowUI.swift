import AppKit
import SwiftUI

/// The Flow sheet is deliberately a sheet: importing is a single decision,
/// not another permanent browser pane.
///
/// It is the whole sheet, edge to edge — no card of its own inside the
/// system's — and its size is the presenter's (`FlowPresenter`), never its
/// content's: a header, a middle that scrolls when the window is short, and
/// a footer pinned to the bottom. A change of phase redraws the middle in
/// place; nothing moves, nothing animates from one layout to the next.
struct FlowSheet: View {
    @ObservedObject var browser: Browser
    @ObservedObject var flow = Flow.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .measured()
            ScrollView(.vertical) {
                middle
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 12)
                    .measured()
            }
            .scrollIndicators(.automatic)
            footer
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 22)
                .measured()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Fork (move-in-polish): the sheet takes its step's height.
        .onPreferenceChange(FlowSheetHeight.self) { height in
            MainActor.assumeIsolated { FlowPresenter.shared.want(height) }
        }
        .background(Palette.ground)
        // A sheet that comes up while something else animates (Settings
        // closing) must not animate its own first layout, and a new phase
        // replaces the old one outright: nothing morphs.
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Move in")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { flow.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(Palette.wash, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }
            // Fork (ui-flows): the browsers this Mac has (`MoveFrom`), and
            // only before the move: the done step is its result alone.
            if flow.phase.name != "done" {
                Text("Bring your tabs, bookmarks, history, passwords and sign-ins over from \(MoveFrom.names). Nothing in the other browser changes.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var middle: some View {
        switch flow.phase {
        case .moving(let steps): moving(steps)
        case .done(let report): done(report)
        default:
            if let source = flow.exporting { export(source) } else { picker }
        }
    }

    @ViewBuilder
    private var picker: some View {
        if !flow.sourcesKnown {
            // The look for browsers lands in a moment; say nothing until it
            // does rather than "none found".
            Color.clear.frame(height: 1)
        } else if flow.sources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("No other browser found on this Mac")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                Button("Passwords from a CSV…") { browser.importPasswords() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                sourceCards
                if let source = flow.selected, source.isSafari {
                    safariChecklist(source)
                } else if flow.selected == nil, flow.sources.allSatisfy(\.isSafari) {
                    // Only Safari, still locked: its own four rows, dimmed —
                    // never sign-ins or extensions it can't bring.
                    safariRows
                } else {
                    checklist
                }
                // Under the switches it is about, in the part that scrolls,
                // so a short window keeps its room for the list. Safari's
                // passwords come from its export: macOS asks nothing.
                if flow.choice.passwords || flow.choice.passkeys || flow.choice.cookies,
                   let source = flow.selected, !source.isSafari {
                    Text("macOS will ask once to let Copper use \(source.name)'s saved passwords and sign-ins. Say Allow; the window keeps working while it asks.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Safari's export (a .zip, or the folder it unzips to) can be
            // dropped anywhere on the list; one file goes on the export pane,
            // where whose file it is is clear.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard !flow.fileBusy, !flow.moving, flow.source(named: FlowSafari.name) != nil,
                      let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var folder: ObjCBool = false
                    let isExport = url.pathExtension.lowercased() == "zip"
                        || (FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue)
                    guard isExport else { return }
                    DispatchQueue.main.async { flow.takeSafariExport(url) }
                }
                return true
            }
        }
    }

    @ViewBuilder
    private var sourceCards: some View {
        if flow.sources.count == 1, let only = flow.sources.first {
            card(only)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top),
                                GridItem(.flexible(), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(flow.sources) { card($0) }
            }
        }
    }

    @ViewBuilder
    private func card(_ source: FlowSource) -> some View {
        if source.showsLocked {
            lockedCard(source)
        } else if !source.readable {
            emptyCard(source)
        } else {
            Button { flow.scan(source) } label: {
                sourceCard(source)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(source.name), \(profileLine(source))")
            .accessibilityAddTraits(flow.selected?.id == source.id ? .isSelected : [])
        }
    }

    private func profileLine(_ source: FlowSource) -> String {
        guard source.isSafari else { return "\(source.profileCount) profile\(source.profileCount == 1 ? "" : "s")" }
        // Safari: what Copper reads — its own files, its export, or both.
        let date = flow.safariExportDate.map { " from " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        switch (source.safariDirect != nil, source.export != nil) {
        case (true, true): return "Its files and the export\(date)"
        case (false, true): return "The export\(date)"
        default: return "Open tabs, bookmarks and history"
        }
    }

    private func cardHead(_ source: FlowSource, _ line: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // Fork (ui-flows): the browser's own app icon, as on the start card.
            if let icon = MoveFrom.icon(source.name) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: source.glyph)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text(line)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceCard(_ source: FlowSource) -> some View {
        cardHead(source, profileLine(source))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(flow.selected?.id == source.id ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(flow.selected?.id == source.id ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// macOS keeps the folder private. One sentence, one way to let Copper
    /// in, one way around it; Copper looks again as soon as it is back in
    /// front, so there is nothing to reopen.
    private func lockedCard(_ source: FlowSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHead(source, lockedLine(source))
            // Side by side when the card is wide; one above the other in
            // half a sheet, never a pill broken over two lines.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { lockedButtons(source) }
                VStack(alignment: .leading, spacing: 8) { lockedButtons(source) }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// One sentence. Safari's files open with Full Disk Access, which a
    /// running Copper may only see after it is reopened: once the person has
    /// been to System Settings and it is still locked, the card says so.
    private func lockedLine(_ source: FlowSource) -> String {
        guard source.isSafari else { return "macOS needs your OK before Copper can read \(source.name)." }
        if flow.askedAccess.contains(source.id) {
            return "Still locked. If you just turned on Full Disk Access for Copper, quit and reopen Copper."
        }
        return "macOS needs your OK before Copper can read Safari."
    }

    @ViewBuilder
    private func lockedButtons(_ source: FlowSource) -> some View {
        Button(source.isSafari ? "Allow Full Disk Access…" : "Allow in System Settings…") { flow.allow(source) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Palette.accent, in: Capsule()) // Fork (ui-system)
            .accessibilityHint(source.isSafari ? "Opens Privacy & Security, Full Disk Access" : "Opens Privacy & Security, Files & Folders")
        Button("Use an export instead…") { flow.showExport(for: source) }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Palette.ink)
    }

    /// Installed, but it has never been opened: nothing to read yet.
    private func emptyCard(_ source: FlowSource) -> some View {
        cardHead(source, "Open \(source.name) once, then come back.")
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .opacity(0.6)
            .accessibilityElement(children: .combine)
    }

    // MARK: - the export pane

    @State private var dropping = false

    private func export(_ source: FlowSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(source.isSafari ? "Bring in Safari's export" : "Bring in a file \(source.name) exported")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
                Text(source.isSafari
                     ? "Safari's export brings bookmarks, the Reading List, history and passwords — not open tabs."
                     : "A file brings only bookmarks or passwords — no open tabs, history or sign-ins.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                if flow.fileBusy {
                    ProgressView().controlSize(.small)
                    Text(source.isSafari ? "Reading the export…" : "Reading the file…")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                } else {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Palette.muted)
                    Text(source.isSafari ? "Drop the .zip here" : "Drop the file here")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(dropping ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropping ? Palette.ink.opacity(0.5) : Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard !flow.fileBusy, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { flow.takeFile(url, from: source.name, into: browser) }
                }
                return true
            }
            .accessibilityLabel(source.isSafari ? "Drop Safari's export here" : "Drop a bookmarks or passwords file here")
            VStack(alignment: .leading, spacing: 8) {
                if source.isSafari {
                    howTo("The export", "in Safari, File › Export Browsing Data to File…, then drop the .zip it saves")
                    howTo("Or one file", "a bookmarks .html or a passwords .csv works too")
                } else if source.name == "Chrome" {
                    howTo("Bookmarks", "in Chrome, ⋮ › Bookmarks and lists › Bookmark manager, then ⋮ › Export bookmarks")
                    howTo("Passwords", "in Chrome, ⋮ › Passwords and autofill › Password Manager › Settings › Export passwords")
                } else {
                    howTo("Bookmarks", "export them from \(source.name)'s bookmark manager")
                    howTo("Passwords", "export them from \(source.name)'s password settings")
                }
            }
            if let result = flow.fileResult {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: result.ok ? "checkmark" : "minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(result.ok ? Palette.ink : Palette.muted)
                        .frame(width: 12)
                    Text(result.text)
                        .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func howTo(_ what: String, _ path: String) -> some View {
        (Text(what).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.ink)
            + Text(" — " + path).font(.system(size: 12)).foregroundColor(Palette.muted))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(flow.selected?.isArc == true ? "Tabs and spaces" : "Tabs and windows", hint: tabHint, binding: binding(\.tabs), enabled: has { $0.tabCount })
            Rule()
            row("Bookmarks", hint: count { $0.bookmarkCount == 0 ? "none found" : FlowSummary.plural($0.bookmarkCount, "bookmark") }, binding: binding(\.bookmarks), enabled: has { $0.bookmarkCount })
            Rule()
            row("History", hint: count { $0.placeCount == 0 ? "none found" : FlowSummary.plural($0.placeCount, "place") }, binding: binding(\.history), enabled: has { $0.placeCount })
            Rule()
            row("Passwords", hint: count { $0.loginCount == 0 ? "none saved" : FlowSummary.plural($0.loginCount, "password") }, binding: binding(\.passwords), enabled: has { $0.loginCount })
            Rule()
            row("Passkeys", hint: count { $0.passkeyCount == 0 ? "none found" : FlowSummary.plural($0.passkeyCount, "passkey") }, binding: binding(\.passkeys), enabled: has { $0.passkeyCount })
            Rule()
            row("Sign-ins", hint: "stay signed in to your sites", binding: binding(\.cookies)) // Fork (ui-flows)
            Rule()
            row("Site data", hint: "what sites kept on this Mac, like settings and drafts", binding: binding(\.localStorage))
            Rule()
            row("Extensions", hint: count { $0.extensions.isEmpty ? "none found" : FlowSummary.plural($0.extensions.count, "extension") }, binding: binding(\.extensions), enabled: has { $0.extensions.count })
        }
        .padding(.horizontal, 13)
        .background(Palette.wash.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .disabled(flow.selected == nil)
        .opacity(flow.selected == nil ? 0.5 : 1)
    }

    private var safariRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Tabs and tab groups", hint: "", binding: binding(\.tabs))
            Rule()
            row("Bookmarks and Reading List", hint: "", binding: binding(\.bookmarks))
            Rule()
            row("History", hint: "", binding: binding(\.history))
            Rule()
            row("Passwords", hint: "", binding: binding(\.passwords))
        }
        .padding(.horizontal, 13)
        .background(Palette.wash.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .disabled(true)
        .opacity(0.5)
    }

    /// One category. A row the source can't bring is drawn off and still,
    /// with what to do about it beside the hint (`link`).
    private func row(_ title: String, hint: String, binding: Binding<Bool>, enabled: Bool = true,
                     link: (title: String, action: () -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(enabled ? Palette.ink : Palette.muted)
                if !hint.isEmpty || link != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if !hint.isEmpty {
                            Text(hint).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let link {
                            Button(link.title, action: link.action)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            Spacer()
            // The shared switch says its own name, value and action.
            Switch(on: enabled ? binding : .constant(false), label: title)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
        .padding(.vertical, 9)
    }

    /// Safari's rows: only what Safari has. Open tabs need its own files;
    /// passwords need its export. Each row that can't come says why and
    /// offers the one way to change that.
    private func safariChecklist(_ source: FlowSource) -> some View {
        let direct = source.safariDirect != nil
        let look: FlowSafari.Look? = { if case .preview(let haul) = flow.phase { return haul.safari } else { return nil } }()
        let hasPasswords = look?.hasPasswords ?? false
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                row("Tabs and tab groups", hint: direct ? count { _ in Self.safariTabs(look) } : "not in Safari's export",
                    binding: binding(\.tabs), enabled: direct,
                    link: direct ? nil : ("Allow Full Disk Access…", { flow.allow(source) }))
                Rule()
                row("Bookmarks and Reading List", hint: count { _ in Self.safariBookmarks(look) }, binding: binding(\.bookmarks))
                Rule()
                row("History", hint: count { $0.placeCount == 0 ? "none found" : FlowSummary.plural($0.placeCount, "place") }, binding: binding(\.history))
                Rule()
                row("Passwords",
                    hint: source.export == nil ? "only in Safari's export" : count { _ in hasPasswords ? FlowSummary.plural(look?.passwords ?? 0, "password") : "none in this export" },
                    binding: binding(\.passwords), enabled: hasPasswords,
                    link: source.export == nil ? ("Add the export…", { flow.showExport(for: source) }) : nil)
            }
            .padding(.horizontal, 13)
            .background(Palette.wash.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            if let look, let line = FlowSafari.staysLine(look) {
                Text(line)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func safariTabs(_ look: FlowSafari.Look?) -> String {
        guard let look else { return "" }
        guard look.tabs > 0 else { return "none open" }
        var text = "\(FlowSummary.plural(look.tabs, "tab")) in \(FlowSummary.plural(look.spaces, "space"))"
        if look.pins > 0 { text += " · \(look.pins.formatted()) pinned" }
        return text
    }

    private static func safariBookmarks(_ look: FlowSafari.Look?) -> String {
        guard let look else { return "" }
        guard look.hasBookmarks else { return look.direct ? "none found" : "not in this export" }
        guard look.bookmarks + look.readingList > 0 else { return "none found" }
        var parts: [String] = []
        if look.bookmarks > 0 { parts.append(FlowSummary.plural(look.bookmarks, "bookmark")) }
        if look.readingList > 0 { parts.append("\(look.readingList.formatted()) in Reading List") }
        return parts.joined(separator: " · ")
    }

    /// Hints are counts; before there are any, "counting…" or nothing.
    private var countingHint: String {
        flow.phase == .scanning ? "counting…" : ""
    }

    private var tabHint: String {
        guard case .preview(let haul) = flow.phase else { return countingHint }
        let open = haul.spaces.filter { !$0.tabs.isEmpty }.count
        let unit = flow.selected?.isArc == true ? "space" : "window"
        return haul.tabCount == 0 ? "none open" : "\(FlowSummary.plural(haul.tabCount, "tab")) in \(FlowSummary.plural(open, unit))"
    }

    /// A row's hint: a count once the source is read, "counting…" while it
    /// is, nothing before.
    private func count(_ text: (FlowModel.Haul) -> String) -> String {
        guard case .preview(let haul) = flow.phase else { return countingHint }
        return text(haul)
    }

    /// Fork (move-in-polish): a kind the browser has none of is off and
    /// still; before the counts are in, every switch is the person's.
    private func has(_ n: (FlowModel.Haul) -> Int) -> Bool {
        guard let haul = flow.counted else { return true }
        return n(haul) > 0
    }

    private func binding(_ keyPath: WritableKeyPath<FlowModel.Choice, Bool>) -> Binding<Bool> {
        Binding(get: { flow.choice[keyPath: keyPath] }, set: { flow.choice[keyPath: keyPath] = $0 })
    }

    /// A row per chosen category, made when the move starts and changed in
    /// place: nothing is added, so nothing grows or moves.
    private func moving(_ steps: [FlowStep]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.selected.map { "Bringing it over from \($0.name)…" } ?? "Bringing it over…")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps, id: \.category) { step in
                    stepRow(step.category, step.state, step.state == .waiting ? "waiting" : step.text)
                }
            }
        }
    }

    /// One category's row, the same while moving and in the summary: the
    /// move ends on exactly the rows the summary shows, so going from one to
    /// the other changes the marks and the title, and nothing moves.
    private func stepRow(_ category: FlowSummary.Category, _ state: FlowStep.State, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark(state)
                .frame(width: 12)
            Text(category.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state == .waiting ? Palette.faint : Palette.ink)
                .frame(width: 92, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(state == .arrived ? Palette.ink : state == .waiting ? Palette.faint : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func mark(_ state: FlowStep.State) -> some View {
        switch state {
        case .waiting:
            Circle().strokeBorder(Palette.faint, lineWidth: 1).frame(width: 8, height: 8)
        case .working:
            ProgressView().controlSize(.mini)
        case .arrived:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink)
        case .missed:
            Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
        }
    }

    private func done(_ report: Flow.Report) -> some View {
        VStack(alignment: .center, spacing: 14) {
            // Fork (move-in-polish): the result in the middle, a check over it,
            // and the one thing to do next under it.
            Image(systemName: report.summary.contains(where: \.ok) ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(report.summary.contains(where: \.ok) ? Palette.accent : Palette.muted) // Fork (ui-flows): the copper check
                .accessibilityHidden(true)
            Text(report.title)
                .font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.summary, id: \.category) { line in
                    stepRow(line.category, line.ok ? .arrived : .missed, line.detail)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let next = Self.next(report) {
                Text(next)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            ForEach(report.stayed, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.undone {
                Text("Took back the tabs and spaces this move added.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if flow.guide == .failed {
                Text("Couldn't open the Chrome guide.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            ForEach(report.notes.filter { $0.contains("still installing") }, id: \.self) { note in
                Text(note.prefix(1).uppercased() + note.dropFirst() + ".")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// The one next step after a move, by what came.
    static func next(_ report: Flow.Report) -> String? {
        let came = Set(report.summary.filter(\.ok).map(\.category))
        if came.contains(.tabs) { return "Your tabs came over as spaces. ⌃1–9 switches between them." }
        if came.contains(.bookmarks) { return "Your bookmarks are behind the bookmark button. ⌘K finds them too." }
        if came.contains(.history) { return "Start typing an address: Copper already knows where you go." }
        if came.contains(.passwords) { return "Sign in anywhere: Copper offers your saved passwords." }
        return nil
    }

    @ViewBuilder
    private var footer: some View {
        switch flow.phase {
        case .done(let report):
            HStack(spacing: 16) {
                if flow.canUndo {
                    secondary("Undo the tabs") { flow.undo() } // Fork (move-in-polish): a button, not loose words
                }
                if report.guideOffered, flow.guide != .opened {
                    Button(flow.guide == .opening ? "Opening the guide…" : "Open the Chrome guide") {
                        Task { await flow.openGuide() }
                    }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    .disabled(flow.guide == .opening)
                }
                Spacer()
                primary("Done") { flow.finish() }
            }
        case .moving:
            Text("You can close this; the move keeps going.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            if let source = flow.exporting {
                HStack(spacing: 14) {
                    Button("Back") { flow.exporting = nil; flow.fileResult = nil }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    Spacer()
                    primary(source.isSafari ? "Choose the export…" : "Choose a file…", disabled: flow.fileBusy) { flow.chooseFile(from: source.name, into: browser) }
                }
            } else {
                pickerFooter
            }
        }
    }

    private var pickerFooter: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                if let source = flow.selected, let date = flow.movedAt[source.name], !flow.moveAgain {
                    // A move is one-time: once a browser is in, say when, and
                    // make running it again a choice rather than the big button.
                    HStack {
                        Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Text("Moved in from \(source.name) on \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Spacer()
                        primary("Move in again") { flow.moveAgain = true }
                    }
                } else {
                    HStack {
                        // Two or more to choose from and none picked yet: the
                        // cards are the choice, so say so rather than leave a
                        // dimmed list and a button that does nothing.
                        if flow.selected == nil, flow.sources.contains(where: { $0.readable && !$0.showsLocked }) {
                            Text("Choose a browser above to see what comes over")
                                .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        primary(flow.selected?.isSafari == true ? "Bring it all over" : flow.effectiveChoice.button(for: flow.counted), disabled: !flow.canMove) {
                            guard let source = flow.selected else { return }
                            Task { await flow.move(source, into: browser) }
                        }
                    }
                }
            }
        }
    }

    /// Fork (move-in-polish): a bordered button beside the primary, the same size.
    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 17).padding(.vertical, 10)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
    }

    /// The one button Return presses, in every state.
    private func primary(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 17).padding(.vertical, 10)
            .background(Palette.accent.opacity(disabled ? 0.35 : 1), in: Capsule()) // Fork (ui-system)
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
    }
}

/// Fork (move-in-polish): the heights of the sheet's three parts, summed —
/// what the sheet would be with nothing scrolled.
struct FlowSheetHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    func measured() -> some View {
        background(GeometryReader { Color.clear.preference(key: FlowSheetHeight.self, value: $0.size.height) })
    }
}
