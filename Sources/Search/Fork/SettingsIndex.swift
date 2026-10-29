import SwiftUI

// Every setting there is, as data: which page, which section, what it is
// called, what it says under its name, the other words people use for it,
// and the anchor on the row search lands on. Search reads only this.
//
// It can't drift silently: every row search can land on carries
// `.settingsAnchor(id)`, and `bench settings index check` opens every page
// and compares — an entry whose anchor (or fallback) isn't drawn, or an
// anchor drawn with no entry, fails the check.

struct SettingsEntry: Identifiable {
    let page: SettingsPanel.Page
    let section: String
    let title: String
    let subtitle: String
    let keywords: [String]
    /// The row's `.settingsAnchor` id.
    let anchor: String
    /// Drawn in its place when the row itself isn't (a Bitwarden row while
    /// the vault is locked, a Jev row while Jev is off, a card another build
    /// adds): the card or section that holds it.
    var fallback: String? = nil
    /// A switch the result can flip in place.
    var toggle: ((Browser) -> Binding<Bool>)? = nil
    /// The page itself rather than a row on it.
    var isPage = false

    var id: String { "\(page.rawValue)/\(anchor)/\(title)" }
}

extension SettingsPanel.Page {
    /// The rail's groups, in order.
    enum Group: String, CaseIterable {
        case browsing = "Browsing"
        case copper = "AI & agents"
        case data = "Data & privacy"
        case about = "Copper"
    }

    var group: Group {
        switch self {
        case .general, .tabs, .spaces, .extensions: return .browsing
        case .intelligence, .agents: return .copper
        case .passwords, .privacy: return .data
        case .cloud, .about: return .about // Fork (settings-merge): Copper Cloud beside About
        }
    }

    /// The rail's order inside each group. `allCases` keeps upstream's order
    /// (and the stored `settings.page` values); this is only how it is drawn.
    static let railOrder: [SettingsPanel.Page] = [
        .general, .tabs, .spaces, .extensions,
        .intelligence, .agents,
        .passwords, .privacy,
        .cloud, .about,
    ]

    /// What the page is for, in a line under its title.
    var blurb: String {
        switch self {
        case .general: return "The default browser, how Copper looks, downloads, and moving in."
        case .tabs: return "The sidebar, switching between tabs, and what happens to tabs you leave."
        case .spaces: return "Each space's name, look, icon and profile. Drag the chips to reorder."
        case .intelligence: return "The model behind the agent pane, Jev's fast lane, and voice."
        case .agents: return "Let MCP clients, linked agent apps and terminal agents use this browser."
        case .cloud: return "Connect, sign in, then choose what follows you between Macs."
        case .extensions: return "Chrome extensions, and the addons your Copper Cloud assigns."
        case .passwords: return "Saved sign-ins, password managers, passkeys and what agents may use."
        case .privacy: return "Blocking ads and trackers, site permissions, and clearing what sites keep."
        case .about: return "Updates, feedback and the keyboard shortcuts."
        }
    }

    /// Other words for the page as a whole.
    var keywords: [String] {
        switch self {
        case .general: return ["preferences", "basics", "options", "downloads", "files", "download folder"]
        case .tabs: return ["tab bar", "vertical tabs", "sidebar"]
        case .spaces: return ["workspaces", "profiles", "space look"]
        case .intelligence: return ["ai", "model", "llm", "claude", "anthropic", "openai", "gpt", "keys",
                                    "voice", "dictation", "dictate", "speech", "transcription", "push to talk", "hold to talk",
                                    "microphone", "mic", "talk", "conversational", "speech model"]
        case .agents: return ["mcp", "proxy", "bot", "bots", "automation", "agent"]
        case .cloud: return ["sync", "account", "canvas", "devices", "backup"]
        case .extensions: return ["add-ons", "addons", "addon", "plugins", "chrome web store", "agent sidebar", "web app"]
        case .passwords: return ["pw", "pwd", "logins", "keychain", "autofill", "credentials", "password manager"]
        case .privacy: return ["security", "tracking", "data", "clear"]
        case .about: return ["version", "credits", "help", "shortcuts", "update", "updates", "upgrade", "release"]
        }
    }

    /// The invisible anchor at the top of every page's scroll.
    var topAnchor: String { "\(rawValue).top" }
}

@MainActor
enum SettingsIndex {
    /// Every entry, pages first (one per page), then the rows in page order.
    static let entries: [SettingsEntry] = [pages, rows].flatMap { $0 }

    static let pages: [SettingsEntry] = SettingsPanel.Page.allCases.map { page in
        SettingsEntry(page: page, section: "", title: page.title, subtitle: page.blurb,
                      keywords: page.keywords, anchor: page.topAnchor, isPage: true)
    }

