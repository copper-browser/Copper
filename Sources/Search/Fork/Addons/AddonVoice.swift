import AppKit

// `copper.voice`: Copper's dictation, lent to the addon in the Agent sidebar.
//
// While an addon owns the sidebar, the native agent pane — its composer,
// the mic in it, the line under it — isn't on screen, and the person would
// have lost speech to text. So the addon draws a mic in its own composer
// and asks Copper to listen: the same Voice session, the same model, the
// same Settings › Intelligence › Voice, the same ⌃⇧D. The words come back as
// `voice` events — partials for a preview, the final words once — and the
// addon puts them at its own caret and, with "Send right away", sends its
// own draft. Copper never writes the native draft for it and never sends
// for it (DictationSink.swift).
//
// The four methods need the "agent" capability. A capability of their own
// would fail manifest validation on every Copper that doesn't know it; a
// Copper that doesn't know `voice.*` answers bad_request instead, and the
// addon leaves its mic out.
//
// ⌃⇧D goes to the addon only once its page has asked for voice (any
// `voice.*` call since it loaded): an addon that never did draws no mic, and
// a dictation nobody shows would only hear the room. Its key then goes on to
// the page, as with voice off.

/// The addon side of a dictation: a sink with a window, which says when its
/// page has shown it draws a mic.
@MainActor
protocol VoiceSlot: DictationSink {
    var browser: Browser? { get }
    /// The page called a `voice.*` method.
    func voiceAsked()
    /// The page started, stopped or cancelled one: a `state` event follows
    /// even when what it says ends up as it was (a start and a cancel inside
    /// one beat), so the page never waits on one.
    func voiceActed()
}

@MainActor
enum AddonVoice {
    static let methods: Set<String> = ["voice.state", "voice.start", "voice.stop", "voice.cancel"]
    /// The mic's reason while a dictation for another composer (another
    /// window's, or the pane's) is under way.
    nonisolated static let elsewhere = "Finish the other dictation first"
    nonisolated static let off = "Voice is off — turn it on in Settings › Intelligence › Voice"
    nonisolated static let unsupported = "Voice needs macOS 15 or later"

    /// Everything `voice.state()` says, read at one moment.
    struct Snapshot: Equatable {
        /// This Copper on this Mac can dictate at all.
        var available: Bool
        /// Settings › Intelligence › Voice is on.
        var enabled: Bool
        /// As the pane's mic would show, for a composer that needs no agent
        /// of Copper's — and `unavailable` while another composer dictates.
        var mic: Voice.Mic
        var trigger: VoiceTrigger
        var finish: VoiceFinish
        /// A dictation for this slot is under way…
        var active: Bool
        /// …and has been let go: the last decode is running.
        var finishing: Bool
    }

    /// The state for `slot`, now.
    static func snapshot(for slot: DictationSink) -> Snapshot {
        let voice = Voice.shared
        let prefs = VoicePrefs.shared
        let mine = voice.serves(slot)
        var mic = voice.mic(agentReady: true)
        if !mine, voice.active, mic != .hidden, mic != .unavailable(Listen.blocksDictation) {
            mic = .unavailable(elsewhere)
        }
        return Snapshot(available: VoicePrefs.supported, enabled: VoicePrefs.supported && prefs.enabled, mic: mic,
                        trigger: prefs.trigger, finish: prefs.finish, active: mine, finishing: mine && voice.phase == .finishing)
    }

    /// `voice.state()`, and every `state` event without its `type`.
    static func state(_ now: Snapshot) -> [String: Any] {
        let (mic, reason) = words(now.mic)
        return [
            "available": now.available,
            "enabled": now.enabled,
            "mic": mic,
            "reason": reason.map { $0 as Any } ?? NSNull(),
            "trigger": now.trigger.rawValue,
            "finish": now.finish.rawValue,
            "active": now.active,
            "phase": !now.active ? "idle" : now.finishing ? "finishing" : "dictating",
        ]
    }

    /// The mic as the contract names it, with why when it can't listen.
    static func words(_ mic: Voice.Mic) -> (String, String?) {
        switch mic {
        case .hidden: return ("hidden", nil)
        case .unavailable(let why): return ("unavailable", why)
        case .waiting(let why): return ("waiting", why)
        case .preparing: return ("preparing", Voice.preparingHelp)
        case .ready: return ("ready", nil)
        }
    }

