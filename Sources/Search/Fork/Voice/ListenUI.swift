import AppKit
import SwiftUI

// Listen in the ⌘E pane (Listen.swift): the door in the header, the card
// pinned under it, and the composer's "Live transcript" chip. Drawn like the
// pane's live bands (DriveLiveStrip): a quiet wash, a hairline, small capsule
// controls — no waveform, no glow, no chat bubbles. Words are shown here and
// nowhere else in the pane; the chat stays the chat.

/// The header's Listen door: hidden with voice off; dimmed (a click opens
/// Settings › Intelligence › Voice) while the speech model isn't ready; disabled while a
/// dictation has the microphone; the accent while Listen has it.
struct ListenDoor: View {
    let browser: Browser
    @ObservedObject private var listen = Listen.shared
    @ObservedObject private var voice = Voice.shared
    @ObservedObject private var prefs = VoicePrefs.shared
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        switch listen.door {
        case .hidden:
            EmptyView()
        case .ready:
            switch listen.phase {
            case .paused: door(help: "Resume Listen", on: true, tint: Palette.muted)
            case .stopped: door(help: "Listen again", on: true, tint: Palette.muted)
            default: door(help: "Listen", on: true, tint: Palette.muted)
            }
        case .waiting(let why):
            door(help: why, on: true, tint: Palette.muted.opacity(0.45))
        case .busy(let why):
            door(help: why, on: false, tint: Palette.muted)
        case .on(let why):
            door(help: why, on: true, tint: DriveStyle.accent)
        }
    }

    private func door(help: String, on: Bool, tint: Color) -> some View {
        PaneDoor(icon: "waveform", help: help, on: on, tint: tint) { listen.doorPressed(in: browser) }
            .accessibilityLabel("Listen")
            .accessibilityHint(help == "Listen" ? "Starts a live transcript of the microphone"
                               : help == "Resume Listen" || help == "Listen again" ? "Listens on into the same transcript" : help)
    }
}

/// The card under the header while there is a Listen transcript.
struct ListenCard: View {
    let browser: Browser
    @ObservedObject private var listen = Listen.shared
    @ObservedObject private var transcript = Transcript.shared
    @Environment(\.accessibilityReduceMotion) private var still
    /// The list is scrolled to its end; new lines follow only then.
    @State private var atBottom = true

    /// The open list's ceiling.
    static let listMax: CGFloat = 220