    private static func e(
        _ page: SettingsPanel.Page, _ section: String, _ title: String, _ subtitle: String,
        _ keywords: [String], _ anchor: String, fallback: String? = nil,
        toggle: ((Browser) -> Binding<Bool>)? = nil
    ) -> SettingsEntry {
        SettingsEntry(page: page, section: section, title: title, subtitle: subtitle,
                      keywords: keywords, anchor: anchor, fallback: fallback, toggle: toggle)
    }

    /// A switch on the shared preferences.
    private static func pref(_ path: ReferenceWritableKeyPath<Preferences, Bool>) -> (Browser) -> Binding<Bool> {
        { browser in
            Binding(get: { browser.prefs[keyPath: path] }, set: { browser.prefs[keyPath: path] = $0 })
        }
    }

    // A list joined rather than a chain of `+`: long chains are slow for
    // older type checkers (the release runner's).
    static let rows: [SettingsEntry] = [
        general, downloads, tabs, spaces, intelligence, voice, agents, cloud,
        extensions, passwords, privacy, updates, about,
        AddonSettingsIndex.entries, // Fork (addons): Fork/Addons/AddonUI.swift — last, so Copper's own update rows win a tie
    ].flatMap { $0 }

    // MARK: general

    private static let general: [SettingsEntry] = [
        e(.general, "Copper on this Mac", "Open links from other apps", "Make Copper the default browser so links from Mail, Slack and the rest open here",
          ["default browser", "make default", "links", "handler", "open with", "system browser"], "general.default"),
        e(.general, "Copper on this Mac", "Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too",
          ["dark mode", "light mode", "theme", "night mode", "colour scheme", "color scheme", "system appearance"], "general.appearance"),
        e(.general, "Copper on this Mac", "Correct spelling as you type", "macOS's autocorrect inside pages",
          ["spelling", "spellcheck", "spell check", "autocorrect", "auto correct", "typos", "capitalise", "capitalize"], "general.autocorrect",
          toggle: pref(\.autocorrect)),
        e(.general, "Moving in", "Move in from another browser", "Tabs, spaces, bookmarks, history and passwords from Chrome, Safari or Arc",
          ["import", "flow", "chrome", "arc", "safari", "export", "reading list", "migrate", "switch browsers", "bookmarks import", "transfer"], "general.flow"),
        e(.general, "Moving in", "Browsing history", "Typed addresses complete from Arc or Chrome history",
          ["import history", "arc history", "chrome history", "browsing history", "autocomplete", "address completion"], "general.history"),
        e(.general, "Developer", "Let a script drive Copper", "A local socket for testing — see ./bench",
          ["bench", "automation", "socket", "testing", "script", "developer", "debug"], "general.bench",
          toggle: pref(\.bench)),
    ]

    // MARK: tabs

    private static let tabs: [SettingsEntry] = [
        e(.tabs, "Layout", "Tabs in a sidebar", "Down the left instead of across the top",
          ["vertical tabs", "sidebar", "side bar", "left column", "tab bar", "horizontal tabs"], "tabs.sidebar",
          toggle: pref(\.sidebar)),
        e(.tabs, "Layout", "Tabs show", "Icons or letters beside the title, and on a pinned square",
          ["favicons", "icons", "letters", "glyph", "tab icons"], "tabs.glyph"),
        e(.tabs, "Switching", "⌃Tab switches to", "Whether Control-Tab follows the row or your most recent tabs",
          ["control tab", "ctrl tab", "mru", "most recent", "recent tabs", "cycle tabs", "tab switching", "switch tabs"], "tabs.switching"),
        e(.tabs, "Switching", "Swipe between spaces", "Two fingers across the sidebar: natural, inverted, or like scrolling",
          ["trackpad", "gesture", "swipe", "natural scrolling", "inverted", "two fingers", "direction"], "tabs.swipe"),
        e(.tabs, "Tabs you leave", "Sleep tabs you aren't using", "Only when more pages are open than this Mac keeps easily, or memory runs short",
          ["memory", "suspend", "discard", "energy", "battery", "idle", "performance", "hibernate"], "tabs.sleep",
          toggle: pref(\.sleepsTabs)),
        e(.tabs, "Tabs you leave", "Archive Today after", "Untouched rows below the New Tab line close themselves",
          ["auto archive", "archive", "close old tabs", "today", "clean up", "12 hours", "24 hours", "cleanup"], "tabs.archive"),
    ]

    // MARK: spaces

