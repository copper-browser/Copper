import Foundation
import WebKit

// Fork (secret-redact): a secret Copper put into a page never comes back out
// to an agent.
//
// Copper fills passwords, one-time codes, card numbers and codes, new
// passwords and hidden vault fields for agents (browser_sign_in,
// browser_autofill, Jev's SIGN_IN) and for the user (the saved-account list
// under a box) without ever returning them. Two layers keep them from coming
// back out by another road:
//
//  1. Structure. The page scripts (Page.helper, Ultrafast.script) print the
//     value of a secret box — a password box, one whose autocomplete promises
//     a password, a one-time code, a card number or its code, or one Copper
//     filled with a secret (Forms.script keeps those in a WeakSet in Copper's
//     own content world) — as `placeholder`, never as itself.
//  2. Words. Every secret string Copper filled is remembered here, in memory,
//     per tab, for the tab's life, and any occurrence of it (raw,
//     JSON-escaped, URL-encoded, HTML-escaped) is replaced by `placeholder` in
//     whatever an agent or a model is handed: every tool's answer and error
//     (Tools.call), the Jev request (Jev.ask), the router's (Router.ask), the
//     agent pane's page context and request, the progress a linked app sees
//     (JevProgress.cap) and the driver timeline (Drive). That is what catches
//     a page that copies the password somewhere a structure rule can't see:
//     into a div, the console, an address, another box.
//
// Nothing here is ever written to disk, logged or returned: the store answers
// counts, never strings.

enum AgentSecrets {
    /// What a secret reads as wherever an agent could see it.
    static let placeholder = "•••• (secret, hidden)"

    /// Shorter secrets are not searched for in text: a two-letter "secret"
    /// would rub out half of every answer. Digits-only secrets (a card's
    /// three-digit code, a six-digit one-time code) count from three, and
    /// only standing alone — "123" is not taken out of "41234" or a ref "e123".
    static let shortest = 4
    static let shortestDigits = 3

    private static let lock = NSLock()
    /// Per tab, in the order filled; never written anywhere.
    private static var byTab: [UUID: [String]] = [:]
    /// Every variant of every secret, longest first: rebuilt when the set changes.
    private static var compiled: [Needle]?

    private struct Needle {
        let text: String
        /// Digits only: matched as a whole run of digits.
        let digits: Bool
    }

    // MARK: - the store

    /// A secret Copper is about to put into `tab`'s page. Called before the
    /// fill, so an echo the page makes the instant the value lands is known.
    static func remember(_ secret: String, tab: UUID) {
        guard !secret.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var list = byTab[tab] ?? []
        guard !list.contains(secret) else { return }
        list.append(secret)
        byTab[tab] = list
        compiled = nil
    }

    /// The tab is gone: what it was given goes with it.
    static func forget(tab: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard byTab.removeValue(forKey: tab) != nil else { return }
        compiled = nil
    }

    /// How many secrets `tab` holds (tests and the bench; never the strings).
    static func count(tab: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return byTab[tab]?.count ?? 0
    }

    /// The secrets `tab` holds, long enough to look for — only for the page's
    /// own masking (`masking`), never returned anywhere else.
    fileprivate static func held(_ tab: UUID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (byTab[tab] ?? []).filter { $0.count >= shortest }
    }

    /// Whether any live tab holds a secret: the fast path for every answer.
    static var any: Bool {
        lock.lock(); defer { lock.unlock() }
        return !byTab.isEmpty
    }

    // MARK: - scrubbing

