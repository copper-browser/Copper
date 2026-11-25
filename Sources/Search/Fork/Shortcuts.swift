import AppKit
import SwiftUI

// Fork (ardia-shortcuts): every menu command's key, in one table. The menus
// ask it with `.shortcut(.newTab)` (App.swift, Spaces.swift ForkCommands,
// GroupsUI, CleanLinks…), the window's key monitor asks it which command a
// keystroke is (App.swift `take`), and Settings › Shortcuts rebinds them
// (Fork/ShortcutsSettings.swift). Your own keys are kept with the other
// settings under `shortcuts`: command id → "⌥⌘U", or "" for no key.

/// A key and its modifiers, written as the menus write it: "⇧⌘D", "⌃⌥←".
struct KeyCombo: Hashable {
    /// One character, lowercased ("d", "[", "+"), or a named key ("←", "↩", "F5", "Space").
    let key: String
    let mods: Mods

    struct Mods: OptionSet, Hashable {
        let rawValue: UInt8
        static let control = Mods(rawValue: 1)
        static let option = Mods(rawValue: 2)
        static let shift = Mods(rawValue: 4)
        static let command = Mods(rawValue: 8)

        init(rawValue: UInt8) { self.rawValue = rawValue }
        init(_ flags: NSEvent.ModifierFlags) {
            var mods: Mods = []
            if flags.contains(.control) { mods.insert(.control) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.command) { mods.insert(.command) }
            self = mods
        }
    }

    init(_ key: String, _ mods: Mods) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.mods = mods
    }

    /// Apple's order: ⌃ ⌥ ⇧ ⌘, then the key.
    private static let signs: [(Mods, Character)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]

    /// Keys with a name rather than a character, and what the menus need for them.
    static let named: [String: KeyEquivalent] = {
        var keys: [String: KeyEquivalent] = [
            "←": .leftArrow, "→": .rightArrow, "↑": .upArrow, "↓": .downArrow, "↩": .return, "⌫": .delete,
            "⌦": .deleteForward, "⇥": .tab, "Space": .space, "↖": .home, "↘": .end, "⇞": .pageUp, "⇟": .pageDown,
        ]
        for n in 1...12 { keys["F\(n)"] = KeyEquivalent(Character(UnicodeScalar(UInt32(0xF703 + n))!)) }
        return keys
    }()

    var text: String {
        Self.signs.filter { mods.contains($0.0) }.map { String($0.1) }.joined() + (key.count == 1 ? key.uppercased() : key)
    }

    /// "⌥⇧⌘C" back to a combo; nil for "" or anything that isn't one.
    init?(_ text: String) {
        var mods: Mods = []
        var rest = Substring(text)
        while let first = rest.first, let sign = Self.signs.first(where: { $0.1 == first }) {
            mods.insert(sign.0)
            rest = rest.dropFirst()
        }
        let key = String(rest)
        guard key.count == 1 || Self.named[key] != nil else { return nil }
        self.init(key, mods)
    }

    var keyboardShortcut: KeyboardShortcut {
        var modifiers: EventModifiers = []
        if mods.contains(.control) { modifiers.insert(.control) }
        if mods.contains(.option) { modifiers.insert(.option) }
        if mods.contains(.shift) { modifiers.insert(.shift) }
        if mods.contains(.command) { modifiers.insert(.command) }
        return KeyboardShortcut(Self.named[key] ?? KeyEquivalent(Character(key)), modifiers: modifiers)
    }

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("F") }

    /// A key as AppKit types it (`charactersIgnoringModifiers`, a menu's
    /// `keyEquivalent`) → the table's word for it; nil for Escape and the rest.
    static func key(_ typed: String) -> String? {
        guard let scalar = typed.unicodeScalars.first, typed.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF70F: return "F\(scalar.value - 0xF703)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x0D, 0x03: return "↩"
        case 0x09, 0x19: return "⇥"
        case 0x7F, 0x08: return "⌫"
        case 0x20: return "Space"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil // Escape, and keys with no name here
        default: return typed.lowercased()
        }
    }

    /// What a keystroke could mean, likeliest first. ⇧⌘] arrives as "}",
    /// so the key under it is tried too; ⌘+ is typed ⇧= on most keyboards,
    /// and ⌘= has always been Zoom In's as well.
    static func candidates(_ event: NSEvent) -> [KeyCombo] {
        guard let typed = event.charactersIgnoringModifiers, let key = Self.key(typed) else { return [] }
        let mods = Mods(event.modifierFlags)
        var out = [KeyCombo(key, mods)]
        if mods.contains(.shift), key.count == 1, !key.first!.isLetter {
            if let base = event.characters(byApplyingModifiers: []).flatMap(Self.key), base != key, base != "Space" {
                out.append(KeyCombo(base, mods))
            }
            out.append(KeyCombo(key, mods.subtracting(.shift)))
        }
        if key == "=" { out.append(KeyCombo("+", mods)) }
        return out
    }

    /// The combo a keystroke records as: the key under ⇧ for a symbol, as
    /// the menus want it ("⇧⌘]", not "⇧⌘}").
    static func recorded(_ event: NSEvent) -> KeyCombo? {
        let all = candidates(event)
        guard let first = all.first else { return nil }
        if first.mods.contains(.shift), all.count > 1, all[1].mods == first.mods { return all[1] }
        return first
    }
}

