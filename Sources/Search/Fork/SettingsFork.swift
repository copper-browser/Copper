import AppKit
import SwiftUI

// Two pages of Settings that upstream doesn't have: Intelligence (the keys
// and what they're for) and Agents (the MCP server). Drawn with upstream's
// own cards and lines so they read as part of the same panel.

// MARK: - Intelligence

struct IntelligencePage: View {
    /// Not observed: only Sign in needs the window, and the browser says it
    /// changed on every page load behind the panel.
    let browser: Browser
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var account = ClaudeAccount.shared
    @ObservedObject var check = IntelligenceCheck.shared

    @State private var pasted = ""

    var body: some View {
        let _ = SettingsPerf.tick("intelligencePage") // Fork (settings-perf)
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection("Model access") {
                Line("Use", useDetail) {
                    // While Copper Cloud provides the gateway key it decides
                    // the lane; this Mac's choice is kept for after.
                    Segmented(options: Intelligence.Lane.allCases.map { ($0, $0.title) },
                              selection: brain.cloudLane ? .constant(brain.lane) : $brain.keys.lane)
                        .disabled(brain.cloudLane)
                        .opacity(brain.cloudLane ? 0.55 : 1)
                }
                .settingsAnchor("intelligence.lane")
                Rule()
                laneRows
                Rule()
                Line("Model", modelDetail) {
                    Segmented(options: Intelligence.Tier.allCases.map { ($0, $0.title) }, selection: $brain.keys.tier)
                }
                .settingsAnchor("intelligence.tier")
                Rule()
                Line("Model names", brain.lane == .claude
                     ? "What Haiku, Sonnet and Opus are called for your Claude account. Leave one empty for Copper's own."
                     : "What Haiku, Sonnet and Opus are called on your gateway. Leave one empty for the plain name.") {
                    modelNames
                }
                .settingsAnchor("intelligence.names")
                Rule()
                Line("Check", check.line ?? "Asks Jev and the model one small question each, so you know they answer.") {
                    if check.running {
                        HStack(spacing: 6) {
                            Ring(size: 12)
                            Text("Asking…").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Pill(check.line == nil ? "Test" : "Test again") { check.run() }
                    }
                }
                .settingsAnchor("intelligence.check")
            }

            SettingsSection("Jev", note: footnote) {
                Line("Jev key", brain.cloudLine("jevKey", brain.cloud?.jev?.key) ?? jevDetail) {
                    SettingsFlow(spacing: 8) { // Fork (settings-merge): the pill goes above the field in a narrow column
                        if !brain.jevReady { JevKeyPagePill() }
                        KeyField(text: $brain.keys.jevKey, placeholder: brain.cloudPlaceholder("jevKey", brain.cloud?.jev?.key, otherwise: "ts-…"),
                                 ready: brain.jevReady, refused: check.refused("jev"), label: "Jev key")
                    }
                }
                .settingsAnchor("intelligence.jev")
            }
        }
    }

    private var jevDetail: String {
        let speed = "Quick decisions for agents, in about a fifth of a second."
        return brain.jevReady ? speed : speed + " Needs a key from your TypeSafe account."
    }

    private var footnote: String {
        let local = "Keys and the Claude sign-in stay on this Mac, in files only you can read."
        guard brain.cloud != nil else { return local }
        return local + " Keys from Copper Cloud go when you sign out of it. While it provides a gateway key, that key is used; a Jev key typed here still wins over the cloud's."
    }

    private var useDetail: String {
        guard brain.cloudLane else {
            return "Sign in with your Claude account (Pro, Max, Team or Enterprise), or use an API key for a model gateway."
        }
        if brain.keys.lane == .claude || account.signedIn {
            return "Set by Copper Cloud, which provides the model key. Your Claude account is back when you sign out of it."
        }
        return "Set by Copper Cloud, which provides the model key while you're signed in to it."
    }