    /// `text` with every known secret — in any of its encodings — replaced by
    /// `placeholder`. Every live tab's secrets, not only the one the call
    /// worked on: a page can hand a value to another tab (a popup, a
    /// redirect), and an answer may name several tabs.
    static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let needles = current()
        guard !needles.isEmpty else { return text }
        return scrub(text, with: needles)
    }

    /// A JSON-shaped value (dictionaries, arrays, strings, numbers) with every
    /// string in it scrubbed, keys too: for a request body, before it is
    /// serialized — so a replacement can never break the JSON around it.
    static func scrub(json value: Any) -> Any {
        let needles = current()
        guard !needles.isEmpty else { return value }
        return walk(value, needles)
    }

    /// A tool's answer: its texts scrubbed (pictures are left as they are).
    static func scrub(_ content: [Tools.Content]) -> [Tools.Content] {
        let needles = current()
        guard !needles.isEmpty else { return content }
        return content.map {
            switch $0 {
            case .text(let s): return .text(scrub(s, with: needles))
            case .image: return $0
            }
        }
    }

    /// What every tool answer passes through on its way out (Tools.call):
    /// the one place the scrub is applied, named so the tests run it too.
    static func outgoing(_ content: [Tools.Content]) -> [Tools.Content] { scrub(content) }

    /// A tool's failure, its words scrubbed — a page's own error text can
    /// quote what it was given. Unchanged errors are passed on as they are.
    static func scrub(error: Error) -> Error {
        let needles = current()
        guard !needles.isEmpty else { return error }
        let text = (error as? Tools.Failure)?.text ?? error.localizedDescription
        let clean = scrub(text, with: needles)
        return clean == text ? error : Tools.Failure(text: clean)
    }

    // MARK: - inside

    private static func current() -> [Needle] {
        lock.lock(); defer { lock.unlock() }
        if let compiled { return compiled }
        var seen = Set<String>()
        var out: [Needle] = []
        for secret in byTab.values.joined() {
            let digits = secret.allSatisfy { $0.isASCII && $0.isNumber }
            guard secret.count >= (digits ? shortestDigits : shortest) else { continue }
            for variant in variants(of: secret) where !variant.isEmpty && seen.insert(variant).inserted {
                out.append(Needle(text: variant, digits: variant.allSatisfy { $0.isASCII && $0.isNumber }))
            }
        }
        // Longest first: a JSON-escaped form is replaced whole before its raw core.
        out.sort { $0.text.count > $1.text.count }
        compiled = out
        return out
    }

    /// The forms a secret takes on its way out of a page: itself, in a JSON
    /// string (with and without `\/`, with non-ASCII as \u escapes, and
    /// escaped twice, as JSON inside JSON), URL-encoded (a component, a form
    /// body, upper- and lowercase hex), HTML-escaped, and a card number
    /// written in groups of four.
    static func variants(of secret: String) -> [String] {
        var out: [String] = [secret]
        func add(_ s: String?) { if let s, !s.isEmpty, !out.contains(s) { out.append(s) } }

        // Foundation writes / as \/; JavaScript's JSON.stringify does not.
        let json = jsonEscaped(secret)
        let plainJSON = json.replacingOccurrences(of: "\\/", with: "/")
        add(json)
        add(plainJSON)
        add(asciiEscaped(plainJSON))
        add(jsonEscaped(plainJSON))
        add(jsonEscaped(plainJSON).replacingOccurrences(of: "\\/", with: "/"))

        let component = percentEncoded(secret, keeping: "-_.!~*'()")
        add(component)
        add(lowerHex(component))
        let form = percentEncoded(secret, keeping: "-_.*", spaceAsPlus: true)
        add(form)
        add(lowerHex(form))
        add(secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))

        add(secret.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;"))

        // A card number as a page shows it: 4242 4242 4242 4242, 4242-4242-…
        if secret.count >= 12, secret.count <= 19, secret.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let groups = stride(from: 0, to: secret.count, by: 4).map { start -> String in
                let a = secret.index(secret.startIndex, offsetBy: start)
                let b = secret.index(a, offsetBy: min(4, secret.count - start))
                return String(secret[a..<b])
            }
            add(groups.joined(separator: " "))
            add(groups.joined(separator: "-"))
        }
        return out
    }

    private static func jsonEscaped(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8), text.count >= 4
        else { return s }
        // ["…"] → …
        return String(text.dropFirst(2).dropLast(2))
    }

    /// Non-ASCII as \uXXXX (UTF-16 units), as many JSON writers put it.
    private static func asciiEscaped(_ json: String) -> String? {
        guard json.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
        var out = ""
        for unit in json.utf16 {
            if unit < 0x80, let scalar = Unicode.Scalar(unit) { out.unicodeScalars.append(scalar) }
            else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }

    private static func percentEncoded(_ s: String, keeping extra: String, spaceAsPlus: Bool = false) -> String {
        var out = ""
        for byte in Array(s.utf8) {
            let c = Character(Unicode.Scalar(byte))
            if byte < 0x80, c.isLetter || c.isNumber || extra.contains(c) {
                out.append(c)
            } else if spaceAsPlus, byte == 0x20 {
                out.append("+")
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func lowerHex(_ encoded: String) -> String? {
        guard encoded.contains("%") else { return nil }
        var out = ""
        var hex = 0
        for ch in encoded {
            if ch == "%" { hex = 2; out.append(ch); continue }
            if hex > 0 { out += ch.lowercased(); hex -= 1 } else { out.append(ch) }
        }
        return out
    }

    private static func scrub(_ text: String, with needles: [Needle]) -> String {
        var text = text
        for needle in needles where text.contains(needle.text) {
            if needle.digits {
                text = replaceDigitRun(needle.text, in: text)
            } else {
                text = text.replacingOccurrences(of: needle.text, with: placeholder)
            }
        }
        return text
    }

    /// `run` replaced wherever it stands alone: no letter or digit either side.
    private static func replaceDigitRun(_ run: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9A-Za-z])" + NSRegularExpression.escapedPattern(for: run) + "(?![0-9A-Za-z])") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }

    private static func walk(_ value: Any, _ needles: [Needle]) -> Any {
        switch value {
        case let s as String:
            return scrub(s, with: needles)
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[scrub(k, with: needles)] = walk(v, needles) }
            return out
        case let list as [Any]:
            return list.map { walk($0, needles) }
        default:
            return value
        }
    }
}

// MARK: - pictures

extension AgentSecrets {
    /// A picture can't be scrubbed after it is taken, so before one is taken
    /// of a page that holds a secret Copper filled, whatever shows that secret
    /// as plain text — a box that is no password box, words the page wrote —
    /// is drawn masked (bullets in a box, invisible ink in words), in every
    /// frame the page has; `unmask` puts it back. The secrets go only to
    /// Copper's own world in the page, where they were filled; the answer is
    /// a count.
    static let maskScript = """
    const turnOn = !!masking, held = (secrets || []).filter(s => typeof s === 'string' && s.length >= 4);
    const kept = window.__copperMasked || (window.__copperMasked = []);
    if (!turnOn) { for (const [el, prop, value, priority] of kept.splice(0)) { try { el.style.setProperty(prop, value, priority); } catch (e) {} } return 0; }
    const has = s => !!s && held.some(x => String(s).includes(x));
    const mask = (el, prop, value) => { kept.push([el, prop, el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)]); el.style.setProperty(prop, value, 'important'); };
    const marked = window.__copperSecretFields;
    let n = 0;
    for (const el of document.querySelectorAll('input, textarea')) {
      const type = String(el.type).toLowerCase();
      if (type === 'password' || type === 'hidden') continue;
      if (has(el.value) || (el.value && marked && marked.has(el))) { mask(el, '-webkit-text-security', 'disc'); mask(el, 'color', 'transparent'); n++; }
    }
    if (document.body && held.length) {
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let node = walk.nextNode(); node; node = walk.nextNode()) {
        const parent = node.parentElement;
        if (parent && has(node.textContent)) { mask(parent, 'color', 'transparent'); mask(parent, 'text-shadow', 'none'); n++; }
      }
    }
    return n;
    """

    /// Mask (or, `on: false`, unmask) what shows `tab`'s secrets, in the page
    /// and the frames it has. Answers how many things were masked.
    @MainActor @discardableResult
    static func masking(_ tab: Tab, on: Bool) async -> Int {
        guard count(tab: tab.id) > 0, let web = tab.built else { return 0 }
        let secrets = held(tab.id)
        var frames: [WKFrameInfo?] = [nil]
        frames += await Tools.Frames.live(web).map { Optional($0.info) }
        var masked = 0
        for frame in frames {
            let n = try? await Tools.Page.call(web, maskScript, ["masking": on, "secrets": secrets], timeout: 3,
                                               late: "masking timed out", counted: false, in: frame, world: .copper)
            masked += (n as? NSNumber)?.intValue ?? 0
        }
        return masked
    }
}