    private static let spaces: [SettingsEntry] = [
        e(.spaces, "Spaces", "Your spaces", "Pick a space to edit, drag to reorder, or add a new one",
          ["workspaces", "new space", "add space", "reorder spaces", "switch space"], "spaces.picker"),
        e(.spaces, "Space", "Name", "What the space is called",
          ["rename", "space name", "title"], "spaces.name", fallback: "spaces.picker"),
        e(.spaces, "Space", "Look", "Colour, gradient, picture or an animated scene behind the column",
          ["theme", "gradient", "picture", "wallpaper", "background", "animated", "backdrop"], "spaces.look", fallback: "spaces.picker"),
        e(.spaces, "Space", "Profile", "Its own sign-ins and cookies, shared with spaces of the same profile",
          ["cookies", "separate logins", "container", "isolation", "work profile", "sign-ins"], "spaces.profile", fallback: "spaces.picker"),
        e(.spaces, "Space", "Icon", "A symbol, an emoji, or none",
          ["emoji", "symbol", "glyph"], "spaces.icon", fallback: "spaces.picker"),
        e(.spaces, "Space", "Colours", "The space's colour, gradient stops or tint",
          ["colour", "color", "tint", "palette", "hue"], "spaces.colours", fallback: "spaces.picker"),
        e(.spaces, "Space", "Adjust", "Intensity, grain, blur and tone of the column",
          ["intensity", "grain", "blur", "tone", "brightness", "contrast", "dark tone"], "spaces.adjust", fallback: "spaces.picker"),
        e(.spaces, "Space", "Delete this space", "Asks first, and can move its tabs to the space beside it",
          ["remove space", "delete"], "spaces.delete", fallback: "spaces.picker"),
    ]

    // MARK: intelligence

    private static let intelligence: [SettingsEntry] = [
        e(.intelligence, "Model access", "Use", "Your Claude account, or an API key for a model gateway",
          ["claude account", "api key", "gateway", "litellm", "provider", "openai", "lane", "model provider", "where the model comes from", "change provider"], "intelligence.lane"),
        e(.intelligence, "Model access", "Claude account", "Sign in with Claude Pro, Max, Team or Enterprise",
          ["sign in", "sign out", "anthropic", "pro", "max", "subscription", "claude.ai", "login", "logout", "oauth", "claude sign in"], "intelligence.account", fallback: "intelligence.lane"),
        e(.intelligence, "Model access", "API key", "From your gateway — anything that speaks /v1/chat/completions",
          ["gateway key", "sk", "token", "openai compatible", "router key", "paste key", "model key"], "intelligence.key", fallback: "intelligence.lane"),
        e(.intelligence, "Model access", "Gateway address", "Where the gateway lives",
          ["url", "base url", "endpoint", "litellm", "router url", "server"], "intelligence.gateway", fallback: "intelligence.lane"),
        e(.intelligence, "Model access", "Model", "Haiku, Sonnet or Opus — fast, balanced or most capable",
          ["haiku", "sonnet", "opus", "model size", "tier", "which model", "change model", "switch model", "smarter model", "smarter",
           "faster model", "faster", "cheaper model", "cheaper", "better model"], "intelligence.tier"),
        e(.intelligence, "Model access", "Model names", "What Haiku, Sonnet and Opus are called for your Claude account or on your gateway",
          ["model id", "alias", "model mapping", "custom model", "rename model"], "intelligence.names"),
        e(.intelligence, "Model access", "Check", "Asks Jev and the model one small question each, so you know they answer",
          ["test", "test key", "test connection", "ping", "verify", "diagnose", "is my key working", "key not working", "check key"], "intelligence.check"),
        e(.intelligence, "Jev", "Jev key", "Picks between choices in about a fifth of a second, for agents' quick decisions",
          ["jev key", "typesafe", "ts key", "system one", "fast lane"], "intelligence.jev"),
    ]

    // MARK: agents

    private static let mcpEnabled: (Browser) -> Binding<Bool> = { _ in
        Binding(get: { MCP.shared.config.enabled }, set: { MCP.shared.config.enabled = $0 })
    }
    private static let mcpAnnounces: (Browser) -> Binding<Bool> = { _ in
        Binding(get: { MCP.shared.config.announces }, set: { MCP.shared.config.announces = $0 })
    }
    private static let mcpJev: (Browser) -> Binding<Bool> = { _ in
        Binding(get: { MCP.shared.config.jev }, set: { MCP.shared.config.jev = $0 })
    }
    private static let pageContext: (Browser) -> Binding<Bool> = { _ in
        Binding(get: { Agent.shared.config.pageContext }, set: { Agent.shared.config.pageContext = $0 })
    }

