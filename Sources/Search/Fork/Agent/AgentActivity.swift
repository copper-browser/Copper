import SwiftUI

// What the agent did on the way to an answer, folded to one quiet row.
//
// A question can take a dozen tool calls; shown one chip each they push the
// answer off the screen and read like a log. ChatGPT's shape is the right
// one: a single line under the question — "Worked for 4 s · 3 steps" — that
// opens to the steps when you want them, each in words ("Read 5 shapes on
// Personal", "40 operations applied") with its time, a failure in red. While
// it runs, the line is the step in flight, shimmering. A Jev run the agent
// started nests its own steps under the step that asked for it.

/// One question's activity: its steps and the model's narration between them.
struct AgentActivityGroup: Identifiable {
    /// The first step's id: stable while the turn grows.
    let id: UUID
    var items: [Agent.Item]
    /// When the question was asked.
    var started: Date
    /// Still working on it.
    var running: Bool

    var steps: [Agent.Item] { items.filter { $0.kind == .tool } }
    var failures: Int { steps.filter { !$0.ok }.count }
    var warnings: Int { steps.filter { $0.ok && !$0.warning.isEmpty }.count }
    /// When the last step ended.
    var ended: Date {
        items.map { $0.kind == .tool ? $0.at.addingTimeInterval($0.ms / 1000) : $0.at }.max() ?? started
    }
}

struct AgentActivity: View {
    let group: AgentActivityGroup
    @ObservedObject private var agent = Agent.shared
    @ObservedObject private var drive = Drive.shared

