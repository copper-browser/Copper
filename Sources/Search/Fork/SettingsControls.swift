import AppKit
import SwiftUI

// Settings' own controls — `Switch`, `Segmented`, `Pill` (Settings.swift) —
// as the keyboard and VoiceOver meet them (settings-a11y).
//
// They are drawn shapes, not AppKit controls, so they used to be invisible
// to both: a tap gesture on a capsule has no role, no name and no focus.
// Now each is one accessibility element with a role (a switch, a group of
// choices, a button), a name — the title of the `Line` it sits in, handed
// down through `controlLabel`, or one given where it is made — and a value,
// and each takes the keyboard the way the Mac's own controls do: reached
// with Tab when Keyboard navigation is on in System Settings, Space or
// Return to flip a switch or press a pill, ← → to move along a row of
// choices. The ring that shows where the keyboard is follows the control's
// own shape, in ink, like everything else in Settings.

private struct ControlLabelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct SettingsPageNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The name of the row a control sits in, for VoiceOver: `Line` sets
    /// it to its title, so a `Switch` or `Segmented` inside it is called
    /// what the row is called.
    var controlLabel: String? {
        get { self[ControlLabelKey.self] }
        set { self[ControlLabelKey.self] = newValue }
    }

    /// The Settings page a control is drawn on, for the bench's ledger
    /// (`SettingsControlLedger`) — so a page fading out isn't counted on
    /// the next one.
    var settingsPageName: String? {
        get { self[SettingsPageNameKey.self] }
        set { self[SettingsPageNameKey.self] = newValue }
    }
}

/// The keyboard's ring around a focused control: the control's own shape,
/// a little outside it, in the accent. Nothing at all while it isn't focused.
struct SettingsFocusRing<S: InsettableShape>: ViewModifier {
    let on: Bool
    let shape: S

    func body(content: Content) -> some View {
        content.overlay {
            shape
                .inset(by: -3)
                .strokeBorder(Palette.accent, lineWidth: 1.75) // Fork (ui-system): the accent marks where the keyboard is
                .opacity(on ? 1 : 0)
                .animation(Motion.quick, value: on)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Reached by Tab (with Keyboard navigation on), wearing Settings' ring
    /// rather than the system's blue halo.
    func settingsFocusable<S: InsettableShape>(_ focus: FocusState<Bool>.Binding, enabled: Bool = true, shape: S) -> some View {
        self
            .focusable(enabled, interactions: .activate)
            .focused(focus)
            .focusEffectDisabled()
            .modifier(SettingsFocusRing(on: focus.wrappedValue, shape: shape))
    }

    /// For a `Button`, which is focusable already: only the ring.
    func settingsFocusRing<S: InsettableShape>(_ focus: FocusState<Bool>.Binding, shape: S) -> some View {
        self
            .focused(focus)
            .focusEffectDisabled()
            .modifier(SettingsFocusRing(on: focus.wrappedValue, shape: shape))
    }
}

// Text fields' ground and focus edge: Fork/SettingsField.swift (SB-04).

/// The plain rules behind the controls, apart from SwiftUI so they can be
/// tested.
enum SettingsControlRules {
    /// What VoiceOver calls a control: the name it was given where it was
    /// made, else the row's title, else nothing.
    static func name(given: String?, row: String?) -> String {
        if let given, !given.isEmpty { return given }
        return row ?? ""
    }

    /// ← → along a row of `count` choices from `index`: one step, stopping
    /// at the ends rather than wrapping, as the Mac's segmented controls do.
    /// Nil when there is nowhere to go.
    static func step(from index: Int?, by: Int, count: Int) -> Int? {
        guard let index, count > 0 else { return nil }
        let next = min(count - 1, max(0, index + by))
        return next == index ? nil : next
    }

    /// Whether a key closes Settings rather than reaching the page or the
    /// tab behind it: ⌘W, with no other modifier.
    static func closes(key: String, flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) && key.lowercased() == "w"
            && flags.isDisjoint(with: [.shift, .option, .control])
    }
}

// MARK: - what each control says about itself (test runs)

/// What every `Switch`, `Segmented`, `Pill` and `Quick` drawn on a Settings
/// page hands to VoiceOver and the keyboard, as it draws — the same name,
/// value and role it passes to `.accessibilityLabel`/`Value`/traits, and
/// whether Tab can reach it. Kept only in a test run, for `bench settings ax
/// sweep`: SwiftUI builds its accessibility tree only for a real
/// accessibility client, so a probe with none asks the controls instead.
@MainActor
enum SettingsControlLedger {
    struct Entry: Hashable {
        let page: String
        let kind: String
        let name: String
        let value: String
        let keyboard: Bool
        let disabled: Bool
    }