    private static let agents: [SettingsEntry] = [
        e(.agents, "MCP server", "Let agents drive this window", "An MCP server on this Mac only — agents in your terminal or editor act in your tabs",
          ["mcp", "mcp server", "automation", "playwright", "claude code", "cursor", "phi", "proxy", "bot", "remote control", "enable", "disable", "agent access",
           "mcp off", "mcp on", "turn off mcp", "turn off agents", "stop agents", "agents off"], "agents.server",
          toggle: mcpEnabled),
        e(.agents, "MCP server", "Status", "Whether the server is listening, and where",
          ["listening", "running", "endpoint", "localhost", "127.0.0.1"], "agents.status"),
        e(.agents, "MCP server", "Say what the agent does", "Each tool call, in the line at the bottom of the window",
          ["announce", "narrate", "status line", "notifications"], "agents.announce", toggle: mcpAnnounces),
        e(.agents, "MCP server", "Port", "Change it if another app already uses the port",
          ["port number", "4123", "listen port"], "agents.port"),
        e(.agents, "Jev mode", "Let the agent hand Copper a goal", "Adds jev_run, jev_step, jev_observe and jev_extract: Jev drives this window towards a goal",
          ["jev", "ultrafast", "jev_run", "browser-use", "goal", "fast mode"], "agents.jev", toggle: mcpJev),
        e(.agents, "Jev mode", "Jev key", "A Jev key, shared with Settings › Intelligence",
          ["typesafe", "ts key"], "agents.jevkey", fallback: "agents.jev"),
        e(.agents, "Jev mode", "Text model", "Writes what gets typed and answers jev_extract",
          ["type text", "extract model", "small model", "typing model"], "agents.textmodel", fallback: "agents.jev"),
        e(.agents, "Jev mode", "Fast mode", "Types quoted values without a model, fills forms in one go",
          ["turbo", "speed", "faster", "quick", "burst", "glide"], "agents.jevfast", fallback: "agents.jev"),
        e(.agents, "Jev mode", "What Jev sees", "Text only, a picture of the page, the picture with numbers, or a Box",
          ["screenshot", "image", "picture", "vision", "marks", "box", "set of marks", "bounding box"], "agents.jevvision", fallback: "agents.jev"),
        e(.agents, "Agents apps", "Connect an agents app", "Linked agent apps get these tools for the bots you grant",
          ["agent link", "linked app", "bots", "grant", "personal token", "remote", "agents app"], "agents.links"),
        e(.agents, "Agents apps", "Add an agents app", "Paste its address and a personal token",
          ["new link", "add app", "connect app"], "agents.add"),
        e(.agents, "The ⌘E agent", "Page in front of every question", "The current tab's address, title and text go with each question in the agent pane (⌘E)",
          ["context", "ask on page", "agent pane", "cmd e", "page text"], "agents.context", toggle: pageContext),
        e(.agents, "The ⌘E agent", "Tool-call rounds per question", "How many times the agent may use its tools before it stops and asks",
          ["max turns", "turns", "rounds", "tool calls", "limit", "budget", "stopped after", "steps", "max steps", "iterations"], "agents.turns"),
        e(.agents, "The ⌘E agent", "Your other MCP servers", "mcp.json servers — http with headers, or a command to run",
          ["mcp.json", "servers", "tools", "stdio", "mcp client"], "agents.servers"),
        e(.agents, "Terminal agents", "phi", "Adds Copper to phi (~/.pi/agent/mcp.json) and a /jev prompt",
          ["pi", "set up phi", "terminal", "setup", "connect phi"], "agents.phi"),
        e(.agents, "Terminal agents", "Claude Code", "Adds Copper to Claude Code for your user (~/.claude.json) and a /jev command",
          ["claude code", "set up claude", "terminal", "cli", "connect claude code"], "agents.claude"),
        e(.agents, "Terminal agents", "copper CLI", "Puts the copper command in your PATH",
          ["command line", "install cli", "shell", "path", "terminal"], "agents.cli"),
        e(.agents, "Terminal agents", "Copy /jev", "A goal-first command for the agent in your terminal",
          ["slash command", "jev command", "copy for another agent"], "agents.copy"),
        e(.agents, "Terminal agents", "Copy prompt", "How to use Copper, for any agent — with the address and token",
          ["system prompt", "instructions", "agent prompt"], "agents.copy"),
        e(.agents, "Terminal agents", "Copy config", "The MCP server's JSON, for a client set up by hand",
          ["json config", "client config", "http config"], "agents.copy"),
        e(.agents, "Terminal agents", "Copy install command", "The one line that installs the copper CLI on another Mac",
          ["install", "brew", "homebrew", "curl"], "agents.copy"),
        e(.agents, "MCP server", "Bearer token", "Every request must carry it. A new token stops every client that has the old one",
          ["token", "secret", "rotate", "rotate token", "new token", "reset token", "auth", "authentication", "api key", "mcp token"], "agents.token"),
    ]

    // MARK: voice

    private static let voiceEnabled: (Browser) -> Binding<Bool> = { _ in
        Binding(get: { VoicePrefs.shared.enabled }, set: { on in
            guard VoicePrefs.supported else { return }
            VoicePrefs.shared.enabled = on
        })
    }