    private var open: Bool { agent.expanded.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.glide) { agent.toggle(expanded: group.id) }
            } label: {
                head.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the steps" : "Show the steps")
            if open {
                list.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - the one line

    private var head: some View {
        HStack(spacing: 7) {
            if group.running {
                Ring(size: 10)
                Text(current)
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .shimmer()
                TimelineView(.periodic(from: group.started, by: 1)) { beat in
                    Text("· \(DriveStyle.span(beat.date.timeIntervalSince(group.started)))")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.muted)
                }
                .fixedSize()
            } else {
                Image(systemName: group.failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(group.failures > 0 ? Color.red.opacity(0.75) : Palette.muted)
                summary
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Palette.faint)
                .rotationEffect(.degrees(open ? 90 : 0))
            Spacer(minLength: 0)
        }
    }

    private var summary: Text {
        let steps = group.steps.count
        var line = Text("Worked for \(DriveStyle.span(group.ended.timeIntervalSince(group.started)))")
            + Text(" · \(steps) step\(steps == 1 ? "" : "s")")
        line = line.foregroundColor(Palette.muted)
        if group.failures > 0 {
            line = line + Text(" · \(group.failures) failed").foregroundColor(Color.red.opacity(0.8))
        } else if group.warnings > 0 {
            line = line + Text(" · \(group.warnings) with errors").foregroundColor(Color.red.opacity(0.8))
        }
        return line.font(.system(size: 12))
    }

    /// The step in flight, in words; a Jev run under it says its own phase.
    private var current: String {
        guard let step = group.steps.last(where: \.running) else {
            return agent.status.isEmpty ? "Thinking…" : agent.status
        }
        if let run = agent.run(step.run), let phase = run.cycles.last?.phases.last?.title {
            return "\(step.title) · \(phase)"
        }
        return step.title + "…"
    }

    // MARK: - the steps

    private var list: some View {
        HStack(alignment: .top, spacing: 0) {
            // A thread down the left, so the steps read as one piece of work.
            Rectangle().fill(Palette.hairline).frame(width: 1).padding(.leading, 5.5).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(group.items) { item in
                    if item.kind == .tool { step(item) } else { aside(item) }
                }
            }
            .padding(.leading, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func aside(_ item: Agent.Item) -> some View {
        Text(MarkdownText.inline(item.text))
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
            .lineLimit(5).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func step(_ item: Agent.Item) -> some View {
        let failed = !item.ok
        let red = Color.red.opacity(0.82)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AgentActivity.icon(item.tool))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(failed ? red : Palette.muted)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? Agent.plain(item.tool) : item.title)
                        .font(.system(size: 12)).foregroundStyle(failed ? red : Palette.ink)
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.warning.isEmpty {
                        Text(item.warning)
                            .font(.system(size: 11)).foregroundStyle(red)
                            .lineLimit(3).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else if failed, let reason = item.text.split(separator: "\n").last, reason.hasPrefix("→") {
                        Text(reason.dropFirst(2))
                            .font(.system(size: 11)).foregroundStyle(red)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                if item.running {
                    Ring(size: 9)
                } else if item.ms > 0 {
                    Text(DriveStyle.ms(Int(item.ms)))
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .fixedSize()
                }
            }
            .help(item.text)
            if let run = agent.run(item.run) { nested(run) }
        }
    }

    /// A Jev run this step started: its moves, folded to lines, under it.
    private func nested(_ run: Drive.Run) -> some View {
        let live = drive.live && drive.run?.id == run.id
        let shown = run.cycles.suffix(8)
        return VStack(alignment: .leading, spacing: 5) {
            if run.cycles.count > shown.count {
                Text("\(run.cycles.count - shown.count) earlier steps")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            ForEach(Array(shown)) { cycle in DriveStep(cycle: cycle, jev: true) }
            if !live, run.status != .running {
                Text(run.statusLine(busy: false))
                    .font(.system(size: 11)).foregroundStyle(run.failed ? Color.red.opacity(0.8) : Palette.muted)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 23)
    }

    /// An SF symbol per tool.
    static func icon(_ tool: String) -> String {
        switch tool {
        case "canvas_read": return "eye"
        case "canvas_apply": return "square.and.pencil"
        case "canvas_list", "canvas_open": return "rectangle.on.rectangle"
        case "canvas_select", "canvas_focus": return "scope"
        case "canvas_create": return "plus.rectangle.on.rectangle"
        case "canvas_invite": return "person.badge.plus"
        case "canvas_screenshot", "browser_take_screenshot": return "camera"
        case "jev_run", "jev_step": return "sparkle"
        case "jev_extract": return "text.viewfinder"
        case "jev_observe", "browser_snapshot", "browser_get_text", "browser_find", "browser_console_messages": return "doc.text.magnifyingglass"
        case "browser_click", "browser_hover", "browser_drag": return "cursorarrow.click"
        case "browser_type", "browser_fill_form", "browser_press_key", "browser_select_option": return "keyboard"
        case "browser_navigate", "browser_navigate_back", "browser_navigate_forward": return "globe"
        case "browser_tabs", "browser_close", "browser_groups": return "square.on.square"
        case "browser_scroll": return "arrow.up.and.down"
        case "browser_wait_for": return "hourglass"
        case "browser_evaluate": return "chevron.left.forwardslash.chevron.right"
        case "browser_sign_in", "browser_autofill", "browser_vault_save", "browser_vault_note": return "key"
        default: return tool.contains("__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

// MARK: - markdown

/// The model's answer as it was meant to read: paragraphs, headings, lists,
/// quotes and code blocks, with bold, italics, `code` and links inside them.
/// AttributedString reads the inline part; the blocks are split here, since
/// SwiftUI's Text draws a whole-document parse as one run-on paragraph.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13

    enum Block {
        case paragraph(String)
        case heading(String, Int)
        case item(String, marker: String, depth: Int)
        case quote(String)
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownText.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownText.inline(s))
                .font(.system(size: size)).foregroundStyle(Palette.ink)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let s, let level):
            Text(MarkdownText.inline(s))
                .font(.system(size: level <= 1 ? size + 3 : (level == 2 ? size + 1.5 : size), weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let s, let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(.system(size: marker == "•" ? size : size - 0.5)).monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .frame(minWidth: 10, alignment: .trailing)
                Text(MarkdownText.inline(s))
                    .font(.system(size: size)).foregroundStyle(Palette.ink)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16 + 2)
        case .quote(let s):
            HStack(alignment: .top, spacing: 9) {
                Capsule().fill(Palette.faint).frame(width: 2.5)
                Text(MarkdownText.inline(s))
                    .font(.system(size: size)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let s):
            Text(s)
                .font(.system(size: size - 1.5, design: .monospaced)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 3)
        }
    }

    /// Bold, italics, `code` and links; plain text when it isn't markdown.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    out.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let depth = min(indent / 2, 3)
            if line == "---" || line == "***" || line == "___" { flush(); out.append(.rule); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " ", line.distance(from: line.startIndex, to: hashes) <= 6 {
                flush()
                out.append(.heading(String(line[hashes...]).trimmingCharacters(in: .whitespaces), line.distance(from: line.startIndex, to: hashes)))
                continue
            }
            if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
                flush()
                out.append(.item(String(line.dropFirst(2)), marker: "•", depth: depth))
                continue
            }
            if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex,
               line[dot] == "." || line[dot] == ")", line[line.index(after: dot)...].first == " " {
                flush()
                out.append(.item(String(line[line.index(dot, offsetBy: 2)...]), marker: String(line[..<dot]) + ".", depth: depth))
                continue
            }
            if line.hasPrefix(">") {
                flush()
                out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }
        if let open = code { out.append(.code(open.joined(separator: "\n"))) }
        flush()
        return out
    }
}

// MARK: - shimmer

/// A highlight that sweeps across text in flight: it is working, without a
/// spinner shouting about it.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content
            .overlay {
                if !still {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Palette.ink.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(geo.size.width * 0.4, 30))
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { phase = 1.1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}
