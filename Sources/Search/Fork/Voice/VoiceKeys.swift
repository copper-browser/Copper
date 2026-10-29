import AppKit

// ⌃⇧D, and Escape while dictating — and nothing else, and only where voice
// lives: a browser window whose agent pane is open, with Settings › Intelligence › Voice on.
// Anywhere else the keys go on untouched (with voice off, every key does).
//
// Where an addon owns the Agent sidebar, its composer is the one on screen:
// ⌃⇧D dictates into it (AddonVoice.keyTarget) once its page has asked for
// voice, and goes on to the page when it never has. Where its page couldn't
// be shown, the pane is back, and so is its composer.
//
// Hold to talk: D down starts, D up — or ⌃ or ⇧ let go — ends. Press to
// start and stop: each D down is one press. The chord's own key events are
// kept from the page and the composer either way, so no "D" is typed, and a
// key held long enough to repeat repeats nothing.
//
// Escape cancels a dictation before anything else hears it: ContentView's
// key handler asks here first (App.swift `take`), and this monitor's own
// look at it covers whichever of the two AppKit calls first.

@MainActor
enum VoiceKeys {
    private static var monitor: Any?
    /// ⌃⇧D went down here and its D hasn't come up.
    private static var down = false
    /// Chord presses taken, and chord presses let through (pane closed, not a
    /// browser window). Counts only, for the bench.
    private(set) static var consumed = 0
    private(set) static var passed = 0
    /// The last press counted as let through: one press reaches this from
    /// two monitors, and again when a page hands it back unused.
    private static var counted: (TimeInterval, UInt16)?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            take(event) ? nil : event
        }
    }

    /// True when the event was voice's, and is used up.
    static func take(_ event: NSEvent) -> Bool {
        guard VoicePrefs.supported, VoicePrefs.shared.enabled else { return false }
        let voice = Voice.shared
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                guard voice.active, voice.owns(event.window) else { return false }
                voice.cancel("escape")
                return true
            }
            guard chord(event) else { return false }
            let browser = Agent.shared.open ? Windows.owner(of: event.window) : nil
            let target = browser.map(AddonVoice.keyTarget(in:)) ?? .neither
            guard let browser, !target.isNeither else {
                if counted.map({ $0.0 != event.timestamp || $0.1 != event.keyCode }) ?? true {
                    counted = (event.timestamp, event.keyCode)
                    passed += 1
                }
                return false
            }
            consumed += 1
            if event.isARepeat { return true }
            down = true
            voice.press(.key, in: browser, window: event.window, for: target.sink)
            return true
        case .keyUp:
            guard down, isD(event) else { return false }
            down = false
            voice.lift(.key)
            return true
        case .flagsChanged:
            // Letting go of ⌃ or ⇧ ends a hold as surely as letting go of D.
            if down {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !flags.contains(.control) || !flags.contains(.shift) {
                    down = false
                    voice.lift(.key)
                }
            }
            return false
        default:
            return false
        }
    }

    /// ⌃⇧D exactly: no ⌘, no ⌥.
    static func chord(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return flags == [.control, .shift] && isD(event)
    }

    /// The D key. On a layout that types Latin letters (QWERTY, AZERTY,
    /// Dvorak…) it is the key that types a d, wherever it sits; on one that
    /// doesn't (Russian, Greek, Hebrew, Arabic…) it is the key in D's place on
    /// a US keyboard (kVK_ANSI_D). Never "either": on Dvorak D's US place
    /// types an e, and ⌃⇧E is a Copper shortcut of its own.
    static func isD(_ event: NSEvent) -> Bool {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.unicodeScalars.count == 1,
           let scalar = typed.unicodeScalars.first, scalar.isASCII, scalar.properties.isAlphabetic {
            return typed == "d"
        }
        return event.keyCode == 2
    }
}