    private static let voice: [SettingsEntry] = [
        e(.intelligence, "Voice", "Talk to the agent", "Voice in the ⌘E pane. Speech is turned into text on this Mac; audio is never saved or sent",
          ["voice", "dictation", "dictate", "speech", "speech to text", "transcription", "mic", "talk",
           "push to talk", "hold to talk", "agent pane", "cmd e"], "voice.enabled", toggle: voiceEnabled),
        // Drawn while voice is on or a model is on disk; until then search
        // lands on the switch that brings it.
        e(.intelligence, "Voice", "Speech model", "Phonon-2, a one-time 345 MB download kept on this Mac until you remove it",
          ["speech model", "phonon", "remove model", "delete model", "free space", "disk space", "model size",
           "transcription", "on device", "offline"], "voice.model", fallback: "voice.enabled"),
        e(.intelligence, "Voice", "Talk", "Hold to talk, or press to start and stop — ⌃⇧D or the mic button",
          ["push to talk", "hold to talk", "ptt", "toggle", "press to talk", "shortcut", "control shift d", "mic button",
           "dictate", "dictation", "talk"], "voice.trigger", fallback: "voice.enabled"),
        e(.intelligence, "Voice", "When you stop", "Insert the words into the message, or send it right away",
          ["send", "auto send", "send right away", "insert", "conversational", "conversation", "dictation", "review before sending"],
          "voice.finish", fallback: "voice.enabled"),
        e(.intelligence, "Voice", "Let agents read the Listen transcript",
          "phi, Claude Code and other agents connected to Copper can read what Listen writes down while this is on. They can't start Listen or hear audio",
          ["transcript", "listen", "mcp", "agents", "share", "share transcript", "read transcript", "phi", "claude code",
           "terminal agents", "voice_transcript", "copper transcript", "live transcript"], "voice.shareTranscript", fallback: "voice.enabled"),
        e(.intelligence, "Voice", "Speech model credits", "Phonon-2 by Fermion Research, derived from NVIDIA Parakeet TDT 0.6B v3 · CC BY 4.0; runtime phonon-coreml · Apache-2.0",
          ["license", "licence", "attribution", "credits", "fermion", "nvidia", "parakeet", "cc by", "phonon", "speech model",
           "phonon-coreml", "apache", "speech runtime", "notice"],
          "voice.credits"),
    ]

    // MARK: cloud

    private static let cloud: [SettingsEntry] = [
        e(.cloud, "Copper Cloud", "Where you are", "Connect, sign in, then choose what syncs",
          ["steps", "setup", "progress"], "cloud.steps"),
        e(.cloud, "Connect", "Connect to an instance", "Paste a link code, a join link or a pairing code from another Mac",
          ["link code", "pairing code", "join link", "server", "instance", "self-hosted", "address", "certificate"], "cloud.connect", fallback: "cloud.steps"),
        e(.cloud, "Account", "Your account on this instance", "Sign in — with your company's Google account, or a password — or create the account",
          ["sign in", "sign up", "email", "password", "create account", "login", "copper cloud sign in", "cloud sign in", "cloud login", "cloud account",
           "google account", "google sign in", "continue with google", "sso", "single sign-on", "company account", "work account"], "cloud.signin", fallback: "cloud.steps"),
        e(.cloud, "Sync", "Browser sync", "Spaces, settings, bookmarks, open tabs and history — each on its own switch",
          ["sync", "turn on sync", "spaces sync", "bookmarks sync", "history sync", "settings sync", "tabs sync", "pause sync", "sync now"], "cloud.sync", fallback: "cloud.steps"),
        e(.cloud, "Sync", "Personal canvas", "Your Personal canvas follows you between Macs",
          ["canvas", "whiteboard", "board"], "cloud.sync", fallback: "cloud.steps"),
        e(.cloud, "Devices", "On your other devices", "The tabs open on your other Macs",
          ["other macs", "devices", "remote tabs", "handoff"], "cloud.devices", fallback: "cloud.steps"),
        e(.cloud, "Delete history on cloud", "Delete history on cloud", "The last hour, day or week, or all of it — or only one site. History on this Mac stays",
          ["delete cloud history", "erase history", "remove history", "clear synced history", "forget site", "privacy", "last hour", "all time"], "cloud.history", fallback: "cloud.steps"),
        e(.cloud, "Account", "Account", "Who you're signed in as, and this Mac's name",
          ["this mac", "device name", "sign out", "display name"], "cloud.account", fallback: "cloud.steps"),
        e(.cloud, "Pair another Mac", "One-time code", "Signs another Mac in as you with one paste",
          ["pair", "pairing code", "another mac", "new mac"], "cloud.pair", fallback: "cloud.steps"),
        e(.cloud, "Instance", "Disconnect", "Signs out and forgets this instance. Nothing is deleted",
          ["disconnect", "forget instance", "fingerprint", "instance details"], "cloud.instance", fallback: "cloud.steps"),
    ]

    // MARK: updates

