import AppKit
import SwiftUI

// The pane beside the page: one conversation with whoever has hands on it.
//
// Your questions on the right in soft bubbles; the agent's answers full
// width, as text rather than chat balloons; between them one quiet row for
// what it did to get there (AgentActivity). When something else drives the
// page — a Jev run, phi or Claude Code on the loopback server, a linked bot —
// it arrives here too, as a live card where it happened in the conversation
// (DriveCard), with its steps and a Stop. There used to be a second pane for
// that, the driver timeline, and with both open every call showed twice.
//
// Drawn in the sidebar's palette so it reads as part of the window, not a
// chat app pasted in. No JSON reaches it.

struct AgentPane: View {
    @ObservedObject var browser: Browser
    /// A width that isn't the dragged one: the bench's pictures at 340–620 pt.
    var fixedWidth: CGFloat? = nil
    @ObservedObject var agent = Agent.shared
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject private var account = ClaudeAccount.shared
    @ObservedObject var servers = Servers.shared
    @ObservedObject private var drive = Drive.shared
    @ObservedObject private var split = Split.shared
    // Fork (voice): Listen's card and the composer's transcript chip.
    @ObservedObject private var listen = Listen.shared
    @ObservedObject private var heard = Transcript.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @FocusState private var focused: Bool
    @State private var copiedJev = false
    /// Whether this pane holds one of LineBreak's watches.
    @State private var breaking = false
    /// Whether the transcript is scrolled to its end. New content follows
    /// only then; scrolled up to read, the reader keeps their place.
    @State private var atBottom = true
    /// Dragged by the pane's leading edge; kept between launches.
    @AppStorage("agent.paneWidth") private var stored: Double = Double(AgentPane.width)
    @State private var dragFrom: Double?

    static let width: CGFloat = 400
    static let widths: ClosedRange<Double> = 340...620

    private var width: CGFloat { fixedWidth ?? CGFloat(min(max(stored, AgentPane.widths.lowerBound), AgentPane.widths.upperBound)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            liveStatus
            ListenCard(browser: browser)
                .transition(still ? .identity : .opacity)
            if agent.items.isEmpty && !agent.busy {
                empty
            } else {
                transcript
            }
            composer
        }
        .frame(width: width)
        .background(Palette.ground)
        .animation(Motion.quick, value: drive.live)
        .animation(still ? nil : Motion.quick, value: listen.phase == .off)
        .overlay(alignment: .leading) { grip }
        .onAppear { focused = true }
        .onChange(of: agent.focusTick) { _, _ in focused = true }
    }

