import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

/// What holding Control while pressing Tab should choose.
enum TabSwitching: String, CaseIterable, Identifiable {
    case row, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .row: return "Next tab in the row"
        case .recent: return "Most recent tab"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for.
    @Published var bench: Bool {
        didSet { store.set(bench, forKey: "bench") }
    }
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// Titles down the left instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    /// Whether Control-Tab follows the row or the tabs used most recently.
    @Published var tabSwitching: TabSwitching {
        didSet { store.set(tabSwitching.rawValue, forKey: "tabs.switching") }
    }
    /// Fork (swipe-direction): which way two fingers across the column move
    /// it — with them, against them, or as the Mac scrolls (the default).
    @Published var swipeDirection: SwipeDirection {
        didSet { store.set(swipeDirection.rawValue, forKey: "spaces.swipe") }
    }
    /// Tabs nobody has looked at for a while give their page back (Sleep.swift) and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// Fill identities, cards, usernames and matching custom fields as well as sign-ins.
    @Published var fillsEverything: Bool {
        didSet { store.set(fillsEverything, forKey: "autofill.everything") }
    }
    /// Where newly saved passwords go. Fills always merge both backends; the
    /// selected backend only changes the destination of a save offer.
    @Published var passwordsBackend: Credentials.Backend {
        didSet { store.set(passwordsBackend.rawValue, forKey: "passwords.backend") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. Off unless asked for.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // Light unless asked otherwise — the browser was only ever light
        // before this was a choice.
        bench = store.bool(forKey: "bench")
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .light
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance.
        NSApp.appearance = chosen.appearance
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        tabSwitching = store.string(forKey: "tabs.switching").flatMap(TabSwitching.init) ?? .row
        swipeDirection = store.string(forKey: "spaces.swipe").flatMap(SwipeDirection.init) ?? .system
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        store.set(entitled, forKey: "passkeys.entitled")
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? (Preferences.testFolder(store.string(forKey: "downloads"), world: Store.folder.path) ?? testDownloads) // Fork (settings-browse)
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        fillsEverything = store.object(forKey: "autofill.everything") as? Bool ?? true
        passwordsBackend = store.string(forKey: "passwords.backend")
            .flatMap(Credentials.Backend.init(rawValue:)) ?? .keychain
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        let corrects = store.bool(forKey: "autocorrect")
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// Fork (settings-browse): a folder a test run chose for itself — inside
    /// its own world folder or under /tmp — is kept across its relaunch like
    /// a person's choice; anything else (~/Downloads above all) still is not.
    static func testFolder(_ path: String?, world: String) -> URL? {
        guard let path, !path.contains("/../") else { return nil }
        let inside = [world + "/", "/tmp/", "/private/tmp/"].contains { path.hasPrefix($0) }
        return inside ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let values = [
            "WebAutomaticSpellingCorrectionEnabled": autocorrect,
            "WebAutomaticQuoteSubstitutionEnabled": false,
            "WebAutomaticDashSubstitutionEnabled": false,
        ]
        // Fork (settings-browse): a test run shares this app's own defaults
        // with the Copper somebody is using (same bundle id), so it tells
        // WebKit in the launch's volatile domain, which WebKit reads first
        // and nothing writes to disk.
        if Store.testing {
            let defaults = UserDefaults.standard
            var launch = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            for (key, value) in values { launch[key] = value }
            defaults.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
            return
        }
        let defaults = UserDefaults.standard
        for (key, value) in values { defaults.set(value, forKey: key) }
    }
}