    var body: some View {
        if listen.phase != .off {
            VStack(alignment: .leading, spacing: 0) {
                head
                if listen.expanded {
                    list
                } else {
                    latest
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 5)
            .padding(.bottom, listen.expanded ? 8 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.wash)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Listen")
        }
    }

    // MARK: - the row

    private var head: some View {
        HStack(spacing: 6) {
            Button {
                if still { listen.expanded.toggle() } else { withAnimation(Motion.quick) { listen.expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    dot
                    title
                    Image(systemName: listen.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(listen.expanded ? "Hide the transcript" : "Show the transcript")
            .accessibilityLabel(listen.title())
            .accessibilityHint(listen.expanded ? "Hides the transcript" : "Shows the transcript")
            controls
        }
    }

    /// Steady, never pulsing: the accent while it listens, grey otherwise.
    @ViewBuilder
    private var dot: some View {
        switch listen.phase {
        case .live:
            Circle().fill(DriveStyle.accent).frame(width: 7, height: 7).accessibilityHidden(true)
        case .arming, .paused:
            Circle().strokeBorder(Palette.muted, lineWidth: 1.2).frame(width: 7, height: 7).accessibilityHidden(true)
        case .stopped, .off:
            EmptyView()
        }
    }

    @ViewBuilder
    private var title: some View {
        if listen.phase == .live, let since = listen.liveSince {
            TimelineView(.periodic(from: since, by: 1)) { beat in
                titleText(listen.title(at: beat.date))
            }
        } else {
            titleText(listen.title())
        }
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(listen.phase == .live ? Palette.ink : Palette.ink.opacity(0.8))
            .lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder
    private var controls: some View {
        switch listen.phase {
        case .live, .arming:
            if listen.phase == .live {
                ListenPill(icon: "pause.fill", title: "Pause", help: "Pause listening — the transcript stays") { listen.pause() }
            }
            ListenPill(icon: "stop.fill", title: "Stop", help: "Stop listening — the transcript stays until you forget it") { listen.stop() }
        case .paused:
            ListenPill(icon: "play.fill", title: "Resume", help: "Listen on, into this transcript") { listen.resume(in: browser) }
            ListenPill(icon: "stop.fill", title: "Stop", help: "Stop listening — the transcript stays until you forget it") { listen.stop() }
        case .stopped:
            ListenPill(icon: "waveform", title: "Listen again", help: "Listen on, into this transcript") { listen.resume(in: browser) }
            ListenPill(icon: "trash", title: "Forget", help: "Forget this transcript — the agent can't read it any more") { listen.forget() }
        case .off:
            EmptyView()
        }
    }

    // MARK: - collapsed: the latest line

    private var latest: some View {
        let last = transcript.segments.last?.text
        let empty = listen.phase == .live || listen.phase == .arming ? "Nothing said yet" : "Nothing was said"
        return Text(last ?? empty)
            .font(.system(size: 11.5))
            .foregroundStyle(last == nil ? Palette.faint : Palette.muted)
            .lineLimit(1).truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 15)
            .padding(.trailing, 8)
            .accessibilityLabel(last.map { "Latest: \($0)" } ?? empty)
    }

    // MARK: - expanded: the list

    private static let time: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm"
        return format
    }()

    /// As tall as its lines up to `listMax`, then a scroller of that height:
    /// the first of the two that fits, so no measuring feeds back into layout.
    private var list: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .frame(height: ListenCard.listMax)
                    .defaultScrollAnchor(.bottom)
                    .listenFollows($atBottom)
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom { jump(proxy) }
                    }
                    .onAppear { follow(proxy, animated: false) }
                    .onChange(of: transcript.segments.count) { _, _ in if atBottom { follow(proxy, animated: true) } }
                    .onChange(of: listen.partial) { _, _ in if atBottom { follow(proxy, animated: false) } }
            }
        }
        .frame(maxHeight: ListenCard.listMax)
        .padding(.top, 2)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if transcript.segments.isEmpty && listen.partial.isEmpty {
                Text(listen.capturing ? "Nothing said yet" : "Nothing was said")
                    .font(.system(size: 12)).foregroundStyle(Palette.faint)
            }
            ForEach(transcript.segments, id: \.seq) { segment in
                row(ListenCard.time.string(from: segment.start), segment.text, partial: false)
            }
            if !listen.partial.isEmpty {
                row(ListenCard.time.string(from: Date()), listen.partial, partial: true)
            }
            Color.clear.frame(height: 1).id("listen.bottom")
        }
        .padding(.leading, 15)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown only while the list is scrolled up from its end.
    private func jump(_ proxy: ScrollViewProxy) -> some View {
        Button { follow(proxy, animated: true) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: 8.5, weight: .semibold)).accessibilityHidden(true)
                Text("Jump to latest").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6).padding(.bottom, 4)
        .help("Scroll to the newest line")
        .accessibilityLabel("Jump to latest")
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !still {
            withAnimation(Motion.quick) { proxy.scrollTo("listen.bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("listen.bottom", anchor: .bottom)
        }
    }

    private func row(_ time: String, _ text: String, partial: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time)
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(Palette.muted)
                .fixedSize()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(partial ? Palette.muted : Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(partial ? "Now: \(text)" : "\(time): \(text)")
    }
}

private extension View {
    /// Whether the scroller is at (or within a line of) its end, from the
    /// scroll view itself. Listen needs macOS 15, so before it there is no list.
    @ViewBuilder
    func listenFollows(_ atBottom: Binding<Bool>) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                // Slack, so a line landing doesn't count as scrolling up.
                geometry.visibleRect.maxY >= geometry.contentSize.height - 30
            } action: { _, now in
                atBottom.wrappedValue = now
            }
        } else {
            self
        }
    }
}

/// The card's small capsule buttons, like the live bands' Stop.
struct ListenPill: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 7.5, weight: .semibold)).accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).frame(height: 20)
            .background(over ? Palette.hover : Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

/// "Live transcript" beside the page chip: the Listen transcript goes with
/// the next question while it is on. Shown once the transcript has a line.
struct TranscriptChip: View {
    @ObservedObject private var agent = Agent.shared
    @ObservedObject private var transcript = Transcript.shared

    static func shown(_ transcript: Transcript) -> Bool {
        transcript.id != nil && !transcript.segments.isEmpty
    }

    var body: some View {
        if TranscriptChip.shown(transcript) {
            let on = agent.transcriptContext
            Button { agent.transcriptContext.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: on ? "waveform" : "eye.slash").font(.system(size: 9.5))
                    Text("Live transcript")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .strikethrough(!on, color: Palette.muted)
                }
                .foregroundStyle(on ? Palette.ink.opacity(0.75) : Palette.muted)
                .padding(.horizontal, 8).frame(height: 22)
                .background(on ? Palette.ground : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help(on ? "The Listen transcript goes with your next question — click to leave it out"
                     : "Left out — click to send the Listen transcript with your next question")
            .accessibilityLabel("Live transcript")
            .accessibilityValue(on ? "Included with your question" : "Left out")
        }
    }
}