    /// The leading edge, a few points wide: drag to make the pane wider.
    private var grip: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = dragFrom ?? Double(width)
                        dragFrom = from
                        stored = min(max(from - Double(drag.translation.width), AgentPane.widths.lowerBound), AgentPane.widths.upperBound)
                    }
                    .onEnded { _ in dragFrom = nil }
            )
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            model
            Spacer(minLength: 4)
            if servers.readyTools > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 9.5))
                    Text("\(servers.readyTools)").font(.system(size: 11)).monospacedDigit()
                }
                .foregroundStyle(Palette.muted)
                .help("Tools from your MCP servers (mcp.json):\n" + servers.all.filter(\.ready).map { "\($0.name): \($0.tools.count)" }.joined(separator: "\n"))
            }
            // Real doors, not bare glyphs: a square each, washed under the
            // pointer (PaneDoor). "Close all" only shows beside a split.
            HStack(spacing: 2) {
                ListenDoor(browser: browser)
                PaneDoor(icon: "square.and.pencil", help: "New chat", on: !agent.items.isEmpty || agent.busy) { agent.clear() }
                if split.on {
                    PaneDoor(icon: "xmark.square", help: "Close all panes (⌘⌥E)") { Panes.closeAll(in: browser) }
                }
                PaneDoor(icon: "xmark", help: "Close (⌘E)") { agent.open = false }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 42)
    }

    /// Someone other than the pane's own agent at the wheel, said under the
    /// header for as long as it lasts, wherever the conversation is scrolled:
    /// the live run first, then any caller working beside it (an MCP call
    /// alongside a Jev run), each with its own Stop. The pane's own agent has
    /// the composer's Stop and its shimmering row; a band would say it twice.
    @ViewBuilder
    private var liveStatus: some View {
        let run = drive.live ? drive.run.flatMap { $0.driver == .pane ? nil : $0 } : nil
        let now = Date()
        let beside = drive.hands.values
            .filter { hand in
                hand.driver != .pane && hand.who.key != run?.who.key
                    && (hand.busy || (hand.until.map { $0 > now } ?? false))
            }
            .sorted { $0.since < $1.since }
        if run != nil || !beside.isEmpty {
            VStack(spacing: 0) {
                if let run { DriveLiveStrip(run: run) }
                ForEach(beside) { DriveHandStrip(hand: $0) }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The model, as a pill: which tier, and the menu to change it.
    private var model: some View {
        Menu {
            ForEach(Intelligence.Tier.allCases) { tier in
                Button {
                    brain.keys.tier = tier
                } label: {
                    HStack {
                        Text("\(tier.title) — \(tier.blurb)")
                        if tier == brain.tier {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Text(brain.accessLine)
            Text(modelLine)
            Button("Model access…") { browser.openSettings(.intelligence) }
            if !servers.all.isEmpty {
                Divider()
                ForEach(servers.all, id: \.name) { server in
                    Text("\(server.name) · \(server.ready ? "\(server.tools.count) tools" : server.state)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(brain.tier.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.8))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Palette.wash, in: Capsule())
            .contentShape(Capsule())
        }
        // The label draws its own small chevron; the button style's
        // indicator would sit in front of the word (SpaceHeader does the same).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model — \(modelLine) · \(brain.accessLine)")
    }

    /// The name sent for the tier, and the model the last answer said it was.
    private var modelLine: String {
        var line = "\(brain.tier.title) → \(brain.modelName)"
        if let answered = brain.answeredModel, answered != brain.modelName { line += " · answered by \(answered)" }
        return line
    }

    // MARK: - the conversation

    /// What the transcript draws, in order: the flat item list with each
    /// question's steps folded into one activity.
    enum Block: Identifiable {
        case user(Agent.Item)
        case answer(Agent.Item)
        case note(Agent.Item)
        case activity(AgentActivityGroup)
        case drive(Agent.Item)
        /// Asked, and nothing back yet.
        case thinking

        var id: String {
            switch self {
            case .user(let i), .answer(let i), .note(let i), .drive(let i): return i.id.uuidString
            case .activity(let g): return "activity-" + g.id.uuidString
            case .thinking: return "thinking"
            }
        }
    }

    static func blocks(_ items: [Agent.Item], busy: Bool) -> [Block] {
        var out: [Block] = []
        var turnStart = items.first?.at ?? Date()
        var current: Int?           // index in `out` of this question's activity
        var lastUser = -1
        func fold(_ item: Agent.Item) {
            if let at = current, case .activity(var group) = out[at] {
                group.items.append(item)
                out[at] = .activity(group)
            } else {
                out.append(.activity(AgentActivityGroup(id: item.id, items: [item], started: turnStart, running: false)))
                current = out.count - 1
            }
        }
        for item in items {
            switch item.kind {
            case .user:
                out.append(.user(item))
                turnStart = item.at
                current = nil
                lastUser = out.count - 1
            case .tool:
                fold(item)
            case .assistant where item.aside:
                fold(item)
            case .assistant:
                current = nil
                out.append(.answer(item))
            case .note:
                current = nil
                out.append(.note(item))
            case .drive:
                // Tools arriving after this card belong below it, not folded
                // back into the activity that preceded the outside driver.
                current = nil
                out.append(.drive(item))
            }
        }
        // Only the newest question can still be running.
        if busy {
            // An outside card ends folding, not an in-flight local tool.
            let running = out.indices.reversed().first { index in
                guard index > lastUser, case .activity(let group) = out[index] else { return false }
                return group.items.contains(where: \.running)
            } ?? current
            if let at = running, at > lastUser, case .activity(var group) = out[at] {
                group.running = true
                out[at] = .activity(group)
            } else {
                out.append(.thinking)
            }
        }
        return out
    }

    private var transcript: some View {
        // The scroll view's own height, read off the reader around it, so
        // "at the bottom" is measured against what is really on screen.
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(AgentPane.blocks(agent.items, busy: agent.busy)) { block in
                            view(block).id(block.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: AgentBottomKey.self, value: g.frame(in: .named("agent.chat")).minY)
                            })
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "agent.chat")
                .onPreferenceChange(AgentBottomKey.self) { y in
                    // A little slack, so a row landing does not count as scrolling up.
                    atBottom = y <= outer.size.height + 40
                }
                .overlay(alignment: .bottom) {
                    if !atBottom { jump(proxy) }
                }
                .animation(Motion.quick, value: atBottom)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: progress) { _, _ in
                    guard atBottom || agent.items.last?.kind == .user else { return }
                    withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: agent.revealTick) { _, _ in
                    // To the card of the run that asked for the pane, when it
                    // has one; a run nested in a step is at the end anyway.
                    let card = drive.run.flatMap { run in agent.items.last { $0.kind == .drive && $0.run == run.id } }
                    let target = card.map { $0.id.uuidString } ?? "bottom"
                    withAnimation(Motion.glide) { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }

    /// Scrolled up while more arrives: one press back to the end.
    private func jump(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(Motion.glide) { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(.system(size: 9.5, weight: .semibold))
                Text("Jump to latest").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12).frame(height: 26)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Enough of a number to know something new landed — a row, a step that
    /// finished, a driver's cycle — without making the items equatable.
    private var progress: Int {
        var n = agent.items.count * 1000 + agent.items.filter(\.running).count * 7 + agent.status.count
        if let run = drive.run {
            n += run.cycles.reduce(run.cycles.count) { $0 + $1.phases.count + ($1.outcome == nil ? 0 : 1) } * 13
        }
        return n + (agent.busy ? 1 : 0) + agent.expanded.count * 31
    }

    @ViewBuilder
    private func view(_ block: Block) -> some View {
        switch block {
        case .user(let item):
            HStack {
                Spacer(minLength: 48)
                Text(item.text)
                    .font(.system(size: 13)).foregroundStyle(Palette.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        case .answer(let item):
            MarkdownText(text: item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity(let group):
            AgentActivity(group: group)
        case .note(let item):
            note(item)
        case .drive(let item):
            if let run = agent.run(item.run) {
                DriveCard(run: run)
            }
        case .thinking:
            HStack(spacing: 8) {
                TypingDots()
                Text(agent.status.isEmpty ? "Thinking…" : agent.status)
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .shimmer()
            }
            .padding(.vertical, 2)
        }
    }

    /// A plain note is context ("About Hacker News", "Stopped") and sits
    /// quietly in the middle; a failure is a callout you cannot miss.
    @ViewBuilder
    private func note(_ item: Agent.Item) -> some View {
        if item.ok {
            HStack(spacing: 8) {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Text(item.text)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .fixedSize()
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                Text(item.text)
                    .font(.system(size: 12)).foregroundStyle(Palette.ink)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.orange.opacity(0.22), lineWidth: 1))
        }
    }

    // MARK: - empty

    private var empty: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [DriveStyle.accent.opacity(0.95), Color(red: 0.88, green: 0.62, blue: 0.42)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                .shadow(color: DriveStyle.accent.opacity(0.3), radius: 10, y: 3)
                Text(agent.ready ? "What should we do?" : "Set up a model to start")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(agent.ready
                     ? "It reads the page, clicks and types for you, and draws on your canvases."
                     : "Sign in with your Claude account, or add an API key for a gateway in Settings › Intelligence.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 290)
                // Setting up is the one thing to do, so it sits with the words.
                if !agent.ready { signIn.padding(.top, 6) }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 20)
            if agent.ready {
                VStack(spacing: 6) {
                    ForEach(suggestions, id: \.text) { s in
                        SuggestionRow(icon: s.icon, text: s.text) { agent.ask(s.text, in: browser) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var suggestions: [(icon: String, text: String)] {
        guard let tab = browser.active, !tab.isBlank else {
            return [("rectangle.on.rectangle", "Sum up my Personal canvas"),
                    ("square.on.square", "Which tabs do I have open?"),
                    ("globe", "Find today's top story on Hacker News")]
        }
        if tab.address.flatMap(CanvasLinks.id(from:)) != nil {
            return [("text.alignleft", "Sum up this board"),
                    ("square.grid.2x2", "Group these notes into frames by theme"),
                    ("arrow.triangle.branch", "Draw arrows between related notes"),
                    ("plus.square.on.square", "Add a sticky for each next step")]
        }
        return [("text.alignleft", "Summarise this page"),
                ("questionmark.circle", "What can I do here?"),
                ("link", "List the main links on this page"),
                ("tablecells", "Pull the key facts into a table")]
    }

    @ViewBuilder
    private var signIn: some View {
        VStack(spacing: 10) {
            switch account.phase {
            case .waiting, .exchanging:
                HStack(spacing: 7) {
                    Ring(size: 10)
                    Text(account.phase == .waiting ? "Finish signing in in the tab that opened…" : "Signing in…")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Pill("Cancel") { account.cancel() }
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.85))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                buttons
            case .idle:
                buttons
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Pill("Sign in with Claude", filled: true) { account.signIn(in: browser) }
            Pill("Use an API key") { browser.openSettings(.intelligence) }
        }
    }

    // MARK: - composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $agent.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .disabled(!agent.ready)
                // Fork (ui-system): the prompt drawn in muted ink — a plain
                // field ignores a prompt's colour and showed it at ~1.7:1.
                .background(alignment: .topLeading) {
                    if agent.draft.isEmpty { Text(placeholder).foregroundStyle(Palette.muted).allowsHitTesting(false).accessibilityHidden(true) }
                }
                .accessibilityLabel(placeholder)
                .font(.system(size: 13))
                // What the field shows is what goes (Fork/Voice/ComposerInsert.swift).
                .onSubmit { ComposerInsert.syncDraft(in: Windows.window(of: browser)); agent.send(in: browser) }
                // Return sends (the field's submit); ⇧Return is a new line,
                // as in every chat (LineBreak).
                .onChange(of: focused, initial: true) { _, on in
                    lineBreaks(on)
                    Voice.shared.composer(focused: on, in: browser) // where dictated words may go through the field editor
                }
                .onDisappear { lineBreaks(false); Voice.shared.composer(focused: false, in: browser) }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            // "Listening…" and the words so far, never in the draft (Fork/Voice/VoiceUI.swift).
            DictationPreview(browser: browser)
            HStack(spacing: 6) {
                context
                TranscriptChip()
                Spacer(minLength: 4)
                jev
                MicButton(browser: browser, agentReady: agent.ready)
                send
            }
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(focused ? Palette.faint : Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .animation(Motion.quick, value: focused)
    }

    private var placeholder: String {
        guard agent.ready else { return "Sign in with Claude or add a key to start" }
        guard let tab = browser.active, !tab.isBlank else { return "Ask anything, or say what to do…" }
        return tab.address.flatMap(CanvasLinks.id(from:)) != nil ? "Ask about this canvas…" : "Ask about this page…"
    }

    /// The page in front of every question, as a chip: which one, and a
    /// click to leave it out.
    @ViewBuilder
    private var context: some View {
        if let tab = browser.active, !tab.isBlank {
            let canvas = tab.address.flatMap(CanvasLinks.id(from:)).map { Canvases.shared.entry($0)?.name ?? "Canvas" }
            let on = agent.config.pageContext
            Button { agent.config.pageContext.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: on ? (canvas != nil ? "rectangle.on.rectangle" : "doc.text") : "eye.slash")
                        .font(.system(size: 9.5))
                    Text(canvas ?? (tab.title.isEmpty ? (tab.address?.host ?? "This page") : tab.title))
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.tail)
                        .strikethrough(!on, color: Palette.muted)
                }
                .foregroundStyle(on ? Palette.ink.opacity(0.75) : Palette.muted)
                .padding(.horizontal, 8).frame(height: 22)
                // 180: with /jev, the mic and Send beside it, the row still
                // fits the narrowest pane (340 pt) without spilling over —
                // less beside the Listen transcript's chip.
                .frame(maxWidth: pageChipWidth, alignment: .leading)
                .background(on ? Palette.ground : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .help(on ? "This \(canvas != nil ? "canvas" : "page") goes in front of every question — click to leave it out"
                     : "Left out — click to put this \(canvas != nil ? "canvas" : "page") in front of every question")
        }
    }

    /// The page chip's widest: 180, or what the row leaves it beside "Live
    /// transcript" (the composer's 44 pt of margins, /jev, the mic, Send,
    /// the gaps, and that chip's ~105 pt).
    private var pageChipWidth: CGFloat {
        guard TranscriptChip.shown(heard) else { return 180 }
        return min(180, max(64, width - 270))
    }

    /// The draft as a /jev command for a terminal agent.
    private var jev: some View {
        Button {
            let goal = agent.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MCP.jevCommand(goal: goal.isEmpty ? nil : goal), forType: .string)
            copiedJev = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedJev = false }
        } label: {
            Image(systemName: copiedJev ? "checkmark" : "terminal")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copiedJev ? "Copied" : "Copy this goal as a /jev command")
    }

    /// Send, or Stop while it works — the same place, so the thumb knows.
    private var send: some View {
        Button {
            if agent.busy { agent.stop() } else { agent.send(in: browser) }
        } label: {
            Image(systemName: agent.busy ? "stop.fill" : "arrow.up")
                .font(.system(size: agent.busy ? 9 : 11.5, weight: .bold))
                .foregroundStyle(agent.busy || canSend ? Palette.ground : Palette.muted)
                .frame(width: 28, height: 28)
                .background(agent.busy || canSend ? Palette.ink : Palette.wash, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!agent.busy && !canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(agent.busy ? "Stop" : "Send (Return)")
        .animation(Motion.quick, value: agent.busy)
    }

    private func lineBreaks(_ on: Bool) {
        guard on != breaking else { return }
        breaking = on
        LineBreak.watch(on)
    }

    private var canSend: Bool { agent.ready && !agent.busy && !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The bottom of the transcript, measured against its scroll view.
private struct AgentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One suggestion on the empty pane: a row to press instead of a question
/// to think up.
private struct SuggestionRow: View {
    let icon: String
    let text: String
    let act: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .opacity(over ? 1 : 0)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(over ? Palette.hover : Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .animation(Motion.quick, value: over)
    }
}

/// Three dots that rise in turn: it has the question and is working on it.
struct TypingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(DriveStyle.accent)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.3)
                    .offset(y: on ? -1.5 : 1.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.16), value: on)
            }
        }
        .onAppear { on = true }
    }
}

/// ⇧Return in the composer. The field's own editor sends on it, as on a
/// plain Return — only ⌥Return breaks the line there — and SwiftUI's key
/// handlers never see a press the editor has, so the line break is asked of
/// the editor directly, at the caret, while the composer has the keyboard.
@MainActor
private enum LineBreak {
    private static var monitor: Any?
    /// Composers that have the keyboard: one per window can.
    private static var watchers = 0

    static func watch(_ on: Bool) {
        watchers = max(watchers + (on ? 1 : -1), 0)
        if watchers > 0, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // Return or the keypad's Enter, with only ⇧ held.
                guard event.keyCode == 36 || event.keyCode == 76, flags == .shift,
                      let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor
                else { return event }
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
        } else if watchers == 0, let installed = monitor {
            NSEvent.removeMonitor(installed)
            monitor = nil
        }
    }
}
