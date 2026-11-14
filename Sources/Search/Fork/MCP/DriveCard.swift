import SwiftUI

// Someone else's hands on the page, drawn inside the agent pane's
// conversation: a Jev run, an agent on the loopback server calling tools one
// by one (phi, Claude Code, the `copper` CLI), a bot through a link.
//
// This used to be a pane of its own — the driver timeline — open beside the
// agent's chat, so a canvas_apply by the pane's agent showed twice, side by
// side. Now there is one pane and a run is a card in it, where it happened:
// who, on what goal, the steps as they land, how long, Stop. The timeline's
// detail (every phase, how sure Jev was, what else it was offered) is the
// card's expanded state, not a second window into the same story. A Jev run
// the pane's own agent starts is no card at all; its cycles nest inside the
// step that asked for it (AgentActivity).
//
// No JSON reaches this view; Drive has already put everything into the
// page's own words.

/// The one warm note in an otherwise grey pane: the live dot, the stop, the
/// ring around a page under control. Shared with the trail drawn in the page.
enum DriveStyle {
    static let accent = Color(red: 0.78, green: 0.45, blue: 0.24)

    /// A duration as a person reads it: milliseconds until a second, then
    /// one decimal of seconds. No thousands separators anywhere.
    static func ms(_ n: Int) -> String {
        n < 1000 ? "\(n) ms" : String(format: "%.1f s", Double(n) / 1000)
    }

    /// A span of work: "4 s", "1 min 12 s".
    static func span(_ seconds: TimeInterval) -> String {
        let t = Int(max(seconds, 0).rounded())
        if t < 60 { return "\(max(t, 1)) s" }
        return t % 60 == 0 ? "\(t / 60) min" : "\(t / 60) min \(t % 60) s"
    }
}

extension Drive.Run {
    /// How the run stands, in one line: "Driving · 3 calls", "Done — found it".
    func statusLine(busy: Bool) -> String {
        let acted = cycles.filter { $0.outcome != nil }.count
        let word = driver == .jev ? "action" : "call"
        let count = "\(acted) \(word)\(acted == 1 ? "" : "s")"
        if status == .running {
            if driver != .jev { return busy ? "Driving · \(count)" : "Thinking · \(count)" }
            return "Running · \(count)"
        }
        // The note is already a sentence; the head only says which kind of
        // ending it was. "Stopped by the user" says both, so it stands alone.
        func said(_ head: String) -> String { note.isEmpty ? head : "\(head) — \(note)" }
        switch status {
        case .running: return "Running"
        case .done: return said("Done")
        case .blocked: return said("Blocked")
        case .budget: return said("Out of steps")
        case .error: return said("Error")
        case .ended: return said("Let go")
        case .stopped: return note.isEmpty ? "Stopped by you" : note
        }
    }

    /// Whether the run ended badly enough to say so in red.
    var failed: Bool { status == .error || status == .blocked }
}

/// One outside driver's run, as a card in the conversation.
struct DriveCard: View {
    let run: Drive.Run
    @ObservedObject private var drive = Drive.shared
    @ObservedObject private var agent = Agent.shared

    /// The steps shown folded: the newest few. The rest is one click away.
    private static let folded = 4

    private var live: Bool {
        run.status == .running && (drive.run?.id == run.id ? drive.live : drive.hands[run.who.key]?.busy == true)
    }
    private var busy: Bool { live && (drive.run?.id == run.id ? drive.busy : drive.hands[run.who.key]?.busy == true) }
    private var open: Bool { agent.expanded.contains(run.id) }

