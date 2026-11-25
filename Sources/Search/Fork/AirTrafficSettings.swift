import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings › General › Where links open: Air Traffic Control's rules
// (Fork/AirTraffic.swift) in order, Everything else, Try a Link, and the
// switch that sends a pinned tab's links to other sites to Peek
// (Fork/Peek.swift).

struct AirTrafficSection: View {
    @ObservedObject private var atc = AirTraffic.shared
    @State private var trial = ""
    @State private var trialApp: String?
    @State private var trialName: String?
    @AppStorage("peek.pins", store: Store.settings) private var peekPins = false

    var body: some View {
        SettingsSection("Where links open") {
            Line("Air Traffic Control", "Links from other apps go where the first rule that fits says — a space, and a tab, a new window or Little Copper (⌥⌘N)") {
                Pill("Add Rule") { atc.book.rules.append(AirTraffic.Rule()) }
            }
            .settingsAnchor("general.atc")
            ForEach(Array(atc.book.rules.enumerated()), id: \.element.id) { index, rule in
                Rule()
                AirTrafficRuleRow(rule: binding(rule.id), number: index + 1,
                                  raise: { if index > 0 { atc.book.rules.swapAt(index, index - 1) } },
                                  remove: { atc.book.rules.removeAll { $0.id == rule.id } })
            }
            Rule()
            Line("Everything else", "Links no rule names") {
                AirTrafficTargetPicker(target: $atc.book.otherwise)
            }
            .settingsAnchor("general.atc.else")
            Rule()
            Line("Try a link", trialResult) {
                HStack(spacing: 6) {
                    AirTrafficAppPicker(app: $trialApp, name: $trialName)
                    TextField("", text: $trial)
                        .fieldExample("https://…", when: trial.isEmpty)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 180)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .settingsField()
                        .accessibilityLabel("Link to try")
                }
            }
            .settingsAnchor("general.atc.try")
            Rule()
            Line("Peek at links from pins", "A link in a pinned tab that leads to another site opens in a card over the page (⇧-click does it anywhere)") {
                Switch(on: $peekPins)
            }
            .settingsAnchor("general.peek")
        }
    }

    private func binding(_ id: UUID) -> Binding<AirTraffic.Rule> {
        Binding(
            get: { atc.book.rules.first { $0.id == id } ?? AirTraffic.Rule(id: id) },
            set: { new in if let i = atc.book.rules.firstIndex(where: { $0.id == id }) { atc.book.rules[i] = new } }
        )
    }

    private var trialResult: String {
        let text = trial.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "Where a link from an app would go" }
        guard let url = URL(string: text.contains("://") ? text : "https://" + text), url.host() != nil else { return "Not a link" }
        let (rule, to) = atc.decide(url, from: trialApp)
        let which = rule.flatMap { r in atc.book.rules.firstIndex { $0.id == r.id } }.map { "Rule \($0 + 1)" } ?? "Everything else"
        return "\(which): \(AirTrafficTargetPicker.words(to))"
    }
}

/// One rule: from which app and for which sites, then where to.
struct AirTrafficRuleRow: View {
    @Binding var rule: AirTraffic.Rule
    let number: Int
    let raise: () -> Void
    let remove: () -> Void
    @Environment(\.settingsLook) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .frame(width: 16, alignment: .leading)
                Text("From").font(.system(size: 12)).foregroundStyle(Palette.muted)
                AirTrafficAppPicker(app: $rule.app, name: $rule.appName)
                Text("for").font(.system(size: 12)).foregroundStyle(Palette.muted)
                TextField("", text: $rule.site)
                    .fieldExample("any site, github.com, *.google.com/maps*", when: rule.site.isEmpty)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .settingsField()
                    .accessibilityLabel("Rule \(number) site")
                if number > 1 { icon("chevron.up", "Move rule \(number) up", raise) }
                icon("xmark", "Remove rule \(number)", remove)
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 16, height: 1)
                Text("Open in").font(.system(size: 12)).foregroundStyle(Palette.muted)
                AirTrafficTargetPicker(target: $rule.to)
            }
        }
        .padding(.horizontal, SettingsMetrics.lineInset(settings))
        .padding(.vertical, 10)
    }

    private func icon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A space (or whichever is in front) and how the link opens.
struct AirTrafficTargetPicker: View {
    @Binding var target: AirTraffic.Target
    @ObservedObject private var spaces = Spaces.shared

    var body: some View {
        HStack(spacing: 6) {
            Picker("Space", selection: $target.space) {
                Text("The space in front").tag(UUID?.none)
                // A space with a profile brings its own sign-ins: the profile is named with it.
                ForEach(spaces.all) { space in Text(space.profile.map { "\(space.title) · \($0)" } ?? space.title).tag(Optional(space.id)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Picker("Opens as", selection: $target.open) {
                ForEach(AirTraffic.Opening.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .font(.system(size: 12))
    }

    @MainActor static func words(_ to: AirTraffic.Target) -> String {
        let space = to.space.flatMap { id in Spaces.shared.all.first { $0.id == id }?.title }
        let how: String
        switch to.open {
        case .tab: how = "a tab"
        case .window: how = "a new window"
        case .little: how = "Little Copper"
        }
        return space.map { "\(how) in \($0)" } ?? "\(how), in the space in front"
    }
}

/// Any app, one that is running, or one picked from Applications.
struct AirTrafficAppPicker: View {
    @Binding var app: String?
    @Binding var name: String?

    var body: some View {
        Menu {
            Button("Any App") { app = nil; name = nil }
            Divider()
            ForEach(running) { one in
                Button(one.name) { app = one.id; name = one.name }
            }
            Divider()
            Button("Other App…", action: choose)
        } label: {
            Text(app == nil ? "Any app" : (name ?? app ?? ""))
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("From app")
    }

    private struct App: Identifiable { let id: String; let name: String }

    private var running: [App] {
        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> App? in
                guard let id = app.bundleIdentifier, id != mine, seen.insert(id).inserted else { return nil }
                return App(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        app = id
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// What Settings search finds here (SettingsIndex.rows).
@MainActor
enum AirTrafficSettingsIndex {
    static let entries: [SettingsEntry] = [
        SettingsEntry(page: .general, section: "Where links open", title: "Air Traffic Control",
                      subtitle: "Rules for links from other apps: which space, and a tab, a new window or Little Copper",
                      keywords: ["air traffic control", "atc", "link rules", "routing", "open links in", "little copper", "little arc", "choosy", "velja", "per app"],
                      anchor: "general.atc"),
        SettingsEntry(page: .general, section: "Where links open", title: "Everything else",
                      subtitle: "Where links no rule names go",
                      keywords: ["fallback", "default space", "other links"], anchor: "general.atc.else"),
        SettingsEntry(page: .general, section: "Where links open", title: "Try a link",
                      subtitle: "Where a link from an app would go",
                      keywords: ["test a link", "try a link", "check rule"], anchor: "general.atc.try"),
        SettingsEntry(page: .general, section: "Where links open", title: "Peek at links from pins",
                      subtitle: "A pinned tab's links to other sites open in a card over the page",
                      keywords: ["peek", "preview", "shift click", "glance", "pinned tabs", "pins"], anchor: "general.peek",
                      toggle: { _ in Binding(get: { Peek.pins }, set: { Peek.pins = $0 }) }),
    ]
}
