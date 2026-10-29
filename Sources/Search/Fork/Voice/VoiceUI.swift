import AppKit
import SwiftUI

// The composer's two pieces of voice: the mic between /jev and Send, and one
// muted line above the buttons while a dictation runs (or says why it
// couldn't). Nothing else — no waveform, no glow, no sound, no window of its
// own. With voice off neither is drawn.

/// The mic: a 28 pt circle like Send. `mic` at rest, `mic.fill` on ink while
/// it listens; dimmed while the speech model isn't ready (a click opens
/// Settings › Intelligence › Voice) or is being prepared on this Mac (a press says so),
/// greyed while the agent can't take a message.
struct MicButton: View {
    let browser: Browser
    /// The agent can take a message (the pane observes what decides it).
    let agentReady: Bool
    @ObservedObject private var voice = Voice.shared
    @ObservedObject private var prefs = VoicePrefs.shared
    @ObservedObject private var store = ModelStore.shared
    /// Listen live or paused has the microphone: the mic is off meanwhile.
    @ObservedObject private var listen = Listen.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var over = false
    @State private var held = false

    var body: some View {
        let mic = voice.mic(agentReady: agentReady)
        if mic != .hidden {
            control(mic)
        }
    }

    private func control(_ mic: Voice.Mic) -> some View {
        let live = voice.shows(in: browser) && voice.active
        let hold = prefs.trigger == .hold
        return Image(systemName: live ? "mic.fill" : "mic")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(live ? Palette.ground : glyph(mic))
            .frame(width: 28, height: 28)
            .background(live ? Palette.ink.opacity(voice.phase == .dictating ? 1 : 0.55)
                             : (over && mic == .ready ? Palette.faint.opacity(0.55) : Palette.wash), in: Circle())
            .opacity(dimming(mic, live: live))
            .contentShape(Circle())
            .onHover { over = $0 }
            .gesture(holdGesture, including: hold ? .all : .none)
            .onTapGesture {
                guard !hold else { return }
                voice.press(.button, in: browser, window: Windows.window(of: browser))
            }
            .help(help(mic, live: live))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Dictate")
            .accessibilityValue(live ? "Listening" : "")
            .accessibilityHint(hint(mic))
            .accessibilityAction { voice.accessibilityActivate(in: browser) }
            .animation(still ? nil : Motion.quick, value: live)
            .animation(still ? nil : Motion.quick, value: over)
    }

    /// Press and hold: down starts, up ends — wherever the pointer went.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !held else { return }
                held = true
                voice.press(.button, in: browser, window: Windows.window(of: browser))
            }
            .onEnded { _ in
                held = false
                voice.lift(.button)
            }
    }

    private func glyph(_ mic: Voice.Mic) -> Color {
        mic == .ready ? Palette.ink.opacity(0.75) : Palette.muted
    }

    /// Dimmed while the model isn't ready, fainter still while the agent can't
    /// listen. Never while it listens: a load that turns slow mid-dictation
    /// shows on the line, not by fading the mic that is on.
    private func dimming(_ mic: Voice.Mic, live: Bool) -> Double {
        if live { return 1 }
        switch mic {
        case .ready, .hidden: return 1
        case .waiting, .preparing: return 0.5
        case .unavailable: return 0.35
        }
    }

    private func help(_ mic: Voice.Mic, live: Bool) -> String {
        if live, mic != .hidden {
            return prefs.trigger == .hold ? "Listening — let go to stop, Esc cancels" : "Listening — ⌃⇧D or click to stop, Esc cancels"
        }
        switch mic {
        case .waiting(let why), .unavailable(let why): return why
        case .preparing: return Voice.preparingHelp
        case .hidden: return ""
        case .ready:
            return prefs.trigger == .hold ? "Dictate — hold ⌃⇧D, or press and hold" : "Dictate — ⌃⇧D or click to start and stop"
        }
    }

    private func hint(_ mic: Voice.Mic) -> String {
        switch mic {
        case .waiting(let why), .unavailable(let why): return why
        case .preparing: return Voice.preparingHelp
        case .hidden: return ""
        case .ready:
            let start = prefs.trigger == .hold
                ? "Hold Control-Shift-D, or press and hold, to talk"
                : "Press Control-Shift-D, or click, to start and stop"
            let end = prefs.finish == .send ? "the message is sent when you stop" : "the words go into the message for you to review"
            return "\(start); \(end). Escape cancels."
        }
    }
}

/// The line above the composer's buttons: "Listening… <the newest words>",
/// "Finishing…", or a short note. Muted, at most two lines, the start of a
/// long partial cut rather than its end. Only in the window dictating.
struct DictationPreview: View {
    let browser: Browser
    @ObservedObject private var voice = Voice.shared
    @ObservedObject private var prefs = VoicePrefs.shared
    @State private var width: CGFloat = 300

    var body: some View {
        if prefs.enabled, VoicePrefs.supported, voice.shows(in: browser), let line = voice.line {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                words(line)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                if closable {
                    Button { voice.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(voice.active ? "Cancel dictation (Esc)" : "Dismiss")
                    .accessibilityLabel(voice.active ? "Cancel dictation" : "Dismiss")
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
        }
    }

    private var closable: Bool {
        if voice.active { return true }
        if case .error = voice.phase { return true }
        return false
    }

    @ViewBuilder
    private func words(_ line: Voice.Line) -> some View {
        switch line {
        case .live(let lead, let heard):
            // The partial is a guess that changes; VoiceOver hears the state, not it.
            Text(DictationPreview.fitted(lead, heard, width: width))
                .accessibilityLabel(lead == "Listening…" ? "Listening" : lead == "Finishing…" ? "Finishing" : "Finishing, preparing speech model")
        case .plain(let text):
            Text(text)
        case .denied:
            Text(DictationPreview.denied).tint(Palette.ink)
        }
    }

    /// Voice.denied, with "Open System Settings" a link to the Microphone list.
    static var denied: AttributedString {
        var link = AttributedString("Open System Settings")
        link.link = URL(string: Voice.privacyPane)
        link.underlineStyle = .single
        return AttributedString("Microphone access is off. ") + link + AttributedString(" to allow Copper, then try again.")
    }

    /// `lead`, then as many of the last words of `heard` as fit in two lines
    /// of `width`. Where the start was cut nothing marks it: "Listening…"
    /// already ends in an ellipsis, and a second one only stutters.
    static func fitted(_ lead: String, _ heard: String, width: CGFloat, lines: Int = 2) -> String {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return lead }
        let usable = max(width - 6, 60)
        let font = NSFont.systemFont(ofSize: 12)
        let height = ceil(font.ascender - font.descender + font.leading) * CGFloat(lines) + 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ candidate: String) -> Bool {
            let box = (candidate as NSString).boundingRect(with: NSSize(width: usable, height: .greatestFiniteMagnitude),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            return box.height <= height
        }
        let whole = "\(lead) \(text)"
        if fits(whole) { return whole }
        let parts = text.split(whereSeparator: \.isWhitespace)
        var low = 0, high = parts.count
        while low < high {
            let mid = (low + high + 1) / 2
            if fits("\(lead) \(parts.suffix(mid).joined(separator: " "))") { low = mid } else { high = mid - 1 }
        }
        return low == 0 ? lead : "\(lead) \(parts.suffix(low).joined(separator: " "))"
    }
}
