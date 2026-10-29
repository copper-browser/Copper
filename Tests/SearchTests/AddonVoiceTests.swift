import Foundation
import Testing
@testable import Search

// `copper.voice` (Fork/Addons/AddonVoice.swift, docs/addons.md › Voice): the
// sidebar addon's dictation. The rules — which capability, what
// `voice.state()` says, why `voice.start()` is refused — are pure and checked
// here against every state the mic can be in. Then the one guarantee that
// matters most, on the real Voice session: words dictated for the addon are
// handed to it and never written into the native composer's draft, while a
// dictation for the composer still lands in the draft exactly as before.
// No microphone, no speech model, no window.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A slot that writes down what it hears.
@MainActor
private final class Recording: VoiceSlot {
    var browser: Browser? { nil }
    var asked = 0
    var acted = 0
    var partials: [String] = []
    var finals: [(text: String, finish: VoiceFinish)] = []
    var errors: [(code: String, message: String)] = []

    func voiceAsked() { asked += 1 }
    func voiceActed() { acted += 1 }
    func dictation(partial text: String) { partials.append(text) }
    func dictation(final text: String, finish: VoiceFinish) { finals.append((text, finish)) }
    func dictation(error code: String, message: String) { errors.append((code, message)) }
}

@MainActor
private func snapshot(_ mic: Voice.Mic, available: Bool = true, enabled: Bool = true, active: Bool = false,
                      finishing: Bool = false, trigger: VoiceTrigger = .hold, finish: VoiceFinish = .insert) -> AddonVoice.Snapshot {
    AddonVoice.Snapshot(available: available, enabled: enabled, mic: mic, trigger: trigger, finish: finish,
                        active: active, finishing: finishing)
}

private func code(_ work: () throws -> Any) -> String? {
    do {
        _ = try work()
        return nil
    } catch let problem as AddonBridgeError {
        return problem.code
    } catch {
        return "other"
    }
}

@Suite struct AddonVoiceRulesTests {
    @Test func theShimHasTheVoiceNamespaceFrozen() throws {
        let text = try String(contentsOf: repo.appendingPathComponent("Sources/Search/Fork/Addons/Resources/bridge.js"), encoding: .utf8)
        for method in ["voice.state", "voice.start", "voice.stop", "voice.cancel"] {
            #expect(text.contains("call(\"\(method)\")"), "\(method)")
        }
        #expect(text.contains("Object.freeze(copper.voice);"))
        // The header every platform's copy carries is still the first line.
        #expect(text.hasPrefix("// Copper addon bridge, v1. CANONICAL COPY"))
    }

    @MainActor @Test func everyMethodNeedsTheAgentCapability() {
        let slot = Recording()
        let others: Set<AddonCapability> = Set(AddonCapability.allCases).subtracting([.agent])
        for method in AddonVoice.methods.sorted() {
            #expect(code { try AddonVoice.call(method, granted: others, slot: slot) } == "denied", "\(method)")
            #expect(code { try AddonVoice.call(method, granted: [], slot: slot) } == "denied", "\(method)")
        }
        // Refused before anything is looked at: a page without the capability
        // is never taken for one that draws a mic.
        #expect(slot.asked == 0)
        #expect(code { try AddonVoice.call("voice.listen", granted: [.agent], slot: slot) } == "bad_request")
    }

    @MainActor @Test func stopAndCancelWithNothingUnderWayAreFine() throws {
        let slot = Recording()
        for method in ["voice.stop", "voice.cancel"] {
            let answer = try AddonVoice.call(method, granted: [.agent], slot: slot) as? [String: Any]
            #expect(answer?["ok"] as? Bool == true, "\(method)")
        }
        #expect(slot.asked == 2, "a voice call marks the page as one that dictates")
        #expect(slot.acted == 2, "a state event is owed after each")
        #expect(slot.finals.isEmpty && slot.errors.isEmpty && slot.partials.isEmpty)
    }