    private static let updates: [SettingsEntry] = [
        e(.about, "Updates", "Check for updates", "Which Copper you have and whether a newer one is out",
          ["check for updates", "check now", "version", "latest", "new version", "upgrade", "release"], "updates.check"),
        e(.about, "Updates", "Install the update", "Downloads, verifies, backs up your tabs and relaunches",
          ["update", "relaunch", "install update", "download update", "restart"], "updates.install", fallback: "updates.check"),
        e(.about, "Updates", "What's new", "What the newer Copper brings, before you update",
          ["release notes", "changelog", "what's new", "whats new", "notes", "new features"], "updates.notes", fallback: "updates.check"),
        e(.about, "Updates", "Where updates come from", "The feed, and whether Homebrew manages this copy",
          ["feed", "homebrew", "brew", "source", "last checked", "update channel", "channel", "release channel", "nightly"], "updates.source"),
    ]

    // MARK: extensions

    private static let extensions: [SettingsEntry] = [
        e(.extensions, "Extensions", "Search extensions", "Find an installed extension by name, id or what it does",
          ["filter extensions", "find extension"], "extensions.tools", fallback: "extensions.top"),
        e(.extensions, "Extensions", "Chrome Web Store", "Get more from the Chrome Web Store, or load an unpacked folder",
          ["install extension", "web store", "load unpacked", "developer mode", "add extension"], "extensions.tools", fallback: "extensions.top"),
        e(.extensions, "Extensions", "Installed extensions", "Turn on or off, pin to the address bar, site access, permissions, remove",
          ["enable", "disable", "pin", "site access", "permissions", "remove extension", "uninstall", "options"], "extensions.list", fallback: "extensions.top"),
        e(.extensions, "Extensions", "Add by link", "Paste a Chrome Web Store link or an extension id",
          ["extension id", "store link", "paste link"], "extensions.adder", fallback: "extensions.top"),
    ]

    // MARK: passwords