    @ViewBuilder
    private var laneRows: some View {
        if brain.lane == .claude {
            Line("Claude account", accountDetail) {
                accountControl
            }
            .settingsAnchor("intelligence.account")
        } else {
            Line("API key", brain.cloudLine("routerKey", brain.cloud?.router?.key) ?? "From your gateway — anything that speaks /\u{2060}v1/\u{2060}chat/\u{2060}completions.") {
                KeyField(text: brain.cloudLane ? .constant("") : $brain.keys.routerKey,
                         placeholder: brain.cloudPlaceholder("routerKey", brain.cloud?.router?.key, otherwise: "sk-…"),
                         ready: brain.routerReady, refused: check.refused("router"), label: "Gateway API key")
                    .disabled(brain.cloudLane)
            }
            .settingsAnchor("intelligence.key")
            Rule()
            Line("Gateway address", gatewayDetail) {
                TextField(brain.sources["routerURL"] == "cloud" || brain.cloudLane ? brain.effective.routerURL : "https://…",
                          text: brain.cloudLane ? .constant("") : routerURLBinding)
                    .disabled(brain.cloudLane)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 220)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .settingsField()
                    .accessibilityLabel("Gateway address")
            }
            .settingsAnchor("intelligence.gateway")
        }
    }

    /// Where the gateway is — and, when what was typed can't be one, what
    /// it should look like, before a check has to fail to say so.
    private var gatewayDetail: String {
        if brain.sources["routerURL"] == "cloud" { return "Provided by Copper Cloud (\(brain.cloud?.host ?? "your cloud"))" }
        if !Self.isWebAddress(brain.effective.routerURL) { return "That isn't a web address — it should start with https://" }
        return "Where the gateway lives"
    }

    static func isWebAddress(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && !(url.host ?? "").isEmpty
    }

    /// The address field. While Copper Cloud supplies the address it reads
    /// empty, the cloud's address as its placeholder; typing one overrides
    /// it, and clearing it goes back to the cloud's (or the default).
    private var routerURLBinding: Binding<String> {
        Binding(
            get: {
                let local = brain.keys.routerURL
                return brain.sources["routerURL"] == "cloud" && local.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == Intelligence.Keys().routerURL ? "" : local
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                brain.keys.routerURL = trimmed.isEmpty && brain.sources["routerKey"] == "cloud" ? Intelligence.Keys().routerURL : value
            }
        )
    }

    /// The tier, the name sent for it, and the model the last answer named.
    private var modelDetail: String {
        let line = "\(brain.tier.title) — \(brain.tier.blurb.prefix(1).lowercased() + brain.tier.blurb.dropFirst()). Asks for “\(brain.modelName)”"
        if let answered = brain.answeredModel, answered != brain.modelName { return line + "; the last answer came from \(answered)." }
        return line + ". You can also change it from the agent pane."
    }

    private var accountDetail: String {
        if account.signedIn {
            var detail = "Signed in as \(account.who)"
            if let organization = account.credential?.organization, !organization.isEmpty {
                detail += " · \(organization)"
            }
            return detail
        }
        switch account.phase {
        case .idle:
            return "Copper opens claude.ai in a tab; sign in there and you're back here."
        case .waiting:
            return "Finish in the tab that opened. If it doesn't come back on its own, paste the code claude.ai shows."
        case .exchanging:
            return "Finishing…"
        case .failed(let text):
            return text
        }
    }

    @ViewBuilder
    private var accountControl: some View {
        if account.signedIn {
            Pill("Sign out") { account.signOut() }
        } else {
            switch account.phase {
            case .idle:
                Pill("Sign in", filled: true) { account.signIn(in: browser) }
            case .waiting:
                HStack(spacing: 6) {
                    Ring(size: 12)
                    TextField("Paste the code", text: $pasted)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 150)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .settingsField()
                        .onSubmit(completePasted)
                        .accessibilityLabel("Claude sign-in code")
                    Pill("Cancel") { account.cancel() }
                }
            case .exchanging:
                Ring(size: 12)
            case .failed:
                Pill("Try again", filled: true) { account.signIn(in: browser) }
            }
        }
    }

    /// Three short rows, not three fields side by side: the card is not
    /// wide enough for that beside a title, and a name is easier to read
    /// next to the size it stands for.
    private var modelNames: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Intelligence.Tier.allCases) { tier in
                HStack(spacing: 6) {
                    Text(tier.title).font(.system(size: 11)).foregroundStyle(SettingsInk.detail)
                        .lineLimit(1).fixedSize()
                        .accessibilityHidden(true)
                    TextField(defaultModel(for: tier), text: modelBinding(tier))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 150)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .settingsField()
                        .accessibilityLabel("\(tier.title) model name")
                }
            }
        }
    }

    private func defaultModel(for tier: Intelligence.Tier) -> String {
        let defaults = brain.lane == .claude ? Intelligence.Keys.defaultClaudeModels : Intelligence.Keys.defaultRouterModels
        return defaults[tier.rawValue] ?? tier.rawValue
    }

    private func modelBinding(_ tier: Intelligence.Tier) -> Binding<String> {
        Binding(
            get: {
                let map = brain.lane == .claude ? brain.keys.claudeModels : brain.keys.routerModels
                return map[tier.rawValue] ?? defaultModel(for: tier)
            },
            set: { value in
                if brain.lane == .claude {
                    brain.keys.claudeModels[tier.rawValue] = value
                } else {
                    brain.keys.routerModels[tier.rawValue] = value
                }
            }
        )
    }

    private func completePasted() {
        let value = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        pasted = ""
        account.complete(pasted: value)
    }
}

/// A secret, shown as dots until you want to see it, with a paste button so
/// setting a key is one click. The dot says whether there is a key — and,
/// once a check has turned this one away, that it was refused.
struct KeyField: View {
    @Binding var text: String
    let placeholder: String
    let ready: Bool
    /// The last check turned this key away, and it hasn't changed since.
    var refused = false
    /// What VoiceOver calls the field ("Jev key").
    var label = "Key"
    @State private var shown = false
    @FocusState private var focused: Bool

    private var dot: Color {
        if refused { return Color.orange.opacity(0.85) }
        return ready ? Color.green.opacity(0.8) : Palette.faint
    }