/// Every command in the menu bar that can have a key, in menu order.
enum MenuCommand: String, CaseIterable, Identifiable {
    // File
    case newTab, newWindow, newLittle, newPrivateTab, newCanvas, reopenTab, openAddress, closeTab, share, print
    // Edit
    case find, findNext, findPrevious
    // View
    case tabsInSidebar, foldSidebar, reload, hardReload, readingMode, translate, neverTranslate, inspect, floatVideo,
         hideElements, hiddenOnSite, zoomIn, zoomOut, actualSize,
         moveIn, split, flipPanes, rotatePanes, evenPanes, separatePanes, agent, askPage, canvas, driverTimeline, closePanes
    // Tabs
    case back, forward, nextTab, previousTab, searchTabs, pinTab, duplicateTab, copyAddress, copyMarkdown, copyHighlight,
         pasteAndGo, closeOtherTabs, clearTabs, cleanUp, stopSound
    // Bookmarks, History
    case addBookmark, showBookmarks, history, downloads, downloadsFolder, clearHistory
    // Spaces, Groups
    case newSpace, previousSpace, nextSpace, newGroup, removeFromGroup
    // Copper, Help
    case settings, welcome, passwords, searchAccounts, feedback

    var id: String { rawValue }

    /// The menu it lives in, as Settings › Shortcuts groups them.
    var menu: String {
        switch self {
        case .newTab, .newWindow, .newLittle, .newPrivateTab, .newCanvas, .reopenTab, .openAddress, .closeTab, .share, .print: return "File"
        case .find, .findNext, .findPrevious: return "Edit"
        case .tabsInSidebar, .foldSidebar, .reload, .hardReload, .readingMode, .translate, .neverTranslate, .inspect, .floatVideo,
             .hideElements, .hiddenOnSite, .zoomIn, .zoomOut, .actualSize,
             .moveIn, .split, .flipPanes, .rotatePanes, .evenPanes, .separatePanes, .agent, .askPage, .canvas, .driverTimeline, .closePanes: return "View"
        case .back, .forward, .nextTab, .previousTab, .searchTabs, .pinTab, .duplicateTab, .copyAddress, .copyMarkdown, .copyHighlight,
             .pasteAndGo, .closeOtherTabs, .clearTabs, .cleanUp, .stopSound: return "Tabs"
        case .addBookmark, .showBookmarks: return "Bookmarks"
        case .history, .downloads, .downloadsFolder, .clearHistory: return "History"
        case .newSpace, .previousSpace, .nextSpace: return "Spaces"
        case .newGroup, .removeFromGroup: return "Groups"
        case .settings, .welcome, .passwords, .searchAccounts, .feedback: return "Copper"
        }
    }