    private static let passwords: [SettingsEntry] = [
        e(.passwords, "Saved passwords", "Your passwords", "In the macOS keychain, shown with Touch ID",
          ["keychain", "saved passwords", "logins", "show passwords", "touch id", "manage passwords", "pw", "password list"], "passwords.list"),
        e(.passwords, "Saved passwords", "Offer to save passwords", "Asked once per site, never again for a site you refuse",
          ["save passwords", "remember passwords", "password prompt"], "passwords.save", toggle: pref(\.savesPasswords)),
        e(.passwords, "Saved passwords", "Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it",
          ["autofill", "auto fill", "autocomplete", "fill logins", "login fill", "sign in"], "passwords.fill", toggle: pref(\.fillsPasswords)),
        e(.passwords, "Saved passwords", "Fill two-step codes", "The code page fills itself right after a sign-in with an account whose code Copper keeps",
          ["2fa", "two factor", "two-step", "one-time code", "otp", "totp", "authenticator", "verification code", "mfa"], "passwords.codes", toggle: pref(\.fillsCodes)),
        e(.passwords, "Saved passwords", "Fill addresses and cards", "Checkout and address forms fill from your Bitwarden and 1Password identities and cards",
          ["credit card", "address", "identity", "checkout", "autofill forms", "payment"], "passwords.everything", toggle: pref(\.fillsEverything)),
        e(.passwords, "Saved passwords", "Offer passkeys", "Touch ID to sign in on sites that offer a passkey",
          ["passkey", "webauthn", "fido", "touch id", "passwordless"], "passwords.passkeys", toggle: pref(\.passkeys)),
        e(.passwords, "Saved passwords", "Sites never asked", "Each site told to stop offering to save, with its own Forget",
          ["never save", "never ask", "exceptions", "blocked sites", "forget", "let a site ask again"], "passwords.never", fallback: "passwords.save"),
        e(.passwords, "Password managers", "Bitwarden", "Connect an existing Bitwarden or Vaultwarden vault",
          ["bitwarden", "bw", "vault", "vaultwarden", "password manager", "unlock", "master password", "sync vault", "lock", "sign out bitwarden", "log out", "switch account"], "bitwarden"),
        e(.passwords, "Password managers", "Bitwarden server", "bitwarden.com, EU, or a self-hosted Vaultwarden server",
          ["self-hosted", "vaultwarden", "eu server", "server url"], "bitwarden.server", fallback: "bitwarden"),
        e(.passwords, "Password managers", "Save new passwords to", "Keychain, Bitwarden or 1Password — where a password saved from a page goes",
          ["backend", "default store", "save to bitwarden", "save to 1password", "save to keychain", "where passwords go", "save target"],
          "passwords.backend", fallback: "passwords.managers"),
        e(.passwords, "Password managers", "Stay unlocked between launches", "Keeps the Bitwarden session on this Mac between launches",
          ["remember unlock", "session", "keep unlocked"], "bitwarden.stay", fallback: "bitwarden"),
        e(.passwords, "Password managers", "Auto-lock", "Lock the Bitwarden session after inactivity",
          ["autolock", "lock timeout", "inactivity", "lock after"], "bitwarden.autolock", fallback: "bitwarden"),
        e(.passwords, "Password managers", "1Password", "Fill from 1Password — unlock with Touch ID in the 1Password app, the account password, or a service account",
          ["1password", "one password", "op", "touch id", "vault", "unlock", "password manager", "agilebits", "op cli"], "onepassword"),
        e(.passwords, "Password managers", "Unlock 1Password", "Touch ID in 1Password's own window, or the account password",
          ["unlock 1password", "1password touch id", "1password app", "integrate with 1password cli", "lock 1password"],
          "onepassword.unlock", fallback: "onepassword"),
        e(.passwords, "Password managers", "1Password account", "The account Copper reads — email and sign-in address; sign out",
          ["1password account", "sign-in address", "my.1password.com", "secret key", "sign out 1password", "add account"],
          "onepassword.account", fallback: "onepassword"),
        e(.passwords, "Password managers", "1Password sign-in method", "The 1Password app, the account password, or a service account",
          ["sign in with", "1password password", "1password method", "app integration"],
          "onepassword.method", fallback: "onepassword"),
        e(.passwords, "Password managers", "Keep 1Password unlocked between launches", "Opens 1Password again at launch without asking",
          ["remember 1password", "1password session", "keep 1password unlocked", "stay unlocked"],
          "onepassword.stay", fallback: "onepassword"),
        e(.passwords, "Password managers", "Sync 1Password", "Read the vaults again now",
          ["sync 1password", "refresh 1password", "reload vault", "1password vaults"],
          "onepassword.sync", fallback: "onepassword"),
        e(.passwords, "Password managers", "1Password vault for new logins", "The vault a login saved from a page is created in",
          ["save to vault", "1password vault", "private vault", "personal vault", "new logins"],
          "onepassword.vault", fallback: "onepassword"),
        e(.passwords, "Password managers", "1Password service account", "An ops_ token for a Mac nobody sits at",
          ["service account", "ops_", "token", "headless", "op_service_account_token", "automation"],
          "onepassword.service", fallback: "onepassword"),
        e(.passwords, "Agent access", "Share every saved account with agents", "Agents use saved sign-ins in Copper without ever receiving the password",
          ["agents", "ai", "automation", "share logins", "bot sign in", "agent access"], "passwords.agents"),
        e(.passwords, "Agent access", "Accounts, identities and cards agents may use", "Allow each saved account, Bitwarden or 1Password identity or card on its own",
          ["allow agent", "per account", "identities", "cards", "agent permissions"], "passwords.agents"),
        e(.passwords, "Saved passwords", "Import passwords", "From Dia, Chrome, Arc, Brave or Edge on this Mac, in the Passwords window",
          ["import passwords", "bring yours in", "chrome", "arc", "brave", "edge", "dia", "migrate", "transfer passwords"], "passwords.list"),
        e(.passwords, "Import and export", "From a CSV file", "A passwords export from Chrome, Safari, Apple Passwords or a password manager",
          ["csv", "import csv", "apple passwords", "icloud keychain", "safari passwords", "chrome passwords", "password manager export", "import file"], "passwords.csv"),
        e(.passwords, "Import and export", "Export to a CSV file", "Every password Copper keeps, after Touch ID",
          ["export passwords", "export csv", "backup passwords", "download passwords", "save passwords to file"], "passwords.export"),
        e(.passwords, "Passkeys", "Copper passkeys", "The passkeys Copper keeps, and forgetting one",
          ["passkeys", "forget passkey", "webauthn credentials"], "passwords.passkeylist", fallback: "passwords.passkeys"),
    ]

    // MARK: downloads

    private static let downloads: [SettingsEntry] = [
        e(.general, "Downloads", "Save to", "The folder downloads go to",
          ["downloads folder", "download location", "directory", "path", "save location", "destination"], "downloads.folder"),
        e(.general, "Downloads", "Ask where to save each file", "A save panel for every download",
          ["save as", "prompt", "choose location", "ask", "ask before download", "confirm download", "save dialog"],
          "downloads.ask", toggle: pref(\.asksWhereToSave)),
    ]

    // MARK: privacy

