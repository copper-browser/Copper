import AppKit
import SwiftUI

// Fork (page-tools): links copied without the trackers riding on them.
//
// A copied address loses the parameters that only follow you around —
// utm_*, fbclid, gclid and their kin, and a few that mean tracking only on
// one site (YouTube's and Spotify's `si`) — and keeps every other one, in
// the order and spelling it had, so the page still opens as it was. Used by
// ⇧⌘C, the page's Copy Link (ImageMenu.swift), Copy as Markdown (⌥⇧⌘C),
// Copy Link to Highlight and Share (Fork/PageShare.swift).
// Checked by Tests/SearchTests/CleanLinksTests.swift and `./bench page clean URL`.

enum CleanLinks {
    /// Dropped on every site: click ids and campaign tags no page needs to show itself.
    static let everywhere: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid", "srsltid", "_ga", "_gl",
        "msclkid", "twclid", "ttclid", "li_fat_id", "yclid", "ysclid", "rdt_cid", "epik", "igshid", "ref_src",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok",
        "oly_anon_id", "oly_enc_id", "_openstat", "vero_id", "vero_conv", "wickedid", "rb_clickid", "s_cid",
        "irclickid", "cjevent", "sscid", "elqtrackid", "elqtrack", "trk_contact", "trk_msg", "trk_module", "trk_sid",
    ]

    /// Whole families: utm_source, mtm_campaign, pk_kwd, hsa_acc…
    static let prefixes = ["utm_", "mtm_", "pk_", "hsa_"]

    /// Tracking on these sites (and their subdomains) only: elsewhere the
    /// same name can be what the page needs (`si`, `s`, `ref`, `source`).
    static let sites: [(hosts: [String], names: Set<String>, prefixes: [String])] = [
        (["youtube.com", "youtu.be"], ["si", "pp", "feature"], []),
        (["open.spotify.com"], ["si", "nd", "context"], []),
        (["instagram.com"], ["igsh", "img_index"], []),
        (["x.com", "twitter.com"], ["s", "t", "ref_url"], []),
        (["threads.net", "threads.com"], ["xmt", "slof"], []),
        (["tiktok.com"], ["is_from_webapp", "sender_device", "sender_web_id", "_r", "_t"], []),
        (["linkedin.com"], ["trk", "trackingid", "lipi", "midtoken", "midsig", "trkemail"], []),
        (["reddit.com"], ["share_id", "ref_source", "ref_campaign"], []),
        (["medium.com"], ["source"], []),
        (["facebook.com"], ["mibextid", "sfnsn", "rdid"], []),
        (["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.ca", "amazon.co.jp", "amazon.in", "amazon.com.au"],
         ["ref", "ref_", "tag", "_encoding", "linkcode", "linkid", "camp", "creative", "creativeasin", "content-id", "crid", "sprefix", "qid", "sr", "dib", "dib_tag"],
         ["pd_rd_", "pf_rd_"]),
    ]

    /// Whether `name` (already lowercased) only tracks, on `host`.
    static func tracks(_ name: String, on host: String) -> Bool {
        if everywhere.contains(name) || prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return sites.contains { site in
            site.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
                && (site.names.contains(name) || site.prefixes.contains { name.hasPrefix($0) })
        }
    }

    /// The address without its trackers; anything that isn't http(s), or has
    /// none, comes back as it was. Only the query changes (the fragment stays,
    /// even one with `?utm_` in it), and only when a tracker was in it.
    static func strip(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { return url }
        let text = url.absoluteString
        let hash = text.firstIndex(of: "#") ?? text.endIndex
        guard let mark = text[..<hash].firstIndex(of: "?") else { return url }
        let pairs = text[text.index(after: mark)..<hash].split(separator: "&", omittingEmptySubsequences: false)
        func tracker(_ pair: Substring) -> Bool {
            let raw = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let name = (raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(raw)).lowercased()
            return !name.isEmpty && tracks(name, on: host)
        }
        guard pairs.contains(where: tracker) else { return url }
        let query = pairs.filter { !$0.isEmpty && !tracker($0) }.joined(separator: "&")
        return URL(string: String(text[..<mark]) + (query.isEmpty ? "" : "?" + query) + text[hash...]) ?? url
    }

    /// `[title](address)`, the address cleaned. The label stays on one line
    /// and its brackets are escaped; the address's parentheses and angle
    /// brackets are percent-encoded, so every Markdown reader ends the link
    /// where it ends (a Wikipedia `…_(film)` included).
    static func markdown(title: String, url: URL) -> String {
        let address = strip(url).absoluteString
        let line = title.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        var label = ""
        for character in line.isEmpty ? address : line {
            if "\\[]".contains(character) { label.append("\\") }
            label.append(character)
        }
        let destination = address
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
        return "[\(label)](\(destination))"
    }

    /// The address with a text fragment (`#:~:text=`) that scrolls to and
    /// marks `quote` when it opens. A short quote on one line goes in whole;
    /// a longer one, or one across paragraphs (a match can't cross a block),
    /// as its first and last few words (`text=start,end`). Nil without words.
    static func highlight(_ url: URL, quote: String) -> URL? {
        let lines = quote.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { return nil }
        let words = { (line: String) in line.split(separator: " ").map(String.init) }
        let directive: String
        if lines.count == 1, first.count <= 300 || words(first).count < 10 {
            directive = fragment(first)
        } else {
            let start = words(first).prefix(5).joined(separator: " ")
            let end = words(last).suffix(5).joined(separator: " ")
            directive = fragment(start) + "," + fragment(end)
        }
        // An older directive goes; the page's own fragment (`#section`) stays in front.
        let text = strip(url).absoluteString
        let hash = text.firstIndex(of: "#")
        var own = hash.map { String(text[text.index(after: $0)...]) } ?? ""
        if let directives = own.range(of: ":~:") { own = String(own[..<directives.lowerBound]) }
        return URL(string: String(text[..<(hash ?? text.endIndex)]) + "#" + own + ":~:text=" + directive)
    }

    /// Percent-encoded for a text directive: only ASCII letters, digits and
    /// `._~` stay, so its own `-`, `,` and `&` can't be misread.
    private static func fragment(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")
        return text.addingPercentEncoding(withAllowedCharacters: plain) ?? text
    }

    /// Onto the pasteboard as text and as a link (a probe world's own, in a
    /// test run: SettingsActions.pasteboard), cleaned; what was copied.
    @MainActor @discardableResult
    static func copy(_ url: URL, title: String? = nil) -> URL {
        let clean = strip(url)
        let item = NSPasteboardItem()
        item.setString(clean.absoluteString, forType: .string)
        item.setString(clean.absoluteString, forType: .URL)
        if let title, !title.isEmpty { item.setString(title, forType: NSPasteboard.PasteboardType("public.url-name")) }
        let board = SettingsActions.pasteboard
        board.clearContents()
        board.writeObjects([item])
        return clean
    }
}

