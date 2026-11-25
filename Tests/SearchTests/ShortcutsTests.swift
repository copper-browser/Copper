import AppKit
import SwiftUI
import Testing
@testable import Search

// The shortcut table under every menu key (Fork/Shortcuts.swift): the
// defaults are unique and legal, a key's text round-trips, a rebinding moves
// the key and frees the old one, and a keystroke finds its command.

// keyCode 49, the space bar, as `bench key` sends a symbol.
private func press(_ chars: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 49) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                  windowNumber: 0, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode))
}

@Suite("Shortcut table")
struct ShortcutTableTests {
    @Test func everyDefaultIsUniqueLegalAndBound() throws {
        let table = ShortcutTable()
        var seen: [KeyCombo: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let combo = command.standard else { continue }
            #expect(seen[combo] == nil, "\(combo.text) is both \(seen[combo]?.rawValue ?? "") and \(command.rawValue)")
            seen[combo] = command
            #expect(table.check(combo, for: command) == nil, "\(command.rawValue)'s \(combo.text)")
            #expect(table.combo(command) == combo)
            #expect(table.command(for: combo) == command)
            #expect(!table.isChanged(command))
        }
        // Wave 1's keys are in it.
        #expect(MenuCommand.newLittle.standard?.text == "⌥⌘N")
        #expect(MenuCommand.cleanUp.standard?.text == "⌥⌘K")
        #expect(MenuCommand.split.standard?.text == "⇧⌘D")
        #expect(MenuCommand.copyMarkdown.standard?.text == "⌥⇧⌘C")
        #expect(MenuCommand.allCases.allSatisfy { MenuCommand.menus.contains($0.menu) && !$0.title.isEmpty })
    }

    @Test func textRoundTripsInApplesOrder() throws {
        let combo = try #require(KeyCombo("⌘⇧⌥C"))
        #expect(combo.key == "c")
        #expect(combo.mods == [.command, .shift, .option])
        #expect(combo.text == "⌥⇧⌘C")
        for text in ["⇧⌘D", "⌃⌥←", "⌘+", "⌘,", "⌥⌘F5", "⌃Space", "⇧⌘]"] {
            #expect(KeyCombo(text)?.text == text)
            #expect(KeyCombo(KeyCombo(text)!.text) == KeyCombo(text))
        }
        #expect(KeyCombo("") == nil)
        #expect(KeyCombo("⌘") == nil)
        #expect(KeyCombo("⌘AB") == nil)
        #expect(KeyCombo("⌃⌥←")?.keyboardShortcut == KeyboardShortcut(.leftArrow, modifiers: [.control, .option]))
        #expect(KeyCombo("⇧⌘D")?.keyboardShortcut == KeyboardShortcut("d", modifiers: [.command, .shift]))
    }

    @Test func aRebindingMovesTheKeyAndFreesTheOldOne() throws {
        let table = ShortcutTable()
        let new = try #require(KeyCombo("⌥⌘U"))
        #expect(table.check(new, for: .duplicateTab) == nil)
        let moved = ShortcutTable(table.setting(.duplicateTab, to: new))
        #expect(moved.overrides == ["duplicateTab": "⌥⌘U"])
        #expect(moved.command(for: new) == .duplicateTab)
        #expect(moved.command(for: KeyCombo("⌘D")!) == nil)
        #expect(moved.isChanged(.duplicateTab))
        // Back on its own key, nothing is written down.
        #expect(ShortcutTable(moved.setting(.duplicateTab, to: KeyCombo("⌘D"))).overrides.isEmpty)
        // No key at all.
        let none = ShortcutTable(table.setting(.closeTab, to: nil))
        #expect(none.overrides == ["closeTab": ""])
        #expect(none.combo(.closeTab) == nil)
        #expect(none.command(for: KeyCombo("⌘W")!) == nil)
    }

    @Test func aKeyAnotherCommandHoldsAsksThenMoves() throws {
        let table = ShortcutTable()
        let agent = try #require(KeyCombo("⌘E"))
        #expect(table.check(agent, for: .reload) == .taken(.agent))
        let taken = ShortcutTable(table.setting(.reload, to: agent))
        #expect(taken.command(for: agent) == .reload)
        #expect(taken.combo(.agent) == nil)
        #expect(taken.overrides == ["reload": "⌘E", "agent": ""])
        // Resetting the agent asks for ⌘E back from Reload.
        #expect(taken.check(MenuCommand.agent.standard, for: .agent) == .taken(.reload))
        // A key of yours wins over a default nobody moved.
        let shadow = ShortcutTable(["reload": "⌘T"])
        #expect(shadow.command(for: KeyCombo("⌘T")!) == .reload)
        #expect(shadow.combo(.newTab) == nil)
    }

    @Test func plainAndReservedKeysAreRefused() throws {
        let table = ShortcutTable()
        #expect(table.check(KeyCombo("X"), for: .reload) == .needsModifier)
        #expect(table.check(KeyCombo("⇧X"), for: .reload) == .needsModifier)
        #expect(table.check(KeyCombo("F5"), for: .reload) == nil)
        #expect(table.check(KeyCombo("⌥C"), for: .reload) == nil) // Option alone, as Ardia allows
        #expect(table.check(KeyCombo("⌘Q"), for: .reload) == .reserved("Quit"))
        #expect(table.check(KeyCombo("⌘3"), for: .reload) == .reserved("tab 3"))
        #expect(table.check(KeyCombo("⌃⇥"), for: .reload) == .reserved("the next tab"))
        #expect(table.check(nil, for: .reload) == nil)
    }

    @Test func aKeystrokeFindsItsCommand() throws {
        let table = ShortcutTable()
        #expect(table.command(for: try press("t", .command)) == .newTab)
        #expect(table.command(for: try press("G", [.command, .shift])) == .findPrevious)
        #expect(table.command(for: try press("n", [.command, .option])) == .newLittle)
        #expect(table.command(for: try press("\u{F702}", [.control, .option])) == .previousSpace)
        // ⌘+ typed as ⇧= on most keyboards, and ⌘= as Zoom In's too.
        #expect(table.command(for: try press("+", [.command, .shift])) == .zoomIn)
        #expect(table.command(for: try press("=", .command)) == .zoomIn)
        // ⇧⌘] arrives as "}": the key under it (kVK_ANSI_RightBracket) is Next Tab.
        #expect(table.command(for: try press("}", [.command, .shift], keyCode: 30)) == .nextTab)
        #expect(table.command(for: try press("t", [.command, .control])) == nil)
        #expect(table.command(for: try press("\u{1B}", .command)) == nil)
        let moved = ShortcutTable(["duplicateTab": "⌥⌘U"])
        #expect(moved.command(for: try press("u", [.command, .option])) == .duplicateTab)
        #expect(moved.command(for: try press("d", .command)) == nil)
    }

    @Test func keysRecordAsTheMenusWriteThem() throws {
        #expect(KeyCombo.recorded(try press("u", [.command, .option]))?.text == "⌥⌘U")
        #expect(KeyCombo.recorded(try press("}", [.command, .shift], keyCode: 30))?.text == "⇧⌘]")
        #expect(KeyCombo.recorded(try press("\u{F703}", [.control, .option]))?.text == "⌃⌥→")
        #expect(KeyCombo.recorded(try press("\u{1B}", [])) == nil)
    }
}
