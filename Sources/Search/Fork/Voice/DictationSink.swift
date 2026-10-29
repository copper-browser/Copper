import Foundation

// Where a dictation's words go. For a long time there was one place: the
// ⌘E pane's composer, where the words land at the caret (ComposerInsert)
// and, with "Send right away", are sent. An addon that owns the Agent
// sidebar draws a composer of its own, which Copper can't reach into, so it
// takes the words as a sink: the partials as a preview, the final words
// once, and anything that went wrong as one line. What the sink does with
// them — the caret, the draft, the send — is its own business. The native
// draft is never touched for a sink, and Copper never sends for one.
//
// A dictation is for one of the two from its press to its end: a press for
// the other leaves it alone, and what it hears never changes hands.

/// Someone who draws their own composer and takes dictated words from Voice.
@MainActor
protocol DictationSink: AnyObject {
    /// The newest partial words: a guess that changes, for a preview only.
    func dictation(partial text: String)
    /// The finished words, never empty, and what Settings › Intelligence ›
    /// Voice says should happen to them. Said once per dictation.
    func dictation(final text: String, finish: VoiceFinish)
    /// What the composer's line would have said instead of listening: the
    /// microphone off or gone, the model not ready, a tap too short to be a
    /// hold. `code` is short and stable; `message` is for a person.
    func dictation(error code: String, message: String)
}

extension Voice {
    /// Who a dictation is for.
    enum Target: String, Equatable {
        /// The pane's own composer: ComposerInsert at the caret, then Send if asked.
        case composer
        /// A DictationSink: the words handed over, never into the draft.
        case sink
    }

    /// The short code a sink hears for one of Voice's messages.
    nonisolated static func code(for message: String) -> String {
        switch message {
        case Voice.denied: return "mic_denied"
        case Voice.loadFailed: return "model_failed"
        case Voice.preparingNote, Voice.preparingHelp, "Speech model needs attention": return "not_ready"
        case Listen.blocksDictation: return "busy"
        case "Hold to talk", Voice.allowedHoldKey, Voice.allowedHoldButton: return "hold"
        case "Dictation isn't available in headless Copper", "The microphone is off in test worlds", "Voice needs macOS 15 or later.":
            return "unavailable"
        default: return "mic_failed"
        }
    }
}
