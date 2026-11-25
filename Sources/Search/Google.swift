import Foundation

// What to do with words that aren't a place: ask the search engine.
//
// The field still tells an address from a phrase — typing a domain goes
// straight there, without a round trip through anyone's results page. Only
// what can't be a place gets searched.
//
// Fork (omnibox): the name is upstream's. The engine is the one picked in
// Settings › General (Fork/SearchEngines.swift), and a !bang goes to its site.

enum Google {
    static var name: String { SearchEngines.current.name }

    /// A place if it can be one, a search if it can't. A `.new` shortcut
    /// typed in full is the place it names.
    static func destination(for typed: String) -> URL? {
        QuickNew.url(typed) ?? Address.url(from: typed) ?? url(for: typed)
    }

    static func url(for text: String) -> URL? { SearchEngines.search(text)?.url }
}