    private(set) static var drawn: [Entry] = []
    private static var seen: Set<Entry> = []
    /// The control the keyboard is on, as it last drew itself focused.
    private(set) static var focused: Entry?
    /// Asked once: every control asks on every draw.
    private static let kept = Store.testing

    static func note(_ kind: String, page: String?, name: String, value: String = "", keyboard: Bool,
                     disabled: Bool = false, focused now: Bool = false) {
        guard kept, let page else { return }
        let entry = Entry(page: page, kind: kind, name: name, value: value, keyboard: keyboard, disabled: disabled)
        if seen.insert(entry).inserted { drawn.append(entry) }
        if now {
            focused = entry
        } else if focused?.kind == kind, focused?.name == name, focused?.page == page {
            focused = nil
        }
    }

    /// `focused`, for the bench.
    static var describeFocus: Any {
        guard let entry = focused else { return NSNull() }
        return ["page": entry.page, "kind": entry.kind, "name": entry.name, "value": entry.value]
    }

    static func reset() {
        drawn = []
        seen = []
    }
}

// MARK: - confirmations in a test run (X-13)

/// A question Settings asks before something it can't take back — delete a
/// space, remove an extension, a new token, clear history, sign out — and a
/// way for the bench to answer it in a test run.
///
/// For a person nothing changes: the sheet goes up on the window as it
/// always did. A headless test run has nobody to see a sheet and used to
/// decline every one on the spot (Headless.swift), so what a button does
/// could never be proven there. Now, in a test run, the question waits:
/// `bench settings confirm` reads it, and `bench settings confirm answer
/// TITLE` presses that button — through the sheet's own button when one is
/// up (a windowed test run), else by handing its answer straight back.
@MainActor
enum TestConfirm {
    struct Question {
        let kind: String
        let message: String
        let detail: String
        let buttons: [String]
        /// Presses button `index`.
        let press: (Int) -> Void
    }

    /// The question up now, if any.
    private(set) static var waiting: Question?
    /// What the last answered question was, and which button answered it.
    private(set) static var last: [String: Any] = [:]

    /// A test run with nobody to see a sheet: questions wait for the bench
    /// rather than being put on a window parked off every screen.
    static var holds: Bool { Store.testing && Headless.on }

    /// Asks with `alert`: a sheet on `window` (app-modal with no window
    /// shown), or held for the bench in a headless test run. `decide` gets
    /// the button's response either way.
    static func present(_ alert: NSAlert, kind: String, window: NSWindow?,
                        decide: @escaping (NSApplication.ModalResponse) -> Void) {
        let buttons = alert.buttons.map(\.title)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if waiting?.kind == kind { waiting = nil }
            decide(response)
        }
        if holds {
            waiting = Question(kind: kind, message: alert.messageText, detail: alert.informativeText, buttons: buttons) { index in
                finish(response(for: index))
            }
            Headless.log("held \(kind) for the bench: \(said(alert))")
            return
        }
        if Store.testing {
            waiting = Question(kind: kind, message: alert.messageText, detail: alert.informativeText, buttons: buttons) { index in
                guard alert.buttons.indices.contains(index) else { return }
                alert.buttons[index].performClick(nil)
            }
        }
        DispatchQueue.main.async {
            if let window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }
    }

    /// Headless.swift's hook: an alert sheet nobody here put up with
    /// `present` — a SwiftUI confirmation dialog on a Settings page — held
    /// for the bench instead of declined, while Settings is open in a test
    /// run. False leaves it to be declined as before.
    static func adopt(_ alert: NSAlert, done: @escaping (NSApplication.ModalResponse) -> Void) -> Bool {
        guard holds, Windows.all.contains(where: \.tuning) else { return false }
        waiting = Question(kind: "dialog", message: alert.messageText, detail: alert.informativeText,
                           buttons: alert.buttons.map(\.title)) { index in
            waiting = nil
            done(response(for: index))
        }
        Headless.log("held a Settings dialog for the bench: \(said(alert))")
        return true
    }