    /// Why `voice.start()` can't start now, if it can't. `opensSettings`:
    /// the model isn't ready, and — as the pane's mic does — Settings ›
    /// Intelligence › Voice opens where it can be set up.
    struct Refusal: Equatable {
        var error: AddonBridgeError
        var opensSettings = false
    }

    static func refusal(_ now: Snapshot) -> Refusal? {
        guard now.available else { return Refusal(error: AddonBridgeError("disabled", unsupported)) }
        guard now.enabled else { return Refusal(error: AddonBridgeError("disabled", off)) }
        // Its own dictation already under way: starting it is done.
        if now.active { return nil }
        switch now.mic {
        case .hidden: return Refusal(error: AddonBridgeError("disabled", off))
        case .unavailable(let why): return Refusal(error: AddonBridgeError("busy", why))
        case .waiting(let why): return Refusal(error: AddonBridgeError("not_ready", why), opensSettings: true)
        case .preparing: return Refusal(error: AddonBridgeError("not_ready", Voice.preparingNote))
        case .ready: return nil
        }
    }

    /// One `voice.*` call from `slot`'s page.
    static func call(_ method: String, granted: Set<AddonCapability>, slot: VoiceSlot) throws -> Any {
        guard methods.contains(method) else { throw AddonBridgeError("bad_request", "No bridge method \"\(method)\"") }
        guard granted.contains(.agent) else {
            throw AddonBridgeError("denied", "\(method) needs the \"\(AddonCapability.agent.rawValue)\" capability in manifest.json")
        }
        slot.voiceAsked()
        let voice = Voice.shared
        let ok: [String: Any] = ["ok": true]
        switch method {
        case "voice.state":
            return state(snapshot(for: slot))
        case "voice.start":
            let now = snapshot(for: slot)
            if let refused = refusal(now) {
                if refused.opensSettings { slot.browser?.openSettings(.intelligence, at: "voice.enabled") }
                throw refused.error
            }
            if now.active { return ok }
            guard let browser = slot.browser else { throw AddonBridgeError("unavailable", "The window is gone") }
            voice.begin(for: slot, in: browser, window: Windows.window(of: browser))
            slot.voiceActed()
            return ok
        case "voice.stop":
            voice.stop(for: slot)
            slot.voiceActed()
            return ok
        default:
            voice.cancel(for: slot)
            slot.voiceActed()
            return ok
        }
    }

    /// The `voice` event that carries `state`.
    static func stateEvent(_ now: Snapshot) -> [String: Any] {
        var event = state(now)
        event["type"] = "state"
        return event
    }

    // MARK: - ⌃⇧D

    /// Whose composer ⌃⇧D dictates into in a window whose sidebar is open.
    enum KeyTarget {
        /// The native pane's: no addon there, or its page couldn't be shown.
        case composer
        /// The addon's, which has asked for voice.
        case addon(AddonSlotHost)
        /// Neither: the addon owns the sidebar but draws no mic. The key goes on.
        case neither

        var isNeither: Bool {
            if case .neither = self { return true }
            return false
        }

        /// Who a press is for: nil being the pane's composer.
        var sink: DictationSink? {
            if case .addon(let host) = self { return host }
            return nil
        }
    }

    static func keyTarget(in browser: Browser) -> KeyTarget {
        guard AddonSync.shared.active(.agentSidebar) != nil else { return .composer }
        // The slot not drawn in this window yet, which an open sidebar always
        // is: nothing on screen to dictate into.
        guard let host = AddonSlotHost.existing(for: browser, slot: .agentSidebar) else { return .neither }
        if host.failed != nil { return .composer }
        guard host.entry?.granted.contains(.agent) == true, host.voiceAware else { return .neither }
        return .addon(host)
    }

    /// The sidebar's addon dictates, so the speech model is loaded when the
    /// sidebar opens even with no agent of Copper's set up (Voice.warm).
    static var wantsWarm: Bool {
        guard AddonSync.shared.active(.agentSidebar) != nil else { return false }
        return AddonSlotHost.voiceAwareHosts
    }
}