    private var state: String {
        if refused { return "Turned away by the last check" }
        return ready ? "Set" : "Not set"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
                .help(state)
                .accessibilityHidden(true)
            Group {
                if shown {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 200)
            .focused($focused)
            .accessibilityLabel(label)
            .accessibilityValue(state)
            Button { shown.toggle() } label: {
                Image(systemName: shown ? "eye.slash" : "eye").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown ? "Hide the key" : "Show the key")
            .accessibilityLabel(shown ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
            Button {
                if let pasted = SettingsActions.pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                    text = pasted
                }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Paste from the clipboard")
            .accessibilityLabel("Paste \(label.lowercased())")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        // The field's own ring, around the whole of it (eye and paste too):
        // plain fields draw none, and Tab has to land somewhere visible.
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5)
                .opacity(focused ? 1 : 0)
                .animation(Motion.quick, value: focused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Updates

struct UpdatesPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var updates = Updates.shared

    private var isDevBuild: Bool {
        Fork.version == "dev" || Fork.version.split(separator: ".").count == 2
    }

    private var currentLine: String {
        "You have \(Updater.version) (build \(Updater.build))" + (isDevBuild ? " · dev build" : "")
    }

    /// What the feed said, in the words of the one next step. Before the
    /// first answer it says so, not "Couldn't check".
    private var latestLine: String {
        if updates.checking { return "Checking…" }
        // A newer Copper already known stays the headline when a re-check
        // fails: the install row under this one is still right.
        if updates.available, let latest = updates.latest {
            let line = "Latest Copper \(latest.version) · \(Self.publishedDate(latest.publishedAt))"
            return updates.error == nil ? line : line + " · couldn’t check again just now"
        }
        if let error = updates.error { return error }
        guard updates.latest != nil else { return "Not checked yet — Copper looks every six hours on its own" }
        return "Up to date"
    }

    private var installLine: String {
        "Updates come from \(updates.feedHost)" + (updates.managedByBrew ? " · installed via Homebrew" : "")
    }

    /// What the last update left behind, in one sentence. A failure stays
    /// here until the next update, next to the button that retries it.
    private var outcomeLine: (title: String, detail: String)? {
        guard let outcome = updates.outcome else { return nil }
        let when = outcome.at.formatted(.relative(presentation: .named))
        if outcome.ok { return ("Updated to \(outcome.detail)", when) }
        return ("The last update didn’t finish", "\(outcome.detail) · \(when)")
    }

    var body: some View {
        let _ = SettingsPerf.tick("updatesPage") // Fork (settings-perf)
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection("Updates") {
                Line(currentLine, latestLine) {
                    // One pill in both states: the row neither jumps nor
                    // loses its button while the feed is read.
                    Pill(updates.checking ? "Checking…" : "Check now") { updates.check(force: true) }
                        .disabled(updates.checking)
                }
                .settingsAnchor("updates.check")
                if updates.available, let version = updates.latest?.version {
                    Rule()
                    // The three states of a newer release: on its way, ready
                    // (the only one with an Update button), or not obtained —
                    // with the reason, and a way to try again.
                    Group {
                    if updates.downloading {
                        Line("Getting Copper \(version) ready", "Downloading from \(updates.feedHost) and verifying the bundle") {
                            Ring(size: 12)
                        }
                    } else if updates.ready {
                        Line("Copper \(version) is ready", "Downloaded and verified. Update backs up your tabs, swaps in the new Copper and relaunches — a few seconds.") {
                            Pill(updates.state == .upgrading ? "Updating…" : "Update", filled: true) {
                                updates.upgrade()
                            }
                            .disabled(updates.state == .upgrading)
                        }
                    } else {
                        Line("Copper \(version) isn’t downloaded yet", updates.stageError ?? "It downloads on its own after a check; Download gets it now.") {
                            Pill(updates.stageError == nil ? "Download" : "Retry") { updates.stage(force: true) }
                        }
                    }
                    }
                    .settingsAnchor("updates.install")
                    // What the release says it brings, before anyone presses
                    // Update — the same paragraph as the pill's What's New.
                    if let notes = updates.latest?.notes {
                        Rule()
                        Line("What’s new in \(version)", notes) { EmptyView() }
                            .settingsAnchor("updates.notes")
                    }
                }
                if let outcome = outcomeLine, updates.outcome?.ok == false {
                    Rule()
                    Line(outcome.title, outcome.detail) {
                        Pill("Open log") { SettingsActions.open(Updates.log) }
                    }
                }
            }
            // Why an update could not start in this process ("not downloaded
            // yet", "no longer there"). A refusal that was recorded as the
            // outcome is already in the card above, so it is not repeated.
            if let problem = updates.problem, updates.outcome?.detail != problem {
                SettingsNote(problem)
            }
            AddonUpdatesSection(browser: browser) // Fork (addons): an addon waiting for Install (Fork/Addons/AddonUI.swift)
            VStack(alignment: .leading, spacing: 4) {
                SettingsNote(installLine)
                if let outcome = outcomeLine, updates.outcome?.ok == true {
                    SettingsNote("\(outcome.title) · \(outcome.detail)")
                }
                if let checked = updates.checkedAt {
                    SettingsNote("Last checked \(checked.formatted(.relative(presentation: .named)))")
                }
            }
            .settingsAnchor("updates.source")
        }
    }

    static func publishedDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Agents

struct AgentsPage: View {
    /// Not observed: nothing here reads the window, and the browser says it
    /// changed on every page load behind the panel.
    let browser: Browser

    // Each section watches only the objects it reads, so an agent's tool
    // call (MCP), a reply streaming in the pane (Agent) or a link's status
    // redraws its own section rather than the whole page.
    var body: some View {
        let _ = SettingsPerf.tick("agentsPage") // Fork (settings-perf)
        VStack(alignment: .leading, spacing: 26) {
            AgentsServerSection()
            AgentsJevSection()
            AgentsLinksSection()
            AgentsPaneSection()
            AgentsTerminalSection()
        }
    }
}

/// MCP server: on or off, whether it listens, announcing, the port.
private struct AgentsServerSection: View {
    @ObservedObject var mcp = MCP.shared

    var body: some View {
        SettingsSection("MCP server", note: note) {
            Line("Let agents drive this window", "An MCP server on this Mac only (127.0.0.1). Agents in your terminal or editor see your tabs and act in them, signed in as you.") {
                Switch(on: $mcp.config.enabled)
            }
            .settingsAnchor("agents.server")
            Rule()
            Line("Status", status) {
                Circle().fill(mcp.running ? Color.green.opacity(0.8) : (mcp.trouble == nil ? Palette.faint : Color.orange.opacity(0.85)))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            .settingsAnchor("agents.status")
            Rule()
            Line("Say what the agent does", "Each tool call, in the line at the bottom of the window") {
                Switch(on: $mcp.config.announces)
            }
            .settingsAnchor("agents.announce")
            Rule()
            portRow
                .settingsAnchor("agents.port")
            Rule()
            AgentsTokenRow() // Fork (settings-merge): was a section of its own, "The key"
                .settingsAnchor("agents.token")
        }
    }

    private var note: String {
        let calls = mcp.calls > 0 ? "\(mcp.calls) tool call\(mcp.calls == 1 ? "" : "s") this session — last: \(mcp.lastTool). " : ""
        return calls + "Agents act as you: whatever you are signed in to, they are too. Turn the server off when you don't need it."
    }

    private var status: String {
        if let trouble = mcp.trouble {
            return MCP.portOverride == nil ? trouble + " — choose another port below." : trouble
        }
        if mcp.running { return "Listening at \(mcp.endpoint)" }
        return mcp.config.enabled ? "Starting…" : "Off — no agent can reach this browser."
    }

    /// The port the server listens on. A run that sets SEARCH_MCP_PORT
    /// listens there whatever this says, so the field says so instead.
    private var portRow: some View {
        let pinned = MCP.portOverride
        let port = Binding<Int>(get: { Int(mcp.config.port) }, set: { value in
            // 0 would mean "any port", which no client could be told.
            if let valid = UInt16(exactly: value), valid > 0 { mcp.config.port = valid }
        })
        return Line("Port", pinned.map { "This run listens on \($0), set by SEARCH_MCP_PORT." }
                    ?? "Change it if another app already uses \(mcp.config.port).") {
            TextField("4123", value: port, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 60)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .settingsField()
                .accessibilityLabel("Port")
                .disabled(pinned != nil)
                .opacity(pinned != nil ? 0.55 : 1)
        }
    }
}

/// Jev mode: the switch, and — while it is on — the key and the text model.
private struct AgentsJevSection: View {
    @ObservedObject var mcp = MCP.shared
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var check = IntelligenceCheck.shared

    /// The saved word as a mode, and back; an unknown word reads as off.
    private var jevVision: Binding<Tools.Ultrafast.Vision> {
        Binding(get: { Tools.Ultrafast.Vision.parse(brain.keys.jevVision) ?? .off },
                set: { brain.keys.jevVision = $0.rawValue })
    }

    var body: some View {
        SettingsSection("Jev mode") {
            Line("Let the agent hand Copper a goal", "Adds jev_run, jev_step, jev_observe and jev_extract: Jev clicks and types in this window about every 200 ms until the goal is done.") {
                Switch(on: $mcp.config.jev)
            }
            .settingsAnchor("agents.jev")
            if mcp.config.jev, !brain.jevReady { // Fork (settings-merge): once set, the key is Intelligence's row
                Rule()
                Line("Jev key", brain.cloudLine("jevKey", brain.cloud?.jev?.key) ?? "Jev mode needs a key from your TypeSafe account — the same one as Intelligence › Jev.") {
                    SettingsFlow(spacing: 8) { // Fork (settings-merge): the pill goes above the field in a narrow column
                        if !brain.jevReady { JevKeyPagePill() }
                        KeyField(text: $brain.keys.jevKey, placeholder: brain.cloudPlaceholder("jevKey", brain.cloud?.jev?.key, otherwise: "ts-…"),
                                 ready: brain.jevReady, refused: check.refused("jev"), label: "Jev key")
                    }
                }
                .settingsAnchor("agents.jevkey")
            }
            if mcp.config.jev {
                Rule()
                Line("Text model", brain.modelReady ? "Writes what Jev types and answers jev_extract. Small and fast is the point; empty uses \(brain.modelName)." : "Typing text and jev_extract need a model — set one up in Settings › Intelligence.") {
                    HStack(spacing: 8) {
                        Circle().fill(brain.modelReady ? Color.green.opacity(0.8) : Color.orange.opacity(0.8)).frame(width: 8, height: 8)
                            .help(brain.modelReady ? "A model is set up" : "No model is set up")
                            .accessibilityHidden(true)
                        TextField(brain.modelName, text: $brain.keys.textModel)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 120)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .settingsField()
                            .accessibilityLabel("Text model")
                    }
                }
                .settingsAnchor("agents.textmodel")
                Rule()
                Line("Fast mode", "Types the values your goal quotes without a model and fills a whole form in one go — about twice the actions a minute. Off runs the original loop.") {
                    Switch(on: $brain.keys.jevFast)
                }
                .settingsAnchor("agents.jevfast")
                Rule()
                Line("What Jev sees", "Auto sends the element table, and a numbered picture of the page only when the table can't tell controls apart. Pictures are a TypeSafe preview.") {
                    Segmented(options: Tools.Ultrafast.Vision.offered.map { ($0, $0.title) }, selection: jevVision)
                }
                .settingsAnchor("agents.jevvision")
                if !mcp.jevNote.isEmpty {
                    Rule()
                    Line("Last run", mcp.jevNote) { EmptyView() }
                }
            }
        }
    }
}

/// Linked agent apps: one card each, and the card that adds one.
private struct AgentsLinksSection: View {
    @ObservedObject var links = AgentLinks.shared

    var body: some View {
        SettingsSection("Agents apps", carded: false) {
            ForEach(links.all) { link in
                LinkCard(link: link)
            }
            Card {
                Line("Add an agents app", "Paste its address and a personal token") {
                    Pill("Add…", filled: links.all.isEmpty) { links.addEmpty() }
                }
                .settingsAnchor("agents.add")
            }
        }
        .settingsAnchor("agents.links", card: true)
    }
}

/// The agent in the window (⌘E): page context, its tool-call budget, and
/// the user's own MCP servers.
private struct AgentsPaneSection: View {
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var chat = Agent.shared
    @ObservedObject var servers = Servers.shared

    var body: some View {
        SettingsSection("The ⌘E agent") {
            Line("Page in front of every question", "The tab's address, title and first 3000 characters. Off, it can still look with its tools.") {
                Switch(on: $chat.config.pageContext)
            }
            .settingsAnchor("agents.context")
            Rule()
            turnsRow
                .settingsAnchor("agents.turns")
            Rule()
            Line("Your other MCP servers", serversLine) {
                HStack(spacing: 8) {
                    Pill("Open mcp.json") {
                        if !FileManager.default.fileExists(atPath: Servers.file.path) {
                            try? Servers.example.data(using: .utf8)?.write(to: Servers.file, options: .atomic)
                        }
                        SettingsActions.open(Servers.file)
                    }
                    Pill("Reload") { Task { await servers.reload() } }
                }
            }
            .settingsAnchor("agents.servers")
            ForEach(servers.all) { server in
                Rule()
                ServerRow(server: server)
            }
        }
    }

    /// Tool-call rounds per question. While Copper Cloud sets the org's
    /// number it is shown, not editable; this Mac's own comes back after.
    private var turnsRow: some View {
        let cloud = brain.cloudMaxTurns
        let turns = Binding(get: { cloud ?? chat.config.maxTurns }, set: { chat.config.maxTurns = $0 })
        return Line("Tool-call rounds per question", cloud.map { "Set by your Copper Cloud to \($0). Yours (\(chat.config.maxTurns)) is back when you sign out of it." }
                    ?? "How often it may use its tools on one question before it asks to go on. Default \(Agent.Config.defaultMaxTurns).") {
            HStack(spacing: 6) {
                TextField("\(Agent.Config.defaultMaxTurns)", value: turns, format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .settingsField()
                    .accessibilityLabel("Tool-call rounds per question")
                Stepper("Tool-call rounds per question", value: turns, in: Agent.Config.maxTurnsRange)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(cloud != nil)
            .opacity(cloud != nil ? 0.55 : 1)
        }
    }

    private var serversLine: String {
        if let trouble = servers.trouble { return trouble + " — fix it in Open mcp.json, then Reload." }
        if servers.all.isEmpty { return "Servers in mcp.json give the agent in the window their tools too: http servers with headers, or a command to run." }
        return "\(servers.all.filter(\.ready).count) of \(servers.all.count) connected · \(servers.readyTools) tools"
    }
}

/// Terminal agents: set up phi, Claude Code and the copper CLI, and the
/// copies for anything set up by hand.
private struct AgentsTerminalSection: View {
    @ObservedObject var mcp = MCP.shared
    @State private var copied: String?
    @State private var setupStatus = Setup.Status()
    @State private var setupResult: [String: SetupResult] = [:]
    @State private var settingUp: String?

    /// What the last Set up / Install wrote, or why it couldn't.
    struct SetupResult: Equatable {
        let ok: Bool
        let text: String
    }

    var body: some View {
        SettingsSection("Terminal agents") {
            terminalRow(.phi)
                .settingsAnchor("agents.phi")
            Rule()
            terminalRow(.claude)
                .settingsAnchor("agents.claude")
            Rule()
            terminalRow(.cli)
                .settingsAnchor("agents.cli")
            Rule()
            // Fork (settings-merge): the four copies were four rows.
            VStack(alignment: .leading, spacing: 0) {
                Line("Copy for another agent", "A /jev command, a prompt with the address and token, the MCP config, or the line that installs the copper CLI on another Mac") { EmptyView() }
                SettingsFlow(spacing: 8) {
                    Pill(copied == "jev" ? "Copied" : "Copy /jev") { copy(MCP.jevCommand(goal: nil), "jev") }
                    Pill(copied == "prompt" ? "Copied" : "Copy prompt") { copy(mcp.config.jev ? mcp.jevPrompt : mcp.agentPrompt, "prompt") }
                    Pill(copied == "http" ? "Copied" : "Copy config") { copy(mcp.clientConfig, "http") }
                    Pill(copied == "install" ? "Copied" : "Copy install") { copy(Setup.installCommand, "install") }
                }
                .padding(.horizontal, 16)
                .padding(.top, -4)
                .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Setup.installCommand)
                    Text("Or with Homebrew: \(Setup.brewCommand)")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsInk.detail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .settingsAnchor("agents.copy")
        }
        .task(id: "\(mcp.endpoint) \(mcp.config.token)") { await refreshSetup() }
    }

    private enum TerminalAgent: String {
        case phi, claude, cli

        /// " /jev" that never breaks, at the space before it or after the
        /// slash: at the narrowest the line broke inside the command.
        static let slashJev = "\u{00A0}/\u{2060}jev"

        var title: String {
            switch self {
            case .phi: return "phi"
            case .claude: return "Claude Code"
            case .cli: return "copper CLI"
            }
        }

        var detail: String {
            switch self {
            case .phi: return "Adds Copper to phi (~/.pi/agent/mcp.json) and a" + Self.slashJev + " prompt"
            case .claude: return "Adds Copper to Claude Code for your user (~/.claude.json) and a" + Self.slashJev + " command"
            case .cli: return "Puts the copper command in your PATH"
            }
        }
    }

    @ViewBuilder
    private func terminalRow(_ agent: TerminalAgent) -> some View {
        let result = setupResult[agent.rawValue]
        VStack(alignment: .leading, spacing: 0) {
            Line(agent.title, agent.detail) {
                HStack(spacing: 8) {
                    if settingUp == agent.rawValue {
                        Ring(size: 12)
                    } else {
                        Text(stateTitle(state(for: agent)))
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsInk.detail)
                    }
                    Pill(actionTitle(for: agent), filled: state(for: agent) != .ready) {
                        runSetup(agent)
                    }
                    .disabled(settingUp != nil)
                }
            }
            if let result {
                Text(result.text)
                    .font(.system(size: 11))
                    .foregroundStyle(result.ok ? SettingsInk.detail : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, -4)
                    .padding(.bottom, 12)
            }
        }
    }

    private func state(for agent: TerminalAgent) -> Setup.State {
        switch agent {
        case .phi: return setupStatus.phi
        case .claude: return setupStatus.claude
        case .cli: return setupStatus.cli
        }
    }

    private func stateTitle(_ state: Setup.State) -> String {
        switch state {
        case .missing: return "Not set up"
        case .stale: return "Out of date"
        case .ready: return "Ready"
        }
    }

    private func actionTitle(for agent: TerminalAgent) -> String {
        let state = state(for: agent)
        switch agent {
        case .phi, .claude: return state == .missing ? "Set up" : "Update"
        case .cli: return state == .missing ? "Install" : "Reinstall"
        }
    }

    /// Writes the agent's files off the main thread: they can be large
    /// (~/.claude.json), and the CLI asks the login shell for its PATH.
    private func runSetup(_ agent: TerminalAgent) {
        let setup = Setup(endpoint: mcp.endpoint, token: mcp.config.token)
        settingUp = agent.rawValue
        Task {
            let outcome: SetupResult = await Task.detached {
                do {
                    let report: Setup.Report
                    switch agent {
                    case .phi: report = try setup.phi()
                    case .claude: report = try setup.claude()
                    case .cli: report = try setup.cli()
                    }
                    let wrote = report.paths.map { ($0 as NSString).abbreviatingWithTildeInPath }
                    return SetupResult(ok: true, text: (report.notes + ["Wrote " + wrote.joined(separator: " and ") + "."]).joined(separator: " "))
                } catch {
                    return SetupResult(ok: false, text: (error as? Tools.Failure)?.text ?? error.localizedDescription)
                }
            }.value
            setupResult[agent.rawValue] = outcome
            settingUp = nil
            await refreshSetup()
        }
    }

    private func refreshSetup() async {
        let setup = Setup(endpoint: mcp.endpoint, token: mcp.config.token)
        setupStatus = await Task.detached { setup.status() }.value
    }

    private func copy(_ text: String, _ tag: String) {
        SettingsActions.copy(text)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == tag { copied = nil } }
    }
}

/// The bearer token: copying it, making a new one.
private struct AgentsTokenRow: View {
    @ObservedObject var mcp = MCP.shared
    @State private var copied = false
    @State private var confirmRotate = false

    var body: some View {
        Line("Bearer token", "Every request must carry it; it stays in agent.json, readable by you alone. A new token stops every client set up with the old one.") {
            HStack(spacing: 8) {
                Text(String(mcp.config.token.prefix(8)) + "…")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(SettingsInk.detail)
                    .accessibilityLabel("Token starting \(String(mcp.config.token.prefix(8)))")
                Pill(copied ? "Copied" : "Copy") {
                    SettingsActions.copy(mcp.config.token)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                Pill("New token…") { confirmRotate = true }
            }
        }
        .confirmationDialog("Make a new token?", isPresented: $confirmRotate) {
            Button("Make a new token", role: .destructive) { mcp.rotateToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every client set up with the current token stops working until it is set up again: phi and Claude Code with Update, under Terminal agents.")
        }
    }
}


// MARK: - agents

/// The agent link (Fork/MCP/Link.swift): on or off, where, the token, and
/// — once linked — who may use it and what they did.
struct LinkCard: View {
    @ObservedObject var link: AgentLink
    @State private var confirmRevoke = false
    @State private var confirmRemove = false

    private var linked: Bool { link.config.enabled && link.config.linkId != nil }

    private var ungranted: [AgentLink.Bot] {
        let granted = Set(link.grants.map(\.botId))
        return link.bots.filter { !granted.contains($0.id) }
    }

    private var dot: Color {
        switch link.status {
        case .online: return Color.green.opacity(0.8)
        case .connecting: return Color.yellow.opacity(0.8)
        case .offline, .tokenRejected, .revoked: return Color.orange.opacity(0.85)
        case .off: return Palette.faint
        }
    }

    private var grantsLine: String {
        if let error = link.lastError, link.status.isOnline { return error }
        if link.grants.isEmpty { return "None yet. A bot sees nothing here until you grant it." }
        let on = link.grants.filter(\.enabled).count
        return "\(on) of \(link.grants.count) on · switch one off to pause it"
    }

    private var placementLine: String {
        link.placement == "remote" ? "Remote headless" : "This Mac — your own browser"
    }

    var body: some View {
        Card {
            Line("Connect this browser", "An agents app gets these same tools, through its own service. Each bot only after you grant it, and you see every call here.") {
                Switch(on: $link.config.enabled)
            }
            Rule()
            Line("App address", "Shown at Agents › Connect in your agents app") {
                TextField("https://…", text: $link.config.api)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 220)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .settingsField()
                    .accessibilityLabel("App address")
            }
            Rule()
            Line("App name", "Optional nickname used in announcements") {
                TextField("optional", text: $link.config.label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 140)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .settingsField()
                    .accessibilityLabel("App name")
            }
            Rule()
            Line("Link name", link.config.name) { EmptyView() }
            Rule()
            Line("Placement", placementLine) { EmptyView() }
            if let servedBy = link.servedBy?.device {
                Rule()
                Line("Served by", servedBy) { EmptyView() }
                if !link.servingHere {
                    Text("Another Copper (\(servedBy)) is serving this link")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            Rule()
            Line("Personal token", "Mint one at Agents › Connect; it stays in a file only you can read") {
                KeyField(text: $link.config.token, placeholder: "fxb_…", ready: link.tokenReady, label: "Personal token")
            }
            Rule()
            Line("Status", link.status.text) {
                Circle().fill(dot).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            if linked {
                Rule()
                Line("Bots with access", grantsLine) {
                    Menu {
                        if ungranted.isEmpty {
                            Text(link.bots.isEmpty ? "No bots found" : "Every bot has access")
                        }
                        ForEach(ungranted) { bot in
                            Button(bot.name.isEmpty ? "@\(bot.handle)" : "@\(bot.handle) · \(bot.name)") {
                                Task { try? await link.setGrant(bot.id, enabled: true) }
                            }
                        }
                        Divider()
                        Button("Refresh") { Task { await load() } }
                    } label: {
                        Text("Grant a bot…").font(.system(size: 11.5))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                ForEach(link.grants) { grant in
                    Rule()
                    GrantRow(grant: grant, link: link)
                }
                if !link.recentCalls.isEmpty {
                    Rule()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recent calls").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(link.recentCalls.prefix(8)) { call in
                                    Text("@\(call.handle) · \(call.tool) · \(LinkWire.duration(call.ms)) · \(LinkWire.ago(context.date.timeIntervalSince(call.at)))")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(call.ok ? Palette.muted : Color.red.opacity(0.85))
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(call.error ?? "")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
                Rule()
                Line("Revoke link", "Every bot loses these tools now; Copper disconnects.") {
                    Pill("Revoke link", tint: Color.red.opacity(0.85)) { confirmRevoke = true }
                }
                .confirmationDialog("Revoke this link?", isPresented: $confirmRevoke) {
                    Button("Revoke link", role: .destructive) { Task { try? await link.revokeLink() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every bot loses these tools now; Copper disconnects.")
                }
            }
            Rule()
            Line("Remove this app", "Forget this app and its connection") {
                Pill("Remove", tint: Color.red.opacity(0.7)) { confirmRemove = true }
            }
            .confirmationDialog("Remove this app?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { Task { await AgentLinks.shared.remove(link) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Copper will forget this app and revoke it when possible.")
            }
        }
        .task(id: link.config.linkId.map { "\($0)\(link.config.enabled)" }) { await load() }
    }

    private func load() async {
        guard linked else { return }
        _ = try? await link.refreshGrants()
        _ = try? await link.listBots()
    }
}

/// One bot with access: who, on or off, and the × that takes it away.
private struct GrantRow: View {
    let grant: AgentLink.Grant
    @ObservedObject var link: AgentLink

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(grant.enabled ? Color.green.opacity(0.8) : Palette.faint).frame(width: 6, height: 6)
            Text("@\(grant.handle.isEmpty ? grant.botId : grant.handle)")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
            if !grant.name.isEmpty {
                Text("· \(grant.name)").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            if !grant.toolAllowlist.isEmpty {
                Text("· \(grant.toolAllowlist.count) tool\(grant.toolAllowlist.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .help(grant.toolAllowlist.joined(separator: ", "))
            }
            Spacer()
            Switch(on: Binding(
                get: { grant.enabled },
                set: { on in Task { try? await link.setGrant(grant.botId, enabled: on) } }
            ), label: "@\(grant.handle.isEmpty ? grant.botId : grant.handle)") // settings-a11y
            Button { Task { try? await link.removeGrant(grant.botId) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Take away @\(grant.handle)'s access")
            .accessibilityLabel("Take away @\(grant.handle)'s access")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// One configured server: name, where it is, and whether it answered.
struct ServerRow: View {
    @ObservedObject var server: Server

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(colour).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                Text(server.spec.line).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(server.ready ? "\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")" : server.state)
                .font(.system(size: 11)).foregroundStyle(server.state.hasPrefix("failed") ? Color.orange : Palette.muted)
                .lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var colour: Color {
        if server.ready { return Color.green.opacity(0.8) }
        if server.state == "connecting" { return Color.yellow.opacity(0.8) }
        if server.state.hasPrefix("failed") { return Color.orange.opacity(0.85) }
        return Palette.faint
    }
}


/// The small Settings doorway to the full Flow sheet.
struct FlowSettingsLine: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Line("Move in from another browser", "Tabs, spaces, bookmarks, history and passwords from Chrome, Safari or Arc") {
            Pill("Move in…", filled: true) { Flow.presentFromSettings(browser) }
        }
    }
}

/// A small, direct doorway for the part of Flow the address field can use on
/// its own. The read is off-main; this line only reports its quiet progress.
struct HistorySettingsLine: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var flow = Flow.shared

    var body: some View {
        Line("Browsing history", detail) { // settings-browse: it brings Arc's or Chrome's
            if case .reading = flow.historyImport {
                Text("Reading…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            } else {
                Pill("Bring in", filled: true) {
                    flow.importHistory(preferred: "Arc", in: browser)
                }
            }
        }
    }

    private var detail: String {
        let count = browser.history.visitCount
        // A fresh probe can retain Flow's last status while its history file
        // has been deliberately cleared; the row should describe what is
        // actually available to complete from, not that stale status.
        if count == 0 { return "Typed addresses complete from Arc or Chrome history" }
        if let detail = flow.historyImport.detail { return detail }
        return "\(count.formatted()) places kept — typed addresses complete from them"
    }
}

extension Browser {
    /// Settings, opened on one page. Spaces and Extensions are pages of it
    /// like any other: every "Edit Space…" and "Manage Extensions…" — the
    /// pill's puzzle piece, the foot's doors, the menus, ⌘K — lands here.
    /// Fork (settings-merge): `anchor` scrolls to a section on a page that
    /// holds several (Voice on Intelligence, Addons on Extensions).
    func openSettings(_ page: SettingsPanel.Page, at anchor: String? = nil) {
        settingsPage = page
        Store.settings.set(page.rawValue, forKey: "settings.page")
        tuning = true
        // After the panel's onAppear, which starts it fresh.
        if let anchor { DispatchQueue.main.async { SettingsFinder.of(self).land(on: anchor) } }
    }
}

/// A page of Settings drawn off screen at the page's own width and laid out
/// whole, on Settings' ground — for the bench's `spaces picture` and
/// `ext-manager picture`, which get every row this way rather than the top
/// of a scroll.
@MainActor
enum SettingsPicture {
    static func draw<Page: View>(_ page: Page, dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: page
            .frame(width: SpacePage.width, alignment: .topLeading)
            .padding(22)
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: picture)
        return picture
    }
}

/// Opens TypeSafe's console, where a Jev key is made. Shown beside the Jev
/// key box until there is a key.
private struct JevKeyPagePill: View {
    var body: some View {
        Pill("Get a key") {
            if let url = URL(string: Jev.keyPage) { NSWorkspace.shared.open(url) }
        }
        .help(Jev.keyPage)
    }
}
