import Foundation

// Voice's three choices, kept with every other setting in `Store.settings`
// (a probe world's own suite, never the real browser's): whether voice is on,
// how a dictation is started, and what happens to the words when it stops.
// Settings › Intelligence › Voice draws them (VoiceSettings.swift); the agent pane reads them.

/// How a dictation is started and stopped.
enum VoiceTrigger: String, CaseIterable, Sendable {
    /// Talk while the key (or the mic button) is held down.
    case hold
    /// One press starts, the next one stops.
    case toggle

    var title: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Press to start and stop"
        }
    }
}

/// What happens to the words when a dictation stops.
enum VoiceFinish: String, CaseIterable, Sendable {
    /// Into the composer at the caret, for a read before sending.
    case insert
    /// Into the composer and sent at once: a conversation.
    case send

    var title: String {
        switch self {
        case .insert: return "Insert into the message"
        case .send: return "Send right away"
        }
    }
}

@MainActor
final class VoicePrefs: ObservableObject {
    static let shared = VoicePrefs()

    /// Off until someone turns it on. Turning it on gets the speech model if
    /// it isn't here yet; turning it off stops a download in flight (what
    /// arrived is kept to resume) and never deletes a model.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            Store.settings.set(enabled, forKey: VoicePrefs.enabledKey)
            ModelStore.shared.voiceTurned(on: enabled)
        }
    }

    @Published var trigger: VoiceTrigger {
        didSet { Store.settings.set(trigger.rawValue, forKey: VoicePrefs.triggerKey) }
    }

    @Published var finish: VoiceFinish {
        didSet { Store.settings.set(finish.rawValue, forKey: VoicePrefs.finishKey) }
    }

    /// Agents on this Mac (the MCP server's `voice_transcript`, `copper
    /// transcript`) may read the Listen transcript. Off until the person turns
    /// it on; it never lets an agent start Listen or hear audio, and a linked
    /// bot never reads it either way (Fork/MCP/VoiceTools.swift).
    @Published var shareTranscript: Bool {
        didSet {
            guard shareTranscript != oldValue else { return }
            Store.settings.set(shareTranscript, forKey: VoicePrefs.shareTranscriptKey)
        }
    }

    /// The Core ML model is multifunction (one encoder per window length),
    /// which only macOS 15 can load. On 14 voice stays off and says why.
    static var supported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    static let enabledKey = "voice.enabled"
    static let triggerKey = "voice.trigger"
    static let finishKey = "voice.finish"
    static let shareTranscriptKey = "voice.shareTranscript"

    private init() {
        let store = Store.settings
        enabled = VoicePrefs.supported && store.bool(forKey: VoicePrefs.enabledKey)
        trigger = store.string(forKey: VoicePrefs.triggerKey).flatMap(VoiceTrigger.init(rawValue:)) ?? .hold
        finish = store.string(forKey: VoicePrefs.finishKey).flatMap(VoiceFinish.init(rawValue:)) ?? .insert
        shareTranscript = store.bool(forKey: VoicePrefs.shareTranscriptKey)
    }
}