    /// The question in a line, for the log.
    private static func said(_ alert: NSAlert) -> String {
        let text = [alert.messageText, alert.informativeText].filter { !$0.isEmpty }.joined(separator: " — ")
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    nonisolated static func response(for index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    /// The button `choice` names: its index (1-based), its title, or the
    /// start of its title, any case. Nil when none does.
    nonisolated static func button(_ choice: String, in titles: [String]) -> Int? {
        let wanted = choice.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let n = Int(wanted), titles.indices.contains(n - 1) { return n - 1 }
        if let exact = titles.firstIndex(where: { $0.lowercased() == wanted }) { return exact }
        return titles.firstIndex { $0.lowercased().hasPrefix(wanted) }
    }

    /// `bench settings confirm answer CHOICE`.
    static func answer(_ choice: String) -> [String: Any] {
        guard let question = waiting else { return ["error": "no question is up"] }
        guard let index = button(choice, in: question.buttons) else {
            return ["error": "no button “\(choice)”", "buttons": question.buttons]
        }
        last = ["kind": question.kind, "message": question.message, "pressed": question.buttons[index]]
        if holds { waiting = nil }
        question.press(index)
        return ["answered": question.buttons[index], "kind": question.kind]
    }

    /// What is being asked, for the bench.
    static var describe: [String: Any] {
        guard let question = waiting else { return ["waiting": false, "last": last] }
        return ["waiting": true, "kind": question.kind, "message": question.message,
                "detail": question.detail, "buttons": question.buttons, "last": last]
    }

    /// `bench settings confirm selftest`: a SwiftUI confirmation dialog —
    /// the kind Settings pages use for New token, Clear history, Revoke —
    /// put up while Settings is open, held, answered through `answer`, and
    /// its button's own action seen to run. Test runs only.
    static func selftest(in browser: Browser, answer reply: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { reply(["error": "only in a test run"]); return }
        let wasOpen = browser.tuning
        browser.tuning = true
        let probe = ConfirmProbe()
        let host = NSHostingView(rootView: ConfirmProbeView(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 240, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { probe.asking = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let held = describe
            let answered = answer("Do it")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                window.orderOut(nil)
                if !wasOpen { browser.tuning = false }
                reply(["ok": probe.done && held["waiting"] as? Bool == true, "held": held,
                       "answered": answered, "actionRan": probe.done, "holds": holds])
            }
        }
    }

    /// The question named `kind` is no longer up (its sheet went away by
    /// itself).
    static func drop(_ kind: String) {
        if waiting?.kind == kind { waiting = nil }
    }
}

/// `TestConfirm.selftest`'s dialog and what its button did.
@MainActor
private final class ConfirmProbe: ObservableObject {
    @Published var asking = false
    var done = false
}

private struct ConfirmProbeView: View {
    @ObservedObject var probe: ConfirmProbe

    var body: some View {
        Color.clear
            .confirmationDialog("A question for the bench?", isPresented: $probe.asking) {
                Button("Do it", role: .destructive) { probe.done = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Held for the bench in a test run.")
            }
    }
}

// MARK: - the bench

/// `bench settings ax [focus|raw|controls|sweep]`: what VoiceOver finds in
/// the window in front — every element under the Settings panel with its
/// role, name and value — and which one has the keyboard. Read from the
/// app's own accessibility tree, in process, so it needs no grant.
///
///   (nothing)  every named element
///   focus      only who has the keyboard
///   controls   only the controls (switches, choices, buttons, fields), each
///              with whether it has a name and can take the keyboard
///   raw        every node, named or not, for chasing a missing one
///   sweep      `controls` on every page in turn, and the unnamed ones listed
@MainActor
enum SettingsAccessibility {
    static let controlRoles: Set<String> = [
        "AXCheckBox", "AXButton", "AXRadioButton", "AXRadioGroup", "AXTextField", "AXPopUpButton",
        "AXSlider", "AXSwitch", "AXToggle", "AXMenuButton", "AXLink", "AXSecureTextField", "AXComboBox", "AXTextArea",
    ]

    static func dump(in browser: Browser, mode: String) -> [String: Any] {
        guard let window = Windows.window(of: browser) ?? Links.window else { return ["error": "no window"] }
        let focus = focused()
        if mode == "focus" {
            return ["focused": focus, "control": SettingsControlLedger.describeFocus,
                    "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull(),
                    "keyboardNavigation": NSApp.isFullKeyboardAccessEnabled]
        }
        var out: [[String: Any]] = []
        var seen = 0
        walk(window, depth: 0, mode: mode, into: &out, seen: &seen)
        var answer: [String: Any] = ["focused": focus, "count": out.count, "elements": out, "visited": seen]
        if mode == "controls" {
            let unnamed = out.filter { $0["named"] as? Bool == false }
            answer["unnamed"] = unnamed
        }
        return answer
    }

    private static func focused() -> Any {
        guard let element = NSApp.accessibilityFocusedUIElement else { return NSNull() }
        return describe(element as AnyObject)
    }

    static func sweep(in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let pages = SettingsPanel.Page.allCases
        let before = browser.settingsPage
        let wasOpen = browser.tuning
        _ = SettingsFinder.of(browser).clear()
        browser.tuning = true
        // A page that is already showing doesn't draw again when it is
        // asked for, so its controls would go unnoted: start one page over.
        if before == pages.first, let other = pages.last { browser.settingsPage = other }
        var report: [String: Any] = [:]
        var unnamed: [String] = []
        var unreachable: [String] = []
        var total = 0

        func visit(_ index: Int) {
            guard index < pages.count else {
                browser.settingsPage = before
                if !wasOpen { browser.tuning = false }
                answer(["ok": unnamed.isEmpty && unreachable.isEmpty, "controls": total, "unnamed": unnamed,
                        "unreachable": unreachable, "pages": report,
                        "source": "each control's own accessibility name, value and keyboard stop, as drawn"])
                return
            }
            let page = pages[index]
            SettingsControlLedger.reset()
            browser.settingsPage = page
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let rows = SettingsControlLedger.drawn.filter { $0.page == page.rawValue }
                total += rows.count
                var kinds: [String: Int] = [:]
                for row in rows {
                    kinds[row.kind, default: 0] += 1
                    if row.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        unnamed.append("\(page.rawValue): \(row.kind)\(row.value.isEmpty ? "" : " = \(row.value)")")
                    }
                    if !row.keyboard, !row.disabled { unreachable.append("\(page.rawValue): \(row.kind) “\(row.name)”") }
                }
                report[page.rawValue] = ["controls": rows.count, "kinds": kinds,
                                         "items": rows.map { row -> String in
                                             let value = row.value.isEmpty ? "" : " = \(row.value)"
                                             let reach = row.disabled ? " (disabled)" : (row.keyboard ? "" : " (no keyboard)")
                                             return "\(row.kind) “\(row.name)”\(value)\(reach)"
                                         }]
                visit(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { visit(0) }
    }

    private static func describe(_ element: AnyObject) -> [String: Any] {
        var row: [String: Any] = [:]
        guard let e = element as? NSAccessibilityProtocol else {
            row["class"] = String(describing: type(of: element))
            return row
        }
        row["role"] = e.accessibilityRole()?.rawValue ?? ""
        if let label = e.accessibilityLabel(), !label.isEmpty { row["label"] = label }
        if let title = e.accessibilityTitle(), !title.isEmpty { row["title"] = title }
        if let value = e.accessibilityValue() {
            let text = "\(value)"
            if !text.isEmpty { row["value"] = text }
        }
        if let sub = e.accessibilitySubrole()?.rawValue { row["subrole"] = sub }
        if let help = e.accessibilityHelp(), !help.isEmpty { row["help"] = help }
        if e.isAccessibilitySelected() { row["selected"] = true }
        if e.isAccessibilityFocused() { row["focused"] = true }
        if !e.isAccessibilityEnabled() { row["enabled"] = false }
        return row
    }

    /// Whether the keyboard can be put on it: its AXFocused can be set.
    private static func focusable(_ element: AnyObject) -> Bool {
        guard let e = element as? NSAccessibilityProtocol else { return false }
        return e.isAccessibilitySelectorAllowed(#selector(NSAccessibilityProtocol.setAccessibilityFocused(_:)))
    }

    private static func walk(_ element: AnyObject, depth: Int, mode: String, into out: inout [[String: Any]], seen: inout Int) {
        seen += 1
        guard seen < 8000, depth < 80 else { return }
        var row = describe(element)
        let role = row["role"] as? String ?? ""
        let named = row["label"] != nil || row["title"] != nil
        switch mode {
        case "raw":
            row["depth"] = depth
            row["class"] = String(describing: type(of: element))
            out.append(row)
        case "controls":
            // A row of choices is a group with a value (Segmented).
            if controlRoles.contains(role) || (role == "AXGroup" && row["value"] != nil) {
                row["named"] = named
                row["focusable"] = focusable(element)
                out.append(row)
            }
        default:
            let interesting = controlRoles.union(["AXStaticText", "AXGroup", "AXHeading", "AXImage"])
            if interesting.contains(role), named || row["value"] != nil {
                row["depth"] = depth
                out.append(row)
            }
        }
        let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
        for child in children { walk(child as AnyObject, depth: depth + 1, mode: mode, into: &out, seen: &seen) }
    }
}