extension Browser {
    /// ⌥⇧⌘C: the page as a Markdown link, `[title](address)`.
    func copyMarkdownLink() {
        guard let tab = active, let url = tab.address else { return }
        SettingsActions.copy(CleanLinks.markdown(title: tab.title, url: url))
        announce("Copied as Markdown")
    }

    /// The address with a text fragment for what is selected on the page, so
    /// the link opens scrolled to it with it marked. `done` gets the link.
    func copyHighlightLink(done: ((URL?) -> Void)? = nil) {
        guard let tab = active, let url = tab.address, let web = tab.built else { done?(nil); return }
        web.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')", in: nil, in: .copper) { [weak self] result in
            let quote = (try? result.get()) as? String ?? ""
            guard let link = CleanLinks.highlight(url, quote: quote) else {
                self?.announce("Select some text on the page first")
                done?(nil)
                return
            }
            CleanLinks.copy(link, title: tab.title)
            self?.announce("Link to highlight copied")
            done?(link)
        }
    }
}

/// Tabs › Copy as Markdown and Copy Link to Highlight, under Copy Address (App.swift).
struct CopyLinkItems: View {
    let browser: Browser

    var body: some View {
        Button("Copy as Markdown") { browser.copyMarkdownLink() }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(browser.active?.isBlank ?? true)
        Button("Copy Link to Highlight") { browser.copyHighlightLink() }
            .disabled(browser.active?.isBlank ?? true)
    }
}
