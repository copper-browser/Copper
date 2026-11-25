import AppKit
import SwiftUI

// Fork (page-tools): File › Share…, the page tools' ⌘K rows, and their bench
// verb, `./bench page …`. The tools themselves: Fork/CleanLinks.swift (clean
// copies, Markdown, highlight links) and Fork/Translate.swift.

extension Browser {
    /// File › Share…: the system's share picker for the page's clean address,
    /// at the top of the page.
    func sharePage() {
        guard let tab = active, let url = tab.address, let view = tab.built, view.window != nil else { return }
        let picker = NSSharingServicePicker(items: [CleanLinks.strip(url) as NSURL])
        picker.delegate = PageShare.shared
        PageShare.shared.picker = picker
        let top = NSRect(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: top, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}

/// The share picker's delegate: what it offered, for the bench.
@MainActor
final class PageShare: NSObject, NSSharingServicePickerDelegate {
    static let shared = PageShare()
    var picker: NSSharingServicePicker?
    var offered: [String] = []

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                                          proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        let titles = proposed.map(\.title)
        MainActor.assumeIsolated { offered = titles } // AppKit asks on the main thread
        return proposed
    }
}

/// File › Share…, above Print (App.swift).
struct ShareItem: View {
    let browser: Browser

    var body: some View {
        Button("Share…") { browser.sharePage() }
            .disabled(browser.active?.isBlank ?? true)
    }
}

@MainActor
enum PageTools {
    /// ⌘K's rows for the page in front (Fork/CommandBar.swift).
    static func add(to list: inout [CommandBar.Command], in browser: Browser) {
        guard let tab = browser.active, !tab.isBlank else { return }
        list.append(.init(id: "copy-link", name: "Copy Link", glyph: "link") { $0.copyAddress() })
        list.append(.init(id: "copy-markdown", name: "Copy Link as Markdown", glyph: "text.badge.plus") { $0.copyMarkdownLink() })
        list.append(.init(id: "copy-highlight", name: "Copy Link to Highlight", glyph: "highlighter") { $0.copyHighlightLink() })
        list.append(.init(id: "share-page", name: "Share…", glyph: "square.and.arrow.up") { $0.sharePage() })
        guard PageTranslate.available else { return }
        let translate = PageTranslate.shared
        list.append(.init(id: "translate", name: translate.translated(tab) ? "Show Original" : "Translate Page", glyph: "translate") { translate.toggle(in: $0) })
        list.append(.init(id: "translate-never", name: translate.isNever(tab) ? "Translate This Site Again" : "Never Translate This Site", glyph: "nosign") {
            translate.toggleNever(in: $0)
        })
    }

    /// `./bench page clean URL` · `page copy [address|markdown|highlight]` (the
    /// active tab, into a probe world's own pasteboard) · `page linkmenu
    /// SELECTOR` (the page's contextmenu event on that link, then the menu
    /// WebKit builds with its Copy Link: what that item copies now) · `page
    /// share [close]` · `page translate [LANG]` (answers when the page is done,
    /// or after 20 s with how far it got) · `page original` · `page never` ·
    /// `page state` (the active tab's translation and the menu bar's items).
    static func bench(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "state"
        let arg = request["arg"] as? String ?? ""
        let board = { SettingsActions.pasteboard.string(forType: .string) ?? "" }
        let translate = PageTranslate.shared
        let tab = browser.active
        func state() -> [String: Any] {
            var out: [String: Any] = ["url": tab?.address?.absoluteString ?? "", "translated": translate.translated(tab),
                                      "never": translate.isNever(tab), "menu": menuItems(), "available": PageTranslate.available]
            if let tab, let job = translate.jobs[tab.id] {
                out.merge(["state": job.state, "source": job.source, "target": PageTranslate.name(job.target), "nodes": job.nodes,
                           "lines": job.lines, "answered": job.done, "firstMs": job.firstMs ?? -1, "ms": job.ms ?? -1, "note": job.note,
                           "languages": job.languages, "route": job.route]) { $1 }
            }
            return out
        }
        switch op {
        case "clean":
            guard let url = URL(string: arg) else { return answer(["error": "usage: page clean URL"]) }
            answer(["url": arg, "clean": CleanLinks.strip(url).absoluteString, "markdown": CleanLinks.markdown(title: "Title", url: url)])
        case "copy":
            guard tab?.isBlank == false else { return answer(["error": "no page in front"]) }
            switch arg {
            case "markdown":
                browser.copyMarkdownLink()
                answer(["copied": board(), "said": browser.announcement ?? ""])
            case "highlight":
                browser.copyHighlightLink { _ in answer(["copied": board(), "said": browser.announcement ?? ""]) }
            default:
                browser.copyAddress()
                answer(["url": tab?.address?.absoluteString ?? "", "copied": board(), "said": browser.announcement ?? ""])
            }
        case "linkmenu":
            guard let web = tab?.built else { return answer(["error": "no page in front"]) }
            let js = "var el = document.querySelector(s); if (!el) return false; el.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true, button: 2})); return true;"
            web.callAsyncJavaScript(js, arguments: ["s": arg], in: nil, in: .page) { result in
                let menu = NSMenu()
                let copy = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")
                copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
                menu.addItem(copy)
                ImageRelay.clean(menu)
                let replaced = menu.items.first !== copy
                if replaced { menu.performActionForItem(at: 0) }
                answer(["found": (try? result.get()) as? Bool ?? false, "replaced": replaced, "copied": replaced ? board() : ""])
            }
        case "share":
            if arg == "close" { PageShare.shared.picker?.close(); return answer(["closed": true]) }
            PageShare.shared.offered = []
            browser.sharePage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                answer(["shown": PageShare.shared.picker != nil, "offered": PageShare.shared.offered])
            }
        case "translate":
            guard PageTranslate.available else { return answer(["error": "Translate needs macOS 15"]) }
            guard let tab, tab.built != nil, !tab.isBlank else { return answer(["error": "no page in front"]) }
            translate.ended[tab.id, default: []].append { _ in answer(state()) }
            translate.translate(tab, in: browser, into: arg.isEmpty ? nil : Locale.Language(identifier: arg))
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { answer(state()) }
        case "original":
            if let tab { translate.showOriginal(tab, in: browser) }
            answer(state())
        case "never":
            translate.toggleNever(in: browser)
            answer(["never": translate.isNever(tab), "hosts": translate.never.sorted()])
        default:
            answer(state())
        }
    }

    /// The page tools' items in the menu bar as AppKit has them now: title,
    /// key, enabled, checked.
    static func menuItems() -> [[String: Any]] {
        let ours: Set<String> = ["Copy Address", "Copy as Markdown", "Copy Link to Highlight", "Share…", "Translate Page", "Show Original", "Never Translate This Site"]
        var found: [[String: Any]] = []
        func walk(_ menu: NSMenu?, _ path: String) {
            for item in menu?.items ?? [] {
                if let submenu = item.submenu { walk(submenu, item.title); continue }
                guard ours.contains(item.title) else { continue }
                var mask = item.keyEquivalentModifierMask
                if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) } // "C" is ⇧C to AppKit
                let mods = (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "")
                found.append(["menu": path, "title": item.title, "key": item.keyEquivalent.isEmpty ? "" : mods + item.keyEquivalent.uppercased(),
                              "enabled": item.isEnabled, "checked": item.state == .on])
            }
        }
        walk(NSApp.mainMenu, "")
        return found
    }
}
