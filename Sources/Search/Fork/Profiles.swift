import Foundation
import WebKit

// Fork (ardia profiles): which profile a page, a cookie jar or a moment
// belongs to.
//
// A profile is a name a space wears (`Space.profile`). Its pages sign in
// with a cookie jar of their own (`Spaces.store(forProfile:)`), and since
// Ardia parity they keep their own extensions (Extensions.swift: one
// controller per profile), saved passwords (Vault.swift: a keychain drawer
// per profile) and history (History.swift: each place says which profiles
// went there).
//
// Shared — no name — is the drawer every space without a profile uses, and
// what is kept there reaches every profile: extensions installed and
// passwords saved before profiles had their own stay where every profile
// sees them. What a profile adds stays in that profile.
enum Profiles {
    /// A profile named for one read or save, over the window in front: ""
    /// is Shared. A fill, a save or an extension's history call wraps its
    /// work in `$bound.withValue(…)` for the tab it is for.
    @TaskLocal static var bound: String?

    /// The profile in play: the bound one, else the window in front's.
    @MainActor static var current: String? {
        if let bound { return bound.isEmpty ? nil : bound }
        return front
    }

    /// The profile in play for code that isn't main-actor isolated (the
    /// keychain): the bound one, else the window in front's on the main
    /// thread, else Shared.
    static var ambient: String? {
        if let bound { return bound.isEmpty ? nil : bound }
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { front }
    }

    /// The key a profile is bound and stored under ("" for Shared).
    static func key(_ profile: String?) -> String { profile ?? "" }

    /// The profile of the page in front.
    @MainActor static var front: String? { shown(in: Windows.current) }

    /// The profile of a window's page: its tab's jar, or, with no page
    /// there, the space it shows.
    @MainActor static func shown(in browser: Browser) -> String? {
        if let tab = browser.active, !tab.shy, tab.jar != nil { return of(tab) }
        return Spaces.shared.space(in: browser).profile
    }

    /// The profile a tab's page signs in with, by its cookie jar — so a pin
    /// shown in another space is still its own space's. Nil: Shared (and a
    /// shy tab, which keeps nothing).
    @MainActor static func of(_ tab: Tab?) -> String? {
        guard let jar = tab?.jar, jar != "default" else { return nil }
        return byJar[jar]
    }

    /// The profile a web view's store is, for a configuration being built.
    @MainActor static func of(store: WKWebsiteDataStore) -> String? {
        guard let id = store.identifier else { return nil }
        return byJar[id.uuidString]
    }

    /// Whether any space wears a profile — none, and every tab is Shared's.
    @MainActor static var any: Bool { !byJar.isEmpty }

    /// Jar identifiers by profile name, worked out again only when the
    /// spaces' profiles change.
    @MainActor private static var cache: (names: [String], jars: [String: String]) = ([], [:])
    @MainActor private static var byJar: [String: String] {
        let names = Spaces.shared.all.compactMap(\.profile)
        if names != cache.names {
            cache = (names, Dictionary(names.map { (Spaces.storeID(forProfile: $0).uuidString, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        return cache.jars
    }
}
