import Foundation

// Flow — moving in from another browser, all at once.
//
// This file is the contract between the readers (Chrome's session files,
// Arc's sidebar, Chromium's cookie jar and extension list) and the one place
// that puts it all into Copper (`Flow.swift`). Readers produce these shapes
// and never touch `Browser`, `Spaces` or `Groups`; the merge never reads
// another browser's files. Keep this file small and stable — every worker
// on Flow builds against it.

enum FlowModel {
    /// One page another browser had open, as much as its files say.
    struct Tab: Hashable {
        var url: URL
        var title: String
        /// Chrome's pinned tab / Arc's favourite: lands in Copper's pin grid.
        var pinned = false
        /// Arc's per-space pinned tab: Copper's Saved section. Chrome has no
        /// equivalent; leave false and the tab is Today's.
        var saved = false
        /// The group (Chrome tab group / Arc folder) this tab sits in, by the
        /// id in the owning `Window.groups` / `Space.groups`.
        var group: UUID? = nil
        /// Arc: both halves of a split view carry the same token.
        var split: UUID? = nil
        /// When the other browser last had it in front, Unix seconds. Feeds
        /// Copper's Today ordering and the archive sweep.
        var seen: Double? = nil
        /// The tab that was on screen in its window / space.
        var active = false
    }

    /// A Chrome tab group or an Arc folder. Nested Arc folders arrive flat
    /// with parents joined by " › ", the way `Groups` already draws them.
    struct Group: Hashable, Identifiable {
        var id = UUID()
        var name: String
        /// 0…1 on the same wheel as `Space.hue` / `TabGroup.hue`, or nil.
        var hue: Double? = nil
        /// Shut in the column. Arc: shut unless one of its windows has it open.
        var collapsed = false
        /// How many of its parent's tabs come before it — where an empty
        /// folder stands. Nil is at the foot.
        var slot: Int? = nil
    }

    /// One Copper space to be. Chrome: one per window (named after its
    /// profile, "Chrome" or "Chrome · Work"). Arc: one per Arc space.
    struct Space: Hashable, Identifiable {
        var id = UUID()
        var name: String
        var hue: Double? = nil
        /// Arc: the space's look and its emoji.
        var theme: SpaceTheme? = nil
        var icon: String? = nil
        var groups: [Group] = []
        var tabs: [Tab] = []
        /// The Chromium profile folder (e.g. "Default", "Profile 1") whose
        /// cookies and logins belong to these tabs. nil = the source's first.
        var profile: String? = nil
    }

    /// A cookie from the other jar, already decrypted. Built into an
    /// `HTTPCookie` at merge time.
    struct Cookie: Hashable {
        var domain: String   // host_key as Chromium stores it (leading dot allowed)
        var name: String
        var value: String
        var path: String
        var expires: Date?   // nil = session cookie
        var secure: Bool
        var httpOnly: Bool
        /// "Lax" | "Strict" | "None" | nil
        var sameSite: String?
        var profile: String? = nil
    }

    /// A passkey from Chromium's Google Password Manager.
    struct Passkey: Hashable {
        var credentialId: Data
        var rpId: String
        var userHandle: Data
        var userName: String
        var displayName: String
        /// Raw 32-byte P-256 private scalar, ready for PasskeyStore.
        var privateKey: Data
        var created: Date?
        var lastUsed: Date?
        var profile: String? = nil
    }

    /// A Web Store extension the other browser had on.
    struct Extension: Hashable, Identifiable {
        var id: String       // 32-letter store id
        var name: String
        var version: String
        var enabled: Bool
        var fromStore: Bool
    }