    static let menus = ["File", "Edit", "View", "Tabs", "Bookmarks", "History", "Spaces", "Groups", "Copper"]

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .newWindow: return "New Window"
        case .newLittle: return "New Little Copper Window"
        case .newPrivateTab: return "New Private Tab"
        case .newCanvas: return "New Canvas"
        case .reopenTab: return "Reopen Closed Tab"
        case .openAddress: return "Open Address…"
        case .closeTab: return "Close Tab"
        case .share: return "Share…"
        case .print: return "Print…"
        case .find: return "Find on Page…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .tabsInSidebar: return "Show Tabs in Sidebar"
        case .foldSidebar: return "Hide Sidebar"
        case .reload: return "Reload Page"
        case .hardReload: return "Hard Reload"
        case .readingMode: return "Reading Mode"
        case .translate: return "Translate Page"
        case .neverTranslate: return "Never Translate This Site"
        case .inspect: return "Inspect Element"
        case .floatVideo: return "Float Video"
        case .hideElements: return "Hide Elements…"
        case .hiddenOnSite: return "Hidden on This Site…"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .moveIn: return "Move in from Another Browser…"
        case .split: return "Split View"
        case .flipPanes: return "Flip Panes"
        case .rotatePanes: return "Stack Panes"
        case .evenPanes: return "Make Panes Even"
        case .separatePanes: return "Separate All Panes"
        case .agent: return "Agent"
        case .askPage: return "Ask About This Page"
        case .canvas: return "Canvas"
        case .driverTimeline: return "Driver Timeline"
        case .closePanes: return "Close All Panes"
        case .back: return "Back"
        case .forward: return "Forward"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .searchTabs: return "Search Tabs…"
        case .pinTab: return "Pin or Unpin Tab"
        case .duplicateTab: return "Duplicate Tab"
        case .copyAddress: return "Copy Address"
        case .copyMarkdown: return "Copy as Markdown"
        case .copyHighlight: return "Copy Link to Highlight"
        case .pasteAndGo: return "Paste and Go"
        case .closeOtherTabs: return "Close Other Tabs"
        case .clearTabs: return "Clear Tabs"
        case .cleanUp: return "Clean Up Tabs"
        case .stopSound: return "Stop Sound in Tab"
        case .addBookmark: return "Add This Page"
        case .showBookmarks: return "Show Bookmarks…"
        case .history: return "Show History…"
        case .downloads: return "Downloads…"
        case .downloadsFolder: return "Open Downloads Folder"
        case .clearHistory: return "Clear History"
        case .newSpace: return "New Space"
        case .previousSpace: return "Previous Space"
        case .nextSpace: return "Next Space"
        case .newGroup: return "New Group from This Tab"
        case .removeFromGroup: return "Remove from Group"
        case .settings: return "Settings…"
        case .welcome: return "Welcome…"
        case .passwords: return "Passwords…"
        case .searchAccounts: return "Search Accounts…"
        case .feedback: return "Send Feedback…"
        }
    }

    /// The key it comes with; nil for a command that has none until you give it one.
    var standard: KeyCombo? {
        switch self {
        case .newTab: return KeyCombo("⌘T")
        case .newWindow: return KeyCombo("⌘N")
        case .newLittle: return KeyCombo("⌥⌘N")
        case .newPrivateTab: return KeyCombo("⇧⌘N")
        case .newCanvas: return KeyCombo("⌃⇧E")
        case .reopenTab: return KeyCombo("⇧⌘T")
        case .openAddress: return KeyCombo("⌘L")
        case .closeTab: return KeyCombo("⌘W")
        case .print: return KeyCombo("⌘P")
        case .find: return KeyCombo("⌘F")
        case .findNext: return KeyCombo("⌘G")
        case .findPrevious: return KeyCombo("⇧⌘G")
        case .tabsInSidebar: return KeyCombo("⇧⌘S")
        case .foldSidebar: return KeyCombo("⌘S")
        case .reload: return KeyCombo("⌘R")
        case .hardReload: return KeyCombo("⇧⌘R")
        case .readingMode: return KeyCombo("⌥⌘R")
        case .inspect: return KeyCombo("⇧⌘I")
        case .floatVideo: return KeyCombo("⇧⌘P")
        case .hideElements: return KeyCombo("⇧⌘H")
        case .hiddenOnSite: return KeyCombo("⇧⌘U")
        case .zoomIn: return KeyCombo("⌘+")
        case .zoomOut: return KeyCombo("⌘-")
        case .actualSize: return KeyCombo("⌘0")
        case .moveIn: return KeyCombo("⌥⇧⌘I")
        case .split: return KeyCombo("⇧⌘D")
        case .agent: return KeyCombo("⌘E")
        case .askPage: return KeyCombo("⇧⌘E")
        case .canvas: return KeyCombo("⇧⌘O")
        case .driverTimeline: return KeyCombo("⌥⌘J")
        case .closePanes: return KeyCombo("⌥⌘E")
        case .back: return KeyCombo("⌘[")
        case .forward: return KeyCombo("⌘]")
        case .nextTab: return KeyCombo("⇧⌘]")
        case .previousTab: return KeyCombo("⇧⌘[")
        case .searchTabs: return KeyCombo("⌘K")
        case .duplicateTab: return KeyCombo("⌘D")
        case .copyAddress: return KeyCombo("⇧⌘C")
        case .copyMarkdown: return KeyCombo("⌥⇧⌘C")
        case .pasteAndGo: return KeyCombo("⇧⌘V")
        case .clearTabs: return KeyCombo("⇧⌘K")
        case .cleanUp: return KeyCombo("⌥⌘K")
        case .stopSound: return KeyCombo("⇧⌘M")
        case .addBookmark: return KeyCombo("⇧⌘B")
        case .history: return KeyCombo("⌘Y")
        case .downloads: return KeyCombo("⇧⌘J")
        case .newSpace: return KeyCombo("⌃N")
        case .previousSpace: return KeyCombo("⌃⌥←")
        case .nextSpace: return KeyCombo("⌃⌥→")
        case .newGroup: return KeyCombo("⌃⇧G")
        case .settings: return KeyCombo("⌘,")
        case .passwords: return KeyCombo("⌥⌘L")
        case .searchAccounts: return KeyCombo("⇧⌘Y")
        case .share, .translate, .neverTranslate, .flipPanes, .rotatePanes, .evenPanes, .separatePanes, .pinTab, .copyHighlight,
             .closeOtherTabs, .showBookmarks, .downloadsFolder, .clearHistory, .removeFromGroup, .welcome, .feedback:
            return nil
        }
    }

    /// Other words Settings search finds it by.
    var words: [String] {
        switch self {
        case .openAddress: return ["address", "location", "url bar", "omnibox"]
        case .searchTabs: return ["command bar", "tab search", "palette", "switch tab"]
        case .newPrivateTab: return ["private browsing", "incognito"]
        case .newLittle: return ["little arc", "small window", "mini window"]
        case .duplicateTab: return ["copy tab"]
        case .copyAddress: return ["copy url", "copy link"]
        case .clearTabs, .cleanUp: return ["close tabs", "tidy"]
        case .addBookmark: return ["bookmark this page"]
        case .tabsInSidebar: return ["toggle sidebar", "vertical tabs"]
        case .foldSidebar: return ["collapse", "focus mode"]
        case .readingMode: return ["reader", "reader mode"]
        case .hardReload: return ["refresh", "clear cache reload"]
        case .inspect: return ["web inspector", "devtools", "developer tools"]
        case .hideElements: return ["zap", "hide element", "block element"]
        case .floatVideo: return ["picture in picture", "pip"]
        case .settings: return ["preferences"]
        case .split: return ["split screen", "side by side"]
        case .newCanvas, .canvas: return ["whiteboard", "board"]
        default: return []
        }
    }
}

