import AppKit
import SwiftUI

// Fork (ardia-shortcuts): Settings › Shortcuts — every menu command with its
// key, grouped by menu. Click a key and press new ones; a key another command
// holds asks before it moves; Reset puts one back, Reset All every one
// (Fork/Shortcuts.swift keeps the table).

struct ShortcutsPage: View {
    @ObservedObject var keys = Shortcuts.shared

    var body: some View {
        Group {
            SettingsSection("Your keys") {
                Line("Change a shortcut", "Click its keys, then press the new ones. ⌫ takes the key away, ⎋ stops.") {
                    Pill("Reset All") { keys.resetAll() }
                        .disabled(keys.table.overrides.isEmpty)
                }
                .settingsAnchor("shortcuts.reset")
            }
            ForEach(MenuCommand.menus, id: \.self) { menu in
                SettingsSection(menu) {
                    let commands = MenuCommand.allCases.filter { $0.menu == menu }
                    ForEach(Array(commands.enumerated()), id: \.element) { i, command in
                        if i > 0 { Rule() }
                        row(command)
                            .settingsAnchor(command.anchor)
                    }
                }
            }
        }
        .onDisappear { keys.dismiss() } // a recording never outlives the page
    }

    private func row(_ command: MenuCommand) -> some View {
        let note = keys.note?.command == command ? keys.note : nil
        return Line(command.title, note?.text) {
            HStack(spacing: 6) {
                if let note, case .taken = note.problem {
                    Pill("Replace", filled: true) { keys.replace() }
                    Pill("Cancel") { keys.dismiss() }
                } else {
                    if keys.table.isChanged(command), keys.recording != command {
                        Pill("Reset") { keys.reset(command) }
                            .accessibilityLabel("Reset \(command.title)")
                    }
                    ShortcutKeys(command: command, keys: keys)
                }
            }
        }
    }
}

/// A command's keys, as a button: click to record new ones.
struct ShortcutKeys: View {
    let command: MenuCommand
    @ObservedObject var keys: Shortcuts

    var body: some View {
        let recording = keys.recording == command
        let combo = keys.table.combo(command)
        Pill(recording ? "Type the keys…" : combo?.text ?? "Add Key", filled: recording) {
            if recording { keys.dismiss() } else { keys.record(command) }
        }
        .frame(minWidth: 74, alignment: .trailing)
        .accessibilityLabel(recording ? "Recording a shortcut for \(command.title)" : "\(command.title) shortcut, \(combo?.text ?? "none")")
    }
}

extension MenuCommand {
    var anchor: String { "shortcuts.\(rawValue)" }
}

/// What Settings search finds here (SettingsIndex.rows).
@MainActor
enum ShortcutsSettingsIndex {
    static let entries: [SettingsEntry] = [
        SettingsEntry(page: .shortcuts, section: "Your keys", title: "Reset all shortcuts", subtitle: "Every menu command back on its own key",
                      keywords: ["reset shortcuts", "default shortcuts", "restore keys"], anchor: "shortcuts.reset"),
    ] + MenuCommand.allCases.map { command in
        SettingsEntry(page: .shortcuts, section: command.menu, title: command.title,
                      subtitle: command.standard.map { "\(command.menu) menu, \($0.text)" } ?? "\(command.menu) menu, no key yet",
                      keywords: ["keyboard shortcut", "shortcut", "hotkey", "keys"] + command.words, anchor: command.anchor)
    }
}

extension ShortcutsPage {
    /// `bench shortcuts picture PATH [dark] [WIDTH]`: the whole page, drawn
    /// off screen at the content width Settings gives it.
    @MainActor static func picture(_ words: [String]) -> [String: Any] {
        guard !words.isEmpty else { return ["error": "shortcuts picture PATH [dark] [WIDTH]"] }
        let dark = words.contains("dark")
        let width = words.dropFirst().compactMap { Double($0) }.first ?? 635
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 26) { ShortcutsPage() }
            .frame(width: CGFloat(width), alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background(SettingsInk.content)
            .environment(\.settingsLook, true)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["error": "no picture"] }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
        let path = URL(fileURLWithPath: words[0]).standardizedFileURL.path
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
        return ["path": path, "size": [Int(host.bounds.width), Int(host.bounds.height)]]
    }
}