    /// What a reader found. Every field optional in spirit: an empty array
    /// means "nothing there", never "failed" — a reader that cannot read
    /// throws instead.
    struct Haul: Equatable {
        var spaces: [Space] = []
        var cookies: [Cookie] = []
        var extensions: [Extension] = []
        var passkeys: [Passkey] = []
        /// Counted without decrypting; the actual keys arrive during the move.
        var passkeyCount = 0
        var bookmarkCount = 0
        var placeCount = 0
        /// Saved passwords, counted without the key.
        var loginCount = 0
        /// Free-text notes for the report ("3 windows", "7 spaces, 283 tabs",
        /// "Arc Safe Storage refused").
        var notes: [String] = []
        /// Why no spaces could be read at all, in the summary's words
        /// ("couldn't read Chrome's open tabs"); nil when they were read.
        var tabsTrouble: String? = nil
        /// Safari's own counts (Reading List, pins, cards, its extensions,
        /// whether its files and an export were read); nil for Chrome or Arc.
        var safari: FlowSafari.Look? = nil

        var tabCount: Int { spaces.reduce(0) { $0 + $1.tabs.count } }
        var groupCount: Int { spaces.reduce(0) { $0 + $1.groups.count } }
    }

    /// What the user ticked. Everything on by default: a move is a move.
    struct Choice: Equatable {
        var tabs = true       // open tabs, spaces, groups, pins
        var bookmarks = true  // via upstream Chromium.bookmarks + icons
        var history = true    // via upstream Chromium.places
        var passwords = true  // via upstream Chromium.read (keychain prompt)
        var cookies = true    // signed-in state
        var localStorage = true // what sites keep in the page (FlowLocalStorage, no prompt)
        var passkeys = true   // Google Password Manager passkeys
        var extensions = true // Web Store extensions, reinstalled from the store

        /// Fork (move-in-polish): what can actually come from this read — a
        /// switch for something the browser has none of is off, so the move
        /// and its summary never list "Arc has none". Sign-ins and site data
        /// aren't counted before the move, so they stay as chosen. Nil: no
        /// counts yet, nothing changes.
        func fitted(to haul: Haul?) -> Choice {
            guard let haul else { return self }
            var out = self
            if haul.tabCount == 0 { out.tabs = false }
            if haul.bookmarkCount == 0 { out.bookmarks = false }
            if haul.placeCount == 0 { out.history = false }
            if haul.loginCount == 0 { out.passwords = false }
            if haul.passkeyCount == 0 { out.passkeys = false }
            if haul.extensions.isEmpty { out.extensions = false }
            return out
        }

        var anything: Bool { tabs || bookmarks || history || passwords || cookies || localStorage || passkeys || extensions }

        /// The big button, naming what it brings: "Bring over 3 tabs",
        /// "Bring over 3 tabs and 120 bookmarks", "… and more" past two.
        /// Only counted things are named; sign-ins alone say so.
        func button(for haul: Haul?) -> String {
            guard let haul else { return "Bring it all over" }
            var parts: [String] = []
            if tabs { parts.append(FlowSummary.plural(haul.tabCount, "tab")) }
            if bookmarks { parts.append(FlowSummary.plural(haul.bookmarkCount, "bookmark")) }
            if passwords { parts.append(FlowSummary.plural(haul.loginCount, "password")) }
            if history { parts.append("history") }
            if passkeys { parts.append(FlowSummary.plural(haul.passkeyCount, "passkey")) }
            if extensions { parts.append(FlowSummary.plural(haul.extensions.count, "extension")) }
            if parts.isEmpty { return cookies || localStorage ? "Bring over sign-ins" : "Nothing to bring" }
            if parts.count == 1 { return "Bring over \(parts[0])" }
            if parts.count == 2 { return "Bring over \(parts[0]) and \(parts[1])" }
            return "Bring over \(parts[0]), \(parts[1]) and more"
        }
    }

    enum Trouble: LocalizedError {
        case notInstalled(String)
        case unreadable(String)
        case keyRefused(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let n): return "\(n) isn't on this Mac"
            case .unreadable(let what): return "Couldn't read \(what)"
            case .keyRefused(let n): return "macOS didn't hand over \(n)'s key — allow it and try again"
            }
        }
    }

    /// Chromium's clock: microseconds since 1601-01-01.
    static func date(chromium micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    /// Arc's clock: seconds since 2001-01-01 (Cocoa reference date).
    static func date(arc seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}