/// The table at one moment: the defaults with your own keys over them.
struct ShortcutTable {
    /// Command id → "⌥⌘U", or "" for no key: only what differs from the defaults.
    let overrides: [String: String]
    private var bound: [MenuCommand: KeyCombo] = [:]
    private var holders: [KeyCombo: MenuCommand] = [:]

    init(_ overrides: [String: String] = [:]) {
        self.overrides = overrides
        // Yours first; then each default nobody has taken with a key of their own.
        for command in MenuCommand.allCases {
            guard let text = overrides[command.rawValue], let combo = KeyCombo(text), holders[combo] == nil else { continue }
            bound[command] = combo
            holders[combo] = command
        }
        for command in MenuCommand.allCases where overrides[command.rawValue] == nil {
            guard let combo = command.standard, holders[combo] == nil else { continue }
            bound[command] = combo
            holders[combo] = command
        }
    }

    func combo(_ command: MenuCommand) -> KeyCombo? { bound[command] }
    func command(for combo: KeyCombo) -> MenuCommand? { holders[combo] }
    func command(for event: NSEvent) -> MenuCommand? {
        KeyCombo.candidates(event).lazy.compactMap { holders[$0] }.first
    }
    func isChanged(_ command: MenuCommand) -> Bool { bound[command] != command.standard }