    @MainActor @Test func stateHasTheContractsShape() throws {
        let keys: Set<String> = ["available", "enabled", "mic", "reason", "trigger", "finish", "active", "phase"]
        let idle = AddonVoice.state(snapshot(.ready))
        #expect(Set(idle.keys) == keys)
        #expect(idle["available"] as? Bool == true && idle["enabled"] as? Bool == true)
        #expect(idle["mic"] as? String == "ready" && idle["reason"] is NSNull)
        #expect(idle["trigger"] as? String == "hold" && idle["finish"] as? String == "insert")
        #expect(idle["active"] as? Bool == false && idle["phase"] as? String == "idle")
        #expect(JSONSerialization.isValidJSONObject(idle))

        let toggled = AddonVoice.state(snapshot(.ready, trigger: .toggle, finish: .send))
        #expect(toggled["trigger"] as? String == "toggle" && toggled["finish"] as? String == "send")

        let dictating = AddonVoice.state(snapshot(.ready, active: true))
        #expect(dictating["active"] as? Bool == true && dictating["phase"] as? String == "dictating")
        let finishing = AddonVoice.state(snapshot(.ready, active: true, finishing: true))
        #expect(finishing["phase"] as? String == "finishing")

        let off = AddonVoice.state(snapshot(.hidden, enabled: false))
        #expect(off["mic"] as? String == "hidden" && off["enabled"] as? Bool == false && off["reason"] is NSNull)
        let old = AddonVoice.state(snapshot(.hidden, available: false, enabled: false))
        #expect(old["available"] as? Bool == false)

        let waiting = AddonVoice.state(snapshot(.waiting("Speech model downloading · 42%")))
        #expect(waiting["mic"] as? String == "waiting" && waiting["reason"] as? String == "Speech model downloading · 42%")
        let listening = AddonVoice.state(snapshot(.unavailable(Listen.blocksDictation)))
        #expect(listening["mic"] as? String == "unavailable" && listening["reason"] as? String == Listen.blocksDictation)
        let preparing = AddonVoice.state(snapshot(.preparing))
        #expect(preparing["mic"] as? String == "preparing" && preparing["reason"] as? String == Voice.preparingHelp)

        let event = AddonVoice.stateEvent(snapshot(.ready))
        #expect(event["type"] as? String == "state" && Set(event.keys) == keys.union(["type"]))
    }

    @MainActor @Test func startIsRefusedWithTheContractsCodes() {
        #expect(AddonVoice.refusal(snapshot(.hidden, available: false, enabled: false))?.error.code == "disabled")
        #expect(AddonVoice.refusal(snapshot(.hidden, enabled: false))?.error.code == "disabled")
        #expect(AddonVoice.refusal(snapshot(.hidden, enabled: false))?.opensSettings == false)

        let listen = AddonVoice.refusal(snapshot(.unavailable(Listen.blocksDictation)))
        #expect(listen == AddonVoice.Refusal(error: AddonBridgeError("busy", Listen.blocksDictation)))
        #expect(AddonVoice.refusal(snapshot(.unavailable(AddonVoice.elsewhere)))?.error.code == "busy")

        // The model not ready: Settings › Intelligence › Voice opens, as the pane's mic opens it.
        let waiting = AddonVoice.refusal(snapshot(.waiting("Set up voice in Settings")))
        #expect(waiting == AddonVoice.Refusal(error: AddonBridgeError("not_ready", "Set up voice in Settings"), opensSettings: true))
        // Being prepared on this Mac: a moment's wait, not a trip to Settings.
        let preparing = AddonVoice.refusal(snapshot(.preparing))
        #expect(preparing == AddonVoice.Refusal(error: AddonBridgeError("not_ready", Voice.preparingNote)))

        #expect(AddonVoice.refusal(snapshot(.ready)) == nil)
        // Its own dictation already under way: start is done, not refused.
        #expect(AddonVoice.refusal(snapshot(.ready, active: true)) == nil)
    }