    private static let privacy: [SettingsEntry] = [
        e(.privacy, "Blocking", "Block ads and trackers", "Third parties whose only job is to watch",
          ["adblock", "ad blocker", "ads", "trackers", "tracking", "privacy shield", "shield", "content blocker", "ublock", "tracking protection", "anti-tracking", "privacy protection", "block tracking"], "privacy.shield",
          toggle: pref(\.shielded)),
        e(.privacy, "Blocking", "Block on this site", "Turn off on a site that breaks — the page reloads",
          ["pause blocking", "allow site", "allowlist", "whitelist", "broken site", "exception"], "privacy.site", fallback: "privacy.shield"),
        e(.privacy, "Permissions", "Camera and microphone", "What each site was allowed or refused",
          ["permissions", "webcam", "mic", "site permissions", "forget choices"], "privacy.capture"),
        e(.privacy, "Clear browsing data", "History", "Every address you have been to",
          ["clear history", "delete history", "browsing data", "erase"], "privacy.history"),
        e(.privacy, "Clear browsing data", "Cookies and sign-ins", "Signs you out of every site, in every space",
          ["clear cookies", "sign out everywhere", "sign out of everything", "sign out of every site", "log out everywhere", "log out of everything", "site data", "storage", "local storage"], "privacy.cookies"),
        e(.privacy, "Clear browsing data", "Cache", "Only what was fetched to draw pages",
          ["clear cache", "cached files", "empty cache"], "privacy.cache"),
    ]

    // MARK: about

    private static let about: [SettingsEntry] = [
        e(.about, "Copper", "Copper", "Who made it, and what it is built on",
          ["version", "build", "credits", "collin", "felipe", "search", "office commun"], "about.identity"),
        e(.about, "Help", "Send Feedback", "Opens a new issue on Copper’s page, with the version already in it",
          ["feedback", "bug", "report a problem", "issue", "file an issue", "new issue", "contact", "support"], "about.feedback"),
        // Drawn only after a crash; until then search lands on Send Feedback.
        e(.about, "Diagnostics", "Last crash", "When Copper last quit unexpectedly, and what it was",
          ["crash", "crashed", "crash report", "quit unexpectedly", "diagnostics", "logs", "breadcrumbs"],
          "about.crash", fallback: "about.feedback"),
        e(.about, "Diagnostics", "Copy crash report", "Copies the last crash's summary and breadcrumbs, or shows its report in Finder",
          ["copy report", "reveal in finder", "ips", "diagnostic report", "crash log", "symbolicate"],
          "about.crash", fallback: "about.feedback"),
        e(.about, "Keyboard shortcuts", "Keyboard shortcuts", "Every keystroke Copper answers to",
          ["shortcuts", "hotkeys", "keys", "keyboard", "key bindings", "cheat sheet"], "about.shortcuts"),
    ] + SettingsShortcuts.all.map { shortcut in
        e(.about, "Keyboard shortcuts", shortcut.does, shortcut.keys,
          ["keyboard shortcut", "shortcut", "hotkey", "keys"] + shortcut.words, "about.shortcuts")
    }
}

/// The keystrokes About lists — the same list search finds.
enum SettingsShortcuts {
    struct Shortcut {
        let keys: String
        let does: String
        var words: [String] = []
    }

    static let all: [Shortcut] = [
        .init(keys: "⌘L", does: "Address", words: ["location", "url bar", "omnibox"]),
        .init(keys: "⌘K", does: "Switch tab", words: ["command bar", "tab search", "palette"]),
        .init(keys: "⌘T  ⌘W  ⇧⌘T", does: "New, close, reopen tab", words: ["new tab", "close tab", "reopen closed tab"]),
        .init(keys: "⌘N  ⇧⌘N", does: "New window, new private tab", words: ["new window", "private tab", "private browsing"]),
        .init(keys: "⌃⇧E", does: "New canvas", words: ["whiteboard", "new board"]),
        .init(keys: "⌘D", does: "Duplicate tab", words: ["duplicate", "copy tab"]),
        .init(keys: "⇧⌘C", does: "Copy the address", words: ["copy url", "copy link"]),
        .init(keys: "⇧⌘K", does: "Clear tabs", words: ["close tabs", "clean up tabs"]),
        .init(keys: "⇧⌘B", does: "Bookmark this page", words: ["add bookmark"]),
        .init(keys: "⌘Y", does: "History", words: ["show history"]),
        .init(keys: "⇧⌘J", does: "Downloads", words: ["show downloads"]),
        .init(keys: "⇧⌘S", does: "Tabs in a sidebar", words: ["toggle sidebar", "vertical tabs"]),
        .init(keys: "⌘S", does: "Fold the sidebar away", words: ["hide sidebar", "collapse"]),
        .init(keys: "⌥⌘R", does: "Reading mode", words: ["reader", "reader mode"]),
        .init(keys: "⇧⌘R", does: "Hard reload", words: ["refresh", "clear cache reload"]),
        .init(keys: "⇧⌘I", does: "Inspect element", words: ["web inspector", "devtools", "developer tools"]),
        .init(keys: "⇧⌘H", does: "Hide something on this site", words: ["zap", "hide element", "block element"]),
        .init(keys: "⇧⌘P", does: "Float the video", words: ["picture in picture", "pip"]),
        .init(keys: "⌘,", does: "Settings", words: ["preferences", "settings"]),
    ]
}