    enum Problem: Equatable {
        /// A plain key would be taken from every text field.
        case needsModifier
        /// macOS's, or one of Copper's keys that isn't a menu command.
        case reserved(String)
        case taken(MenuCommand)
    }

    /// Keys no command may have, and whose they are.
    static let reserved: [String: String] = {
        var keys = ["⌘Q": "Quit", "⌘H": "Hide Copper", "⌥⌘H": "Hide Others", "⌘M": "Minimize", "⌘C": "Copy", "⌘V": "Paste",
                    "⌘X": "Cut", "⌘A": "Select All", "⌘Z": "Undo", "⇧⌘Z": "Redo", "⌘`": "the next window",
                    "⌃⇥": "the next tab", "⌃⇧⇥": "the previous tab"]
        for n in 1...9 { keys["⌘\(n)"] = "tab \(n)"; keys["⌃\(n)"] = "space \(n)" }
        return keys
    }()

    /// What stands in the way of giving `command` the key `combo`; nil when nothing does.
    func check(_ combo: KeyCombo?, for command: MenuCommand) -> Problem? {
        guard let combo else { return nil }
        if combo.mods.isDisjoint(with: [.command, .control, .option]), !combo.isFunctionKey { return .needsModifier }
        if let what = Self.reserved[combo.text] { return .reserved(what) }
        if let holder = holders[combo], holder != command { return .taken(holder) }
        return nil
    }

    /// The overrides once `command` has `combo` (nil: no key). Whoever held
    /// that key loses it; a command back on its own default isn't written down.
    func setting(_ command: MenuCommand, to combo: KeyCombo?) -> [String: String] {
        var next = overrides
        if let combo, let holder = holders[combo], holder != command { next[holder.rawValue] = "" }
        next[command.rawValue] = combo == command.standard ? nil : (combo?.text ?? "")
        return next
    }
}