    @MainActor @Test func errorsHaveShortCodes() {
        #expect(Voice.code(for: Voice.denied) == "mic_denied")
        #expect(Voice.code(for: Voice.loadFailed) == "model_failed")
        #expect(Voice.code(for: "Hold to talk") == "hold")
        #expect(Voice.code(for: Voice.allowedHoldButton) == "hold")
        #expect(Voice.code(for: Listen.blocksDictation) == "busy")
        #expect(Voice.code(for: Voice.preparingNote) == "not_ready")
        #expect(Voice.code(for: "Dictation isn't available in headless Copper") == "unavailable")
        #expect(Voice.code(for: "The microphone is off in test worlds") == "unavailable")
        #expect(Voice.code(for: "The microphone was disconnected — try again") == "mic_failed")
        #expect(Voice.code(for: Voice.words(for: VoiceCaptureError.noInput)) == "mic_failed")
    }
}

/// The real Voice session and the real agent draft, one test at a time.
@Suite(.serialized) struct AddonVoiceRoutingTests {
    @MainActor @Test func wordsForTheAddonNeverTouchTheDraft() {
        let voice = Voice.shared
        let agent = Agent.shared
        let saved = agent.draft
        defer { agent.draft = saved }
        agent.draft = "Keep this."
        let slot = Recording()

        voice.benchLand("  open the logs  ", for: slot)
        #expect(agent.draft == "Keep this.", "the native draft is untouched")
        #expect(slot.finals.count == 1)
        #expect(slot.finals.first?.text == "open the logs")
        #expect(slot.finals.first?.finish == VoicePrefs.shared.finish, "the person's setting goes with the words; the addon sends")
        #expect(voice.phase == .idle && !voice.active)
        #expect(voice.target == .sink && voice.aimed(at: slot) && !voice.aimed(at: nil))
        #expect(voice.lastInsert == nil && voice.lastSent == nil && voice.lastDelivered == "open the logs")
        #expect(voice.timeline.contains { $0.event == "delivered" })
        #expect(!voice.timeline.contains { $0.event == "inserted" || $0.event == "sent" })

        // Even "Send right away" with an agent ready to take it: nothing is sent from here.
        voice.benchLand("and file a bug", for: slot, sendReady: true)
        #expect(agent.draft == "Keep this.")
        #expect(voice.lastSent == nil)
        #expect(slot.finals.map(\.text) == ["open the logs", "and file a bug"])
    }

    @MainActor @Test func nothingHeardHandsNothingOver() {
        let agent = Agent.shared
        let saved = agent.draft
        defer { agent.draft = saved }
        agent.draft = "Draft"
        let slot = Recording()
        Voice.shared.benchLand("   ", for: slot)
        // No final: an addon set to send must not send its draft for silence.
        #expect(slot.finals.isEmpty && slot.errors.isEmpty)
        #expect(agent.draft == "Draft")
        #expect(Voice.shared.timeline.contains { $0.event == "empty" })
    }

    @MainActor @Test func theComposerStillGetsItsOwnWords() {
        let voice = Voice.shared
        let agent = Agent.shared
        let saved = agent.draft
        defer { agent.draft = saved }
        let slot = Recording()
        // A dictation for the addon first, so the composer's has to take its place back.
        voice.benchLand("for the addon", for: slot)

        agent.draft = "Note:"
        voice.benchLand("check the build", for: nil)
        #expect(agent.draft == "Note: check the build")
        #expect(voice.lastInsert?.piece == " check the build" && voice.lastInsert?.via == "draft")
        #expect(voice.target == .composer && voice.aimed(at: nil) && !voice.aimed(at: slot))
        #expect(slot.finals.map(\.text) == ["for the addon"], "the addon hears nothing of the composer's dictation")

        // At a caret mid-draft, spaced as ever.
        agent.draft = "Check build"
        voice.benchLand("the", for: nil, range: NSRange(location: 6, length: 0))
        #expect(agent.draft == "Check the build")
    }

    @MainActor @Test func stopAndCancelLeaveOtherDictationsAlone() {
        let voice = Voice.shared
        let slot = Recording()
        let other = Recording()
        voice.benchLand("words", for: slot)
        let session = voice.session
        voice.stop(for: other)
        voice.cancel(for: other)
        voice.stop(for: slot)
        voice.cancel(for: slot)
        #expect(voice.session == session, "nothing under way: nothing cancelled")
        #expect(!voice.serves(slot) && !voice.serves(other))
        #expect(other.finals.isEmpty && other.errors.isEmpty)
    }
}