    var body: some View {
        let swatch = Drive.colour(for: run.who)
        VStack(alignment: .leading, spacing: 10) {
            head(swatch)
            if !run.goal.isEmpty {
                Text(run.goal)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let thought = run.thought, !thought.isEmpty, run.driver != .jev {
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(swatch.fill.opacity(live ? 0.7 : 0.35)).frame(width: 2)
                    Text(thought)
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .lineLimit(3).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !run.cycles.isEmpty || live {
                steps
            }
            foot
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(live ? swatch.fill.opacity(0.45) : Palette.hairline, lineWidth: 1)
        )
        .animation(Motion.quick, value: live)
    }

    private func head(_ swatch: Drive.Swatch) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(swatch.fill)
                if run.driver == .jev {
                    Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(swatch.ink)
                } else {
                    Text(run.who.initial).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(swatch.ink)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(run.driver.name)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(byline)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DriveClock(run: run, live: live).fixedSize()
            // Fork (agent-ux): no Stop here — the live band at the top of the
            // pane has the one Stop, in view however far this has scrolled.
        }
    }

    /// Fork (agent-ux): the task, then the tab — "Booking a table · on
    /// OpenTable". Who asked for a Jev run only when there is no task.
    private var byline: String {
        var bits: [String] = []
        if !run.who.thread.isEmpty, run.who.thread != "this window" {
            bits.append(run.who.thread)
        } else if run.driver == .jev, !run.who.via.isEmpty {
            bits.append("for \(run.who.via)")
        }
        let page = run.title.isEmpty ? (URL(string: run.url)?.host ?? "") : run.title
        if !page.isEmpty { bits.append("on \(page)") }
        return bits.isEmpty ? (live ? "is driving" : "drove a tab") : bits.joined(separator: " · ")
    }

    @ViewBuilder
    private var steps: some View {
        if open {
            // The foot already says it is thinking, with its dot.
            DriveTimeline(run: run, live: live, busy: busy, thinking: false)
                .padding(.top, 2)
        } else {
            let shown = run.cycles.suffix(DriveCard.folded)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shown)) { cycle in DriveStep(cycle: cycle, jev: run.driver == .jev) }
            }
        }
        if run.cycles.count > DriveCard.folded || run.cycles.contains(where: { !($0.outcome?.candidates.isEmpty ?? true) || !($0.outcome?.error ?? "").isEmpty }) || open {
            Button {
                withAnimation(Motion.glide) { agent.toggle(expanded: run.id) }
            } label: {
                HStack(spacing: 4) {
                    Text(open ? "Fewer details" : (run.cycles.count > DriveCard.folded ? "All \(run.cycles.count) steps" : "Details"))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var foot: some View {
        HStack(spacing: 6) {
            if live {
                PulseDot(colour: Drive.colour(for: run.who).fill)
            } else {
                Image(systemName: run.failed ? "exclamationmark.circle.fill" : (run.status == .stopped ? "stop.circle" : "checkmark.circle"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(run.failed ? Palette.danger : Palette.muted)
            }
            Text(run.statusLine(busy: busy))
                .font(.system(size: 11)).foregroundStyle(run.failed ? Palette.ink : Palette.muted) // Fork (uitype): a sentence in ink, the red on its glyph
                .lineLimit(2).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if drive.refusingUntil != nil, run.status == .stopped, drive.run?.id == run.id {
                Button { drive.resume() } label: {
                    Text("Let it back in").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                .help("Accept the agent's calls again now")
            }
        }
    }
}

/// Ticking while the run is, still once it ends.
struct DriveClock: View {
    let run: Drive.Run
    let live: Bool

    var body: some View {
        if live {
            TimelineView(.periodic(from: run.started, by: 1)) { beat in
                label(beat.date.timeIntervalSince(run.started))
            }
        } else {
            label((run.ended ?? Date()).timeIntervalSince(run.started))
        }
    }

    private func label(_ seconds: TimeInterval) -> some View {
        Text(DriveStyle.span(seconds))
            .font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(live ? Palette.ink : Palette.muted)
    }
}

/// A small dot that breathes: something is live.
struct PulseDot: View {
    var colour: Color = DriveStyle.accent
    var size: CGFloat = 6
    @State private var breathing = false

    var body: some View {
        Circle().fill(colour)
            .frame(width: size, height: size)
            .opacity(breathing ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
            }
    }
}

/// The band under the agent pane's header while a run that is not the
/// pane's own is live: whose, what it is at, for how long, and Stop — in the
/// driver's colour, always in view however far the conversation has scrolled
/// past the run's card. A click goes to the card.
struct DriveLiveStrip: View {
    let run: Drive.Run
    @ObservedObject private var drive = Drive.shared
    @State private var over = false

    var body: some View {
        let swatch = Drive.colour(for: run.who)
        HStack(spacing: 8) {
            Button { Agent.shared.reveal() } label: {
                HStack(spacing: 8) {
                    PulseDot(colour: swatch.fill, size: 7)
                    Text(line)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    DriveClock(run: run, live: true).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the run")
            DriveStop(help: run.driver == .jev ? "Stop the run (⎋)" : "Take the browser back — its next calls are refused (⎋)") {
                drive.stop()
            }
        }
        .modifier(DriveBand(swatch: swatch, over: over))
        .onHover { over = $0 }
    }

    /// "phi is driving · 4 calls · Read 45 shapes", "Jev is driving · 3 actions · Clicking Search".
    /// The count before the words, which can run long and are cut first.
    private var line: String {
        let acted = run.cycles.filter { $0.outcome != nil }.count
        let word = run.driver == .jev ? "action" : "call"
        var bits = ["\(run.who.agent) is driving", "\(acted) \(word)\(acted == 1 ? "" : "s")"]
        if let doing = run.cycles.last, doing.ended == nil, let phase = doing.phases.last {
            bits.append(phase.title)
        } else if let thought = run.thought, !thought.isEmpty {
            bits.append(thought)
        }
        return bits.joined(separator: " · ")
    }
}

/// A caller working beside the live run (an MCP call while Jev drives): one
/// slimmer line with its own Stop, under the run's band.
struct DriveHandStrip: View {
    let hand: Drive.Hand
    @ObservedObject private var drive = Drive.shared
    @State private var over = false

    var body: some View {
        let swatch = Drive.colour(for: hand.who)
        HStack(spacing: 8) {
            Button { Agent.shared.reveal() } label: {
                HStack(spacing: 8) {
                    PulseDot(colour: swatch.fill, size: 7)
                    Text(hand.doing.isEmpty ? "\(hand.who.agent) is working" : "\(hand.who.agent) · \(hand.doing)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show its card")
            if drive.canStop(hand) {
                DriveStop(help: "Take the browser back from \(hand.who.agent) — its next calls are refused (⎋)") {
                    drive.stop(hand.who.key)
                }
            }
        }
        .modifier(DriveBand(swatch: swatch, over: over))
        .onHover { over = $0 }
    }
}

/// Fork (agent-ux): the one Stop — the live bands', the pill's over the
/// page — a labelled 24-point capsule with its key, ⎋ (Panes.escape).
struct DriveStop: View {
    /// ⎋ while something drives this window: the run stops, or the agent
    /// whose hand is on the tab in view is refused, as its Stop would.
    @MainActor static func escape(in browser: Browser) -> Bool {
        let drive = Drive.shared
        if drive.live { drive.stop(); return true }
        guard let tab = browser.active,
              let hand = drive.hands(on: tab.id).first(where: drive.canStop) else { return false }
        drive.stop(hand.who.key)
        return true
    }

    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 8))
                Text("Stop").font(.system(size: 11.5, weight: .medium))
                Text("⎋").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10).frame(height: 24)
            .background(hovering ? Palette.hover : Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("Stop")
    }
}

/// A live band's ground: a wash of the driver's colour, a hairline under it.
private struct DriveBand: ViewModifier {
    let swatch: Drive.Swatch
    let over: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(swatch.fill.opacity(over ? 0.16 : 0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .animation(Motion.quick, value: over)
    }
}

/// One cycle, folded to a line: what was done, to what, how it went.
struct DriveStep: View {
    let cycle: Drive.Cycle
    let jev: Bool

    var body: some View {
        let failed = !(cycle.outcome?.error ?? "").isEmpty
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: DriveStep.icon(cycle.outcome?.operation ?? cycle.phases.last.map { $0.kind.rawValue.uppercased() } ?? ""))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(failed ? Palette.danger : Palette.muted)
                .frame(width: 16)
            Text(line)
                .font(.system(size: 12)).foregroundStyle(Palette.ink) // Fork (uitype): the red is the glyph's; the line says what failed
                .lineLimit(2).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if cycle.ended == nil {
                Ring(size: 9)
            } else if let started = cycle.phases.first?.started, let ended = cycle.ended {
                Text(DriveStyle.ms(Int(ended.timeIntervalSince(started) * 1000)))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Palette.muted) // Fork (agent-ux): was faint, 1.3:1
                    .fixedSize()
            }
        }
    }

    /// The cycle as a sentence: a tool call's title and what it came to; a
    /// Jev cycle's move and its target; a phase in flight while it runs.
    private var line: String {
        guard let outcome = cycle.outcome else {
            return cycle.phases.last?.title ?? "Starting"
        }
        if let error = outcome.error, !error.isEmpty {
            // Fork (agent-ux): a sentence; the tool's own words are behind Details.
            return DriveStep.plain(head: cycle.phases.first?.title ?? outcome.operation.capitalized)
        }
        if !jev {
            let head = cycle.phases.first?.title ?? outcome.operation.capitalized
            if let result = outcome.result, !result.isEmpty { return result }
            if let text = outcome.text, !text.isEmpty { return "\(head) “\(text)”" }
            return head
        }
        switch outcome.operation {
        case "DONE": return "Said it is done"
        case "BLOCKED": return "Said it is blocked"
        case "TYPE_TEXT":
            let text = outcome.text.map { " “\($0)”" } ?? ""
            return "Typed\(text) into \(outcome.label)"
        default:
            if outcome.stale { return "Page moved — reading it again" }
            let verb: String
            switch outcome.operation {
            case "CLICK": verb = "Clicked"
            case "SELECT": verb = "Chose"
            case "SCROLL": verb = "Scrolled"
            case "WAIT": verb = "Waited for"
            case "GO": verb = "Opened"
            default: verb = outcome.operation.capitalized
            }
            return outcome.label.isEmpty ? verb : "\(verb) \(outcome.label)"
        }
    }

    /// "Changing the canvas" → "Changing the canvas didn't work".
    static func plain(head: String) -> String {
        let head = head.trimmingCharacters(in: CharacterSet(charactersIn: " .…"))
        return head.isEmpty ? "That step didn't work" : "\(head) didn't work"
    }

    /// An SF symbol per kind of move.
    static func icon(_ operation: String) -> String {
        switch operation {
        case "CLICK": return "cursorarrow.click"
        case "TYPE", "TYPE_TEXT", "KEY": return "keyboard"
        case "GO": return "globe"
        case "READ", "OBSERVE": return "eye"
        case "SCROLL": return "arrow.up.and.down"
        case "WAIT": return "hourglass"
        case "SHOT": return "camera"
        case "SELECT": return "list.bullet"
        case "DRAG": return "hand.draw"
        case "HOVER": return "cursorarrow.motionlines"
        case "TABS": return "square.on.square"
        case "SIGN_IN", "AUTOFILL": return "key"
        case "SCRIPT": return "chevron.left.forwardslash.chevron.right"
        case "DONE": return "checkmark"
        case "BLOCKED": return "hand.raised"
        case "ASK": return "sparkle"
        case _ where operation.hasPrefix("CANVAS"): return "rectangle.on.rectangle"
        default: return "circle.dashed"
        }
    }
}

/// The driver timeline's whole detail for one run: a numbered rail, each
/// cycle's phases with their times, what it amounted to, how sure Jev was
/// and the moves it was offered. The card's expanded state, and the nest
/// under a jev_run step the pane's agent made.
struct DriveTimeline: View {
    let run: Drive.Run
    let live: Bool
    let busy: Bool
    /// A "Thinking…" row while an agent is between calls.
    var thinking = true
    /// Which cycles have had their candidate list opened.
    @State private var shown: Set<UUID> = []

    private var isCall: Bool { run.driver != .jev }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(run.cycles.enumerated()), id: \.element.id) { index, cycle in
                if index > 0 {
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 7)
                }
                cycleRows(cycle)
            }
            if thinking, live, !busy, isCall {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 16)
                    Ring(size: 9)
                    Text("Thinking…").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .padding(.top, run.cycles.isEmpty ? 0 : 7)
            }
        }
    }

    private func cycleRows(_ cycle: Drive.Cycle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", cycle.number))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .frame(width: 16, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(cycle.phases) { phase in phaseRow(phase) }
                if let outcome = cycle.outcome {
                    outcomeRows(outcome, of: cycle)
                } else if rereading(cycle) {
                    Text("re-reading").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseRow(_ phase: Drive.Phase) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The title says what is happening; the detail is a fragment and
                // gives way first when the pane is narrow.
                Text(phase.title).font(.system(size: 12)).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                if let detail = phase.detail, !detail.isEmpty, !isCall {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let ms = phase.ms {
                    Text(DriveStyle.ms(ms))
                        .font(.system(size: 11)).monospacedDigit() // Fork (uitype): the monospaced face's thin strokes drew 3.8:1
                        .foregroundStyle(Palette.muted)
                } else {
                    Ring(size: 9)
                }
            }
            // An agent's reason for the call is a sentence, not a fragment:
            // it gets its own line under the title, wrapped, never cut to a word.
            if isCall, let detail = phase.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(3).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the cycle amounted to: the operation, the page's own name for the
    /// thing it touched, how sure Jev was, and what the page did about it.
    /// DONE and BLOCKED have no target to name, so they read as a sentence
    /// instead. A failed call reads as its error.
    @ViewBuilder
    private func outcomeRows(_ outcome: Drive.Outcome, of cycle: Drive.Cycle) -> some View {
        let spoken = outcome.operation == "DONE" || outcome.operation == "BLOCKED"
        VStack(alignment: .leading, spacing: 5) {
            if let error = outcome.error, !error.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    chip(outcome.operation)
                    Text(error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error)
                        .font(.system(size: 12)).foregroundStyle(Palette.danger)
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error)
                }
            } else if spoken {
                Text("Jev said \(outcome.operation) — \(percent(outcome.probability)) sure")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isCall {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    chip(outcome.operation)
                    if let text = outcome.text, !text.isEmpty {
                        Text("“\(text)”").font(.system(size: 12)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    }
                    Spacer(minLength: 6)
                    if let result = outcome.result {
                        Text("→ \(result)")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .lineLimit(2).truncationMode(.tail)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(result)
                    } else if let changed = outcome.pageChanged {
                        Text(changed ? "→ page changed" : "→ no change")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize()
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    chip(outcome.operation)
                    Text(target(outcome))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    Spacer(minLength: 6)
                    tail(outcome)
                }
            }
            candidates(outcome, of: cycle)
        }
        .padding(.top, 2)
    }

    /// A cycle that ended without an answer: Jev was asked, the page had
    /// moved on by the time it replied, and the loop went back to read it.
    private func rereading(_ cycle: Drive.Cycle) -> Bool {
        cycle.ended != nil && !cycle.phases.contains { $0.ended == nil } && cycle.phases.contains { $0.kind == .ask }
    }

    private func chip(_ operation: String) -> some View {
        Text(operation)
            .font(.system(size: 10, design: .monospaced)) // Fork (uitype): the 10 pt floor for words
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.ink.opacity(0.25), lineWidth: 1))
    }

    /// What became of the move. A number no one can read is worse than a
    /// label cut short, so the label gives way first.
    @ViewBuilder
    private func tail(_ outcome: Drive.Outcome) -> some View {
        if outcome.stale {
            Text("page moved · re-read").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize()
        } else {
            HStack(spacing: 5) {
                Text(percent(outcome.probability))
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Palette.muted)
                if let changed = outcome.pageChanged {
                    Text(changed ? "→ page changed" : "→ no change").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            .fixedSize()
        }
    }

    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private func target(_ outcome: Drive.Outcome) -> String {
        guard outcome.operation == "TYPE_TEXT", let text = outcome.text, !text.isEmpty else { return outcome.label }
        return "\(outcome.label) = \"\(text)\""
    }

    /// The other moves Jev was offered, folded away — interesting when a
    /// choice looks wrong, noise the rest of the time.
    @ViewBuilder
    private func candidates(_ outcome: Drive.Outcome, of cycle: Drive.Cycle) -> some View {
        if !outcome.candidates.isEmpty {
            let open = shown.contains(cycle.id)
            Button {
                withAnimation(Motion.quick) { if open { shown.remove(cycle.id) } else { shown.insert(cycle.id) } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("\(outcome.candidates.count) offered").font(.system(size: 11))
                }
                .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(outcome.candidates.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
}

/// Over the page while a run is live: "<Agent> · <task> · Stop" over the tab
/// it drives, "<Agent> · on <tab> · Stop" over any other — a click there goes
/// to that tab. Stop (or ⎋) takes the wheel back. A tab an agent has its
/// hand on wears the bar (HandBar) instead, in the same place and format.
/// Fork (agent-ux): it said "phi is driving" over whichever page was in
/// front, with a ring round it, as if that page were the one being driven.
struct DrivePill: View {
    let browser: Browser
    /// The run is on a tab not in view: the pill names it and goes there.
    let elsewhere: Bool
    @ObservedObject private var drive = Drive.shared
    @State private var breathing = false

    private var tab: Tab? { AgentTabs.find(drive.run?.tabID) }

    var body: some View {
        let name = drive.run?.who.agent ?? drive.run?.driver.name ?? "Agent"
        let title = tab.map { $0.title.isEmpty ? ($0.address?.host ?? "another tab") : $0.title } ?? "another tab"
        let thread = drive.run.map { $0.who.thread == "this window" ? "" : $0.who.thread } ?? ""
        let goal = drive.run.map { $0.goal.isEmpty ? thread : $0.goal } ?? ""
        let task = elsewhere || goal.isEmpty ? "on \(title)" : goal
        HStack(spacing: 6) {
            Circle()
                .fill(DriveStyle.accent)
                .frame(width: 6, height: 6)
                .opacity(drive.busy ? 1 : (breathing ? 0.35 : 1))
            Button { jump() } label: {
                (Text(name).fontWeight(.semibold) + Text("  ·  \(task)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .help(elsewhere ? "Go to the tab it is driving" : "Show what it is doing")
            DriveStop(help: drive.run?.driver == .jev ? "Stop the run (⎋)" : "Take the browser back (⎋)") { drive.stop() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 30)
        .background(Palette.ground.opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    /// To the driven tab: this window's row, else its space.
    private func jump() {
        guard elsewhere, let tab else { return Agent.shared.reveal() }
        if browser.tabs.contains(where: { $0.id == tab.id }) {
            browser.select(tab)
        } else if let space = Spaces.shared.spaceID(of: tab) {
            Spaces.shared.select(space, in: browser, landing: tab.id)
        } else {
            Agent.shared.reveal()
        }
    }
}