/// The table you have, kept with the settings, and Settings › Shortcuts' recorder.
@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    @Published private(set) var table: ShortcutTable
    /// The row waiting for keys.
    @Published var recording: MenuCommand?
    /// What the last keys ran into, on the row they were for.
    @Published private(set) var note: Note?

    struct Note: Equatable {
        let command: MenuCommand
        let combo: KeyCombo?
        let problem: ShortcutTable.Problem

        var text: String {
            let keys = combo?.text ?? ""
            switch problem {
            case .needsModifier: return "Add ⌘, ⌥ or ⌃ to \(keys.isEmpty ? "the key" : keys)"
            case .reserved(let what): return "\(keys) is \(what) — try another"
            case .taken(let holder): return "\(keys) is \(holder.title)’s. Replace it?"
            }
        }
    }

    private init() {
        table = ShortcutTable(Store.settings.dictionary(forKey: "shortcuts") as? [String: String] ?? [:])
    }

    private func keep(_ overrides: [String: String]) {
        if overrides.isEmpty { Store.settings.removeObject(forKey: "shortcuts") } else { Store.settings.set(overrides, forKey: "shortcuts") }
        table = ShortcutTable(overrides)
    }

    /// `command`'s key as a hint after a tooltip, or "" for none.
    static func hint(_ command: MenuCommand) -> String {
        shared.table.combo(command).map { "   \($0.text)" } ?? ""
    }

    /// Give `command` the key `combo` (nil: none), unless something stands in
    /// the way: a key another command holds asks first (`replace`).
    func propose(_ combo: KeyCombo?, for command: MenuCommand) {
        if let problem = table.check(combo, for: command) {
            note = Note(command: command, combo: combo, problem: problem)
            // Another command's key stops the recording to ask; a key no
            // command may have keeps it listening for a better one.
            if case .taken = problem { recording = nil }
            return
        }
        keep(table.setting(command, to: combo))
        note = nil
        recording = nil
    }

    /// The asked-about key goes to the row that asked; its holder has none.
    func replace() {
        guard let note, case .taken = note.problem else { return }
        keep(table.setting(note.command, to: note.combo))
        self.note = nil
    }

    func dismiss() {
        note = nil
        recording = nil
    }

    func record(_ command: MenuCommand) {
        note = nil
        recording = command
    }

    func reset(_ command: MenuCommand) { propose(command.standard, for: command) }

    func resetAll() {
        keep([:])
        dismiss()
    }

    /// While a row records, the next keystroke is its own, before any
    /// command or page hears it (App.swift `take` asks first). ⎋ stops,
    /// ⌫ alone clears the row's key.
    func take(_ event: NSEvent) -> Bool {
        guard let command = recording, event.type == .keyDown else { return false }
        if event.isARepeat { return true }
        let bare = Mods(event.modifierFlags).isEmpty
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        if bare, event.keyCode == 51 || event.keyCode == 117 {
            propose(nil, for: command)
            return true
        }
        guard let combo = KeyCombo.recorded(event) else { return true }
        propose(combo, for: command)
        return true
    }

    private typealias Mods = KeyCombo.Mods
}

extension View {
    /// Fork (ardia-shortcuts): the command's key from the table, or none.
    func shortcut(_ command: MenuCommand) -> some View { modifier(ShortcutKey(command: command)) }
}

/// Each item watches the table itself, so a new key reaches its menu item
/// whether or not the menu around it is drawn again.
private struct ShortcutKey: ViewModifier {
    let command: MenuCommand
    @ObservedObject var keys = Shortcuts.shared

    func body(content: Content) -> some View {
        content.keyboardShortcut(keys.table.combo(command)?.keyboardShortcut)
    }
}

// MARK: - the bench

extension Shortcuts {
    /// `bench shortcuts [list]` every command and its key; `set ID KEYS|none`
    /// (as the recorder would: a held key asks); `record ID` (the next key
    /// pressed is the row's); `replace` / `cancel` the asked-about key;
    /// `reset ID|all`; `menu` what the menu bar's items carry; `press KEYS`
    /// a keystroke handed to the menu bar, as AppKit hands it one;
    /// `picture PATH [dark]` the Settings page.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let keys = shared
        let op = request["op"] as? String ?? "list"
        let arg = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let words = arg.split(separator: " ").map(String.init)
        func command(_ id: String?) -> MenuCommand? { id.flatMap { MenuCommand(rawValue: $0) } }
        switch op {
        case "list": break
        case "set":
            guard let target = command(words.first), words.count == 2 else { return ["error": "shortcuts set ID KEYS|none"] }
            let combo = words[1] == "none" ? nil : KeyCombo(words[1])
            if words[1] != "none", combo == nil { return ["error": "not a shortcut: \(words[1]) — e.g. ⌥⌘U"] }
            keys.propose(combo, for: target)
        case "record":
            guard let target = command(words.first) else { return ["error": "shortcuts record ID"] }
            keys.record(target)
        case "replace": keys.replace()
        case "cancel": keys.dismiss()
        case "reset":
            if arg == "all" { keys.resetAll() } else if let target = command(arg) { keys.reset(target) } else { return ["error": "shortcuts reset ID|all"] }
        case "menu": return ["menu": menuKeys(NSApp.mainMenu)]
        case "press":
            guard Store.testing else { return ["error": "press only works in a test run"] }
            guard let combo = KeyCombo(arg), let event = event(combo) else { return ["error": "shortcuts press KEYS — e.g. ⌃⌥L"] }
            let taken = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            return ["pressed": combo.text, "menuTook": taken]
        case "picture": return ShortcutsPage.picture(words)
        default: return ["error": "shortcuts list|set|record|replace|cancel|reset|menu|press|picture"]
        }
        return state()
    }

    private static func state() -> [String: Any] {
        let keys = shared
        let commands = MenuCommand.allCases.map { c -> [String: Any] in
            ["id": c.rawValue, "title": c.title, "menu": c.menu, "key": keys.table.combo(c)?.text ?? "",
             "standard": c.standard?.text ?? "", "changed": keys.table.isChanged(c)]
        }
        var note: Any = NSNull()
        if let n = keys.note { note = ["command": n.command.rawValue, "keys": n.combo?.text ?? "", "text": n.text] }
        var recording: Any = NSNull()
        if let r = keys.recording { recording = r.rawValue }
        return ["commands": commands, "overrides": keys.table.overrides, "recording": recording, "note": note,
                "stored": Store.settings.dictionary(forKey: "shortcuts") ?? [:]]
    }

    /// Every item in the menu bar with a key: its title → "⌥⌘U". Each menu
    /// is brought up to date first, as AppKit does before it opens one or
    /// matches a key against it (SwiftUI fills its menus then).
    private static func menuKeys(_ menu: NSMenu?) -> [String: String] {
        var out: [String: String] = [:]
        if let menu { menu.delegate?.menuNeedsUpdate?(menu); menu.update() }
        for item in menu?.items ?? [] {
            if let submenu = item.submenu { out.merge(menuKeys(submenu)) { a, _ in a } }
            guard !item.keyEquivalent.isEmpty, let key = KeyCombo.key(item.keyEquivalent) else { continue }
            var mods = KeyCombo.Mods(item.keyEquivalentModifierMask)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mods.insert(.shift) } // "E" with ⌘ is ⇧⌘E
            out[item.title] = KeyCombo(key, mods).text
        }
        return out
    }

    /// A key-down for `combo`, in the window in front, as `bench key` builds one.
    private static func event(_ combo: KeyCombo) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = []
        if combo.mods.contains(.control) { flags.insert(.control) }
        if combo.mods.contains(.option) { flags.insert(.option) }
        if combo.mods.contains(.shift) { flags.insert(.shift) }
        if combo.mods.contains(.command) { flags.insert(.command) }
        let chars = String(combo.keyboardShortcut.key.character)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: Windows.window(of: Windows.current)?.windowNumber ?? 0, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                keyCode: combo.key.count == 1 ? Bench.keyCode(for: Character(combo.key)) : 0)
    }
}
