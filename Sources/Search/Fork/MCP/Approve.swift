import AppKit
import SwiftUI
import WebKit

// Approve cards: an agent's click, key or submit that would pay, send,
// delete or book waits for the person to say yes (borrowed from Ask:
// "Every payment waits", "Nothing sent in your name").
//
// One gate, `Approve.gate`, sits in front of every committing input an agent
// makes — browser_click, browser_mouse_click_xy, browser_press_key Enter,
// browser_type with submit, and Jev's clicks — just before the trusted event
// goes in. It reads what is at that point in the page (the control, its
// label, and what the page shows near it: amount and card's last four, the
// recipient and the words, how many things go), names the kind
// (`kind(…)`, pure), and decides (`decide(…)`, pure) whether to ask.
//
// Asking puts a card at the foot of the window that owns the tab — who, the
// site, the exact button, what the page shows — and marks the control on the
// page ("I'll click this"); the column's foot says "1 needs you". Approve (↩)
// lets the input go in; Deny (⎋), Stop or two minutes with no answer leave
// it undone and the call fails with words the agent can act on.
//
// Nobody to ask, nobody waits: a headless Copper (SEARCH_HEADLESS, Grunts'
// on the mini, every harness world) lets the input through as before, with
// an `approve-skip` breadcrumb. Test worlds (probe,
// bench, coverage, agentbench) start with every "Ask before" switch off, so
// the safety cases run as they always did; SEARCH_APPROVE=ask turns the gate
// on there, headless included, for the e2e and pictures.

@MainActor
final class Approve: ObservableObject {
    static let shared = Approve()

    /// What waits for a yes. Raw values are the settings' keys (`approve.pay`…).
    enum Kind: String, CaseIterable {
        case pay, send, delete, book

        /// Settings › Agents › Ask before.
        var setting: String {
            switch self {
            case .pay: return "Payments"
            case .send: return "Sending"
            case .delete: return "Deleting"
            case .book: return "Booking"
            }
        }

        /// "Claude wants to pay".
        var verb: String {
            switch self {
            case .pay: return "pay"
            case .send: return "send"
            case .delete: return "delete"
            case .book: return "book"
            }
        }

        var noun: String {
            switch self {
            case .pay: return "payment"
            case .send: return "message"
            case .delete: return "deletion"
            case .book: return "booking"
            }
        }

        var symbol: String {
            switch self {
            case .pay: return "creditcard"
            case .send: return "paperplane"
            case .delete: return "trash"
            case .book: return "calendar"
            }
        }
    }

    enum Verdict: Equatable {
        /// Not a commit, or one the person doesn't want asked about: in it goes.
        case go
        case ask(Kind)
        /// A commit the person wants asked about, with nobody there to ask.
        case skip(Kind, String)
    }

    // MARK: - what it is (pure, tested)

    nonisolated private static func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What committing a control would do, from its words (`label`, plus
    /// its aria-label or title) and the page around it: `link` (an `<a>`
    /// that only goes somewhere), `card` (a card field in its form),
    /// `message` (a message box with words in it near it), `key` (Return
    /// in a field rather than a click). Nil: nothing to ask about.
    nonisolated static func kind(label: String, alt: String = "", link: Bool = false, card: Bool = false, message: Bool = false, key: Bool = false) -> Kind? {
        let words = (label + " " + alt).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if has(words, #"\b(delete|erase|trash|destroy|discard|wipe|permanently remove|remove (account|repo|repository|project|forever|permanently|all))\b"#) { return .delete }
        // A link only goes to a page; the commit is on that page's button.
        if link { return nil }
        if !has(words, #"\b(proceed|go|continue) to (check ?out|payment)\b"#),
           has(words, #"\b(pay|buy|purchase|donate|check ?out|order now|send money|(place|submit|complete|confirm) (your |my |the )?(order|purchase|payment)|confirm and pay)\b|\btransfer \$?\d"#) { return .pay }
        if has(words, #"\b(book|reserve)\b|\b(confirm|complete|finish|make) (the |a |my |your )?(booking|reservation|appointment)\b"#) { return .book }
        // A code to your own phone or inbox is not a message in your name.
        if !has(words, #"\b(re)?send (me )?(a |the |new |another )?(code|link|otp|verification|sms|text)\b"#),
           has(words, #"\b(send|post|publish|reply|tweet|comment)\b"#) { return .send }
        // A word that says nothing ("Submit", "Confirm", Return in a field):
        // the form it sends says what it is. No words at all (a click into
        // a card's frame) asks nothing.
        if key || has(words, #"^\s*(submit|confirm|continue|done|ok|next|finish|complete|place|go)\b"#) {
            if card { return .pay }
            if message { return .send }
        }
        return nil
    }

    /// Whether to ask: only a kind the person asks about, and only when
    /// someone can answer.
    nonisolated static func decide(_ kind: Kind?, asks: Set<Kind>, canAsk: Bool, why: String = "headless") -> Verdict {
        guard let kind, asks.contains(kind) else { return .go }
        return canAsk ? .ask(kind) : .skip(kind, why)
    }

    /// The switches' default: on, except in a test world (probe, bench,
    /// harness), where an unanswered card would stall the run.
    nonisolated static func defaultOn(testing: Bool) -> Bool { !testing }

    /// SEARCH_APPROVE=ask: a test world asks even headless (the e2e, pictures).
    nonisolated static let forced: Bool = Store.testing && ProcessInfo.processInfo.environment["SEARCH_APPROVE"]?.lowercased() == "ask"

    nonisolated static func asking(_ kind: Kind) -> Bool {
        if forced { return true }
        return Store.settings.object(forKey: "approve." + kind.rawValue) as? Bool ?? defaultOn(testing: Store.testing)
    }

    nonisolated static var wanted: Set<Kind> { Set(Kind.allCases.filter(asking)) }

    /// How long a card waits before it counts as no.
    static var timeout: TimeInterval {
        let set = Store.settings.double(forKey: "approve.timeout")
        return Store.testing && set > 0 ? set : 120
    }

    // MARK: - the cards

    struct Ask: Identifiable, Equatable {
        let id = UUID()
        let tab: UUID
        let agent: String
        let kind: Kind
        let host: String
        /// The control's own words, exactly.
        let label: String
        var amount = ""
        var card = ""
        var to = ""
        var text = ""
        var count = ""
    }

    @Published private(set) var asks: [Ask] = []
    private var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]

    /// True for Approve, false for Deny, nil when the time ran out.
    private func wait(_ ask: Ask, timeout: TimeInterval) async -> Bool? {
        if !NSApp.isActive, !Headless.on { NSApp.requestUserAttention(.criticalRequest) }
        let id = ask.id
        let answer: Bool? = await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Bool?, Never>) in
                waiters[id] = resume
                asks.append(ask)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.finish(id, nil)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, false) }
        }
        return answer
    }

    private func finish(_ id: UUID, _ answer: Bool?) {
        asks.removeAll { $0.id == id }
        waiters.removeValue(forKey: id)?.resume(returning: answer)
    }

    /// From the card, its keys or the bench.
    func answer(_ id: UUID, approve: Bool) { finish(id, approve) }

    /// Stop on the run: every card on its tab is a no.
    func deny(tab: UUID) { for ask in asks where ask.tab == tab { finish(ask.id, false) } }

    func asks(in browser: Browser) -> [Ask] {
        asks.filter { ask in AgentTabs.find(ask.tab).map { AgentTabs.owner(of: $0) === browser } ?? false }
    }

    /// ↩ approves and ⎋ denies the card of the page in front — never one
    /// on another tab, where Return belongs to whatever you are typing.
    func key(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let ask = asks(in: browser).first,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              [36, 76, 53].contains(event.keyCode),
              browser.activeID == ask.tab || Split.shared.has(ask.tab) else { return false }
        answer(ask.id, approve: event.keyCode != 53)
        return true
    }

    /// `bench agent approve [yes|no]`: what waits, or answer the oldest.
    func bench(_ arg: String) -> [String: Any] {
        if let first = asks.first, ["yes", "no", "approve", "deny"].contains(arg) { answer(first.id, approve: arg == "yes" || arg == "approve") }
        return ["asks": asks.map { ["kind": $0.kind.rawValue, "agent": $0.agent, "host": $0.host, "label": $0.label, "amount": $0.amount,
                                    "card": $0.card, "to": $0.to, "text": $0.text, "count": $0.count] },
                "asking": Kind.allCases.filter(Self.asking).map(\.rawValue), "forced": Self.forced, "timeout": Self.timeout]
    }

    // MARK: - the gate

    /// The user said no (or nothing): the input never went in.
    struct Denied: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Before an agent's click at `point` (viewport CSS px), or its Return
    /// in the focused field (`point` nil): asks when it pays, sends, deletes
    /// or books and the person wants to be asked. Returns the line for the
    /// tool's answer when the person approved, nil when nothing was asked;
    /// throws `Denied` when they said no or nothing.
    @discardableResult
    static func gate(_ tab: Tab, at point: CGPoint?) async throws -> String? {
        let asking = wanted
        guard !asking.isEmpty else { return nil }
        let web = tab.web
        guard let seen = try? await Tools.Page.raw(web, look(point), counted: false) as? [String: Any],
              let label = seen["label"] as? String else { return nil }
        let found = kind(label: label, alt: seen["alt"] as? String ?? "", link: seen["link"] as? Bool == true,
                        card: seen["card"] as? Bool == true, message: seen["message"] as? Bool == true, key: point == nil)
        // Windowed, someone can come back to the card, even to a window
        // hidden behind another app: it waits, and the Dock icon bounces.
        let canAsk = forced || !Headless.on
        let host = tab.address?.host() ?? (seen["host"] as? String ?? "")
        switch decide(found, asks: asking, canAsk: canAsk, why: "headless") {
        case .go:
            return nil
        case .skip(let kind, let why):
            Breadcrumbs.note("approve-skip", [("kind", kind.rawValue), ("host", host), ("why", why)])
            return nil
        case .ask(let kind):
            let shown = label.isEmpty ? "Return" : label
            var ask = Ask(tab: tab.id, agent: DriveCaller.who?.agent ?? Drive.shared.run?.who.agent ?? "An agent",
                          kind: kind, host: host, label: shown)
            // What the card shows: read only now, a whole-page read no ordinary click pays for.
            let more = (try? await Tools.Page.raw(web, look(point, full: true), counted: false) as? [String: Any]) ?? seen
            ask.amount = more["amount"] as? String ?? ""
            ask.card = more["last4"] as? String ?? ""
            ask.to = more["to"] as? String ?? ""
            ask.text = more["text"] as? String ?? ""
            ask.count = more["count"] as? String ?? ""
            // Ask's "I'll click this": the control, outlined and named on the page while the card waits.
            Tools.Trail.target(web, rect: seen["rect"] as? [String: Any], label: "I'll click this", operation: "")
            Breadcrumbs.note("approve-ask", [("kind", kind.rawValue), ("host", host)])
            let answer = await shared.wait(ask, timeout: timeout)
            Breadcrumbs.note("approve-answer", [("kind", kind.rawValue), ("answer", answer.map { $0 ? "yes" : "no" } ?? "timeout")])
            let what = "\(Tools.pageWords(shown, limit: 60)) on \(host)"
            switch answer {
            case true?:
                return "The user approved this \(kind.noun) (\(what))."
            case false?:
                throw Denied(text: "The user denied this \(kind.noun): \(what) was not clicked. Don't try it again another way; tell the user in your reply.")
            case nil:
                throw Denied(text: "No answer from the user in \(Int(timeout)) s, so this \(kind.noun) counts as denied: \(what) was not clicked. Ask the user before trying again.")
            }
        }
    }

    /// The page's side: what is at (x, y), or what Return in the focused
    /// field would send. Copper's world, no helper needed; through open
    /// shadow roots and same-origin frames. Page words are only read here,
    /// never run. Cheap unless `full`: the label and the form's kind of
    /// fields, on every agent click; `full` adds what the card shows.
    static func look(_ point: CGPoint?, full: Bool = false) -> String {
        let at = point.map { "[\($0.x), \($0.y)]" } ?? "null"
        return """
        (function (at, full) {
          var CONTROL = 'button,a[href],input[type=submit],input[type=button],input[type=image],[role=button],[role=link],[role=menuitem],summary';
          var MONEY = /(?:[$€£¥₹]\\s?\\d[\\d,]*(?:\\.\\d{1,2})?|\\d[\\d,]*(?:\\.\\d{2})?\\s?(?:USD|EUR|GBP|CAD|AUD|CHF|JPY))/;
          var dx = 0, dy = 0;
          function squeeze(s, n) { return String(s || '').replace(/\\s+/g, ' ').trim().slice(0, n || 120); }
          function deep(d, x, y) {
            var h = d.elementFromPoint(x, y);
            while (h && h.shadowRoot) { var i = h.shadowRoot.elementFromPoint(x, y); if (!i || i === h) break; h = i; }
            if (h && /^I?FRAME$/.test(h.tagName)) {
              try { var r = h.getBoundingClientRect(), inner = h.contentDocument; if (inner) { dx += r.left; dy += r.top; return deep(inner, x - r.left, y - r.top); } } catch (e) {}
            }
            return h;
          }
          function focused() {
            var a = document.activeElement;
            for (;;) {
              var n = a && a.shadowRoot && a.shadowRoot.activeElement;
              if (!n && a && /^I?FRAME$/.test(a.tagName)) { try { var r = a.getBoundingClientRect(); n = a.contentDocument && a.contentDocument.activeElement; if (n) { dx += r.left; dy += r.top; } } catch (e) {} }
              if (!n || n === a) return a;
              a = n;
            }
          }
          function parent(n) { return n.parentElement || (n.getRootNode && n.getRootNode().host) || null; }
          function closest(n, sel) { for (; n; n = parent(n)) if (n.matches && n.matches(sel)) return n; return null; }
          function words(e) {
            if (!e) return '';
            if (e.tagName === 'INPUT' && /^(submit|button|image)$/i.test(e.type)) return squeeze(e.value || e.alt);
            return squeeze(e.innerText || e.textContent);
          }
          function value(e) { return e ? squeeze(e.isContentEditable ? e.innerText : e.value, 400) : ''; }
          var el = null, field = null;
          if (at) {
            var hit = deep(document, at[0], at[1]);
            el = hit && (closest(hit, CONTROL) || hit);
          } else {
            field = focused();
            var form0 = field && field !== document.body && (field.form || closest(field, 'form'));
            el = form0 ? form0.querySelector('button[type=submit],button:not([type]),input[type=submit],input[type=image]') : null;
            if (!el && field && field !== document.body) {
              // A chat box with no form: Return sends, as the Send button beside it would.
              for (var n = parent(field), i = 0; n && i < 6 && !el; n = parent(n), i++) {
                var bs = n.querySelectorAll ? n.querySelectorAll('button,[role=button]') : [];
                for (var j = 0; j < bs.length; j++) if (/\\b(send|post|reply|comment|tweet)\\b/i.test(words(bs[j]) + ' ' + (bs[j].getAttribute('aria-label') || ''))) { el = bs[j]; break; }
              }
            }
            if (field === document.body) field = null;
          }
          if (!el && !field) return null;
          var anchor = el || field;
          var form = anchor.form || closest(anchor, 'form') || (field && (field.form || closest(field, 'form')));
          // Where to look round it: its form, else the nearest box that has a field in it.
          var scope = form;
          for (var s = parent(anchor), k = 0; !scope && s && k < 8; s = parent(s), k++) {
            if (s.querySelector && s.querySelector('textarea,[contenteditable=""],[contenteditable=true],input:not([type=hidden]):not([type=submit]):not([type=button])')) scope = s;
          }
          var doc = anchor.ownerDocument || document;
          scope = scope || doc.body || doc.documentElement;
          var card = !!scope.querySelector('input[autocomplete^=cc-],input[name*=cardnumber i],input[name*=card_number i],input[name*=cc-num i],input[id*=cardnumber i],input[id*=card-number i],iframe[src*=stripe],iframe[name*=card i],iframe[title*="card" i]');
          var box = field && (field.tagName === 'TEXTAREA' || field.isContentEditable) ? field : null;
          if (!box) { var boxes = scope.querySelectorAll('textarea,[contenteditable=""],[contenteditable=true]'); for (var b = 0; b < boxes.length && !box; b++) if (value(boxes[b])) box = boxes[b]; }
          var label = el ? words(el) : '';
          var alt = el ? squeeze((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('title') || '')) : '';
          var href = el && el.tagName === 'A' ? String(el.getAttribute('href') || '') : '';
          var r = anchor.getBoundingClientRect();
          var out = {
            label: label, alt: alt, host: location.host,
            link: !!href && !/^(javascript:|#)/i.test(href) && el.getAttribute('role') !== 'button',
            card: card, message: !!(box && value(box)),
            rect: {x: r.left + dx, y: r.top + dy, w: r.width, h: r.height}
          };
          if (!full) return out;
          var page = String(doc.body ? doc.body.innerText : '');
          var number = scope.querySelector('input[autocomplete=cc-number],input[name*=cardnumber i],input[name*=card_number i],input[id*=cardnumber i],input[id*=card-number i]');
          var digits = number ? String(number.value || '').replace(/\\D/g, '') : '';
          out.last4 = digits.length >= 12 ? digits.slice(-4) : '';
          if (!out.last4) { var m4 = (String(scope.innerText || '') + '\\n' + page).match(/(?:[•*·]{2,}\\s?|ending in |ends in |last 4:? )(\\d{4})\\b/i); if (m4) out.last4 = m4[1]; }
          var amount = '';
          var own = (label + ' ' + alt).match(MONEY);
          if (own) amount = own[0];
          for (var a = parent(anchor), d = 0; !amount && a && d < 10; a = parent(a), d++) {
            var lines = String(a.innerText || '').split('\\n').filter(function (l) { return MONEY.test(l); });
            if (!lines.length) continue;
            var totals = lines.filter(function (l) { return /total|amount|due|charge|pay/i.test(l); });
            amount = (totals.length ? totals[totals.length - 1] : lines[lines.length - 1]).match(MONEY)[0];
          }
          if (!amount) { var t = page.split('\\n').filter(function (l) { return /total|amount due/i.test(l) && MONEY.test(l); }); if (t.length) amount = t[t.length - 1].match(MONEY)[0]; }
          out.amount = amount;
          out.text = box ? value(box) : '';
          out.to = '';
          var fields = scope.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=password])');
          for (var f = 0; f < fields.length && !out.to; f++) {
            var e = fields[f], name = [e.name, e.id, e.getAttribute('aria-label'), e.placeholder].join(' ');
            if (/(^|[^a-z])(to|recipients?|send to)([^a-z]|$)/i.test(name) && e.value) out.to = squeeze(e.value, 120);
          }
          var mc = (label + ' ' + alt).match(/\\b(\\d+)\\b/) || page.match(/\\b(\\d+)\\s+(?:selected|items?|messages?|conversations?|files?|emails?|rows?|photos?|repositor(?:y|ies))\\b/i);
          out.count = mc ? mc[1] : '';
          return out;
        })(\(at), \(full))
        """
    }
}

// MARK: - the card

/// At the foot of the window that owns the tab (App.swift `bars`), one ask at a time.
struct ApproveSlot: View {
    let browser: Browser
    @ObservedObject private var approve = Approve.shared

    var body: some View {
        if let ask = approve.asks(in: browser).first {
            ApproveCard(ask: ask, tab: AgentTabs.find(ask.tab), elsewhere: ask.tab != browser.activeID && !Split.shared.has(ask.tab))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct ApproveCard: View {
    let ask: Approve.Ask
    let tab: Tab?
    let elsewhere: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ask.kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ask.agent) wants to \(ask.kind.verb)")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(elsewhere ? "\(ask.host) · on another tab" : ask.host)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if elsewhere, let tab {
                    Button("Show") { AgentTabs.show(tab) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .help("Go to the tab the agent is working in")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                fact("Button", "“\(ask.label)”")
                ForEach(facts, id: \.0) { fact($0.0, $0.1) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                answer("Deny", key: "esc", primary: false) { Approve.shared.answer(ask.id, approve: false) }
                answer("Approve", key: "↩", primary: true) { Approve.shared.answer(ask.id, approve: true) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ask.agent) wants to \(ask.kind.verb) on \(ask.host): \(ask.label)")
    }

    /// What the page shows near the button, by kind.
    private var facts: [(String, String)] {
        var out: [(String, String)] = []
        switch ask.kind {
        case .pay, .book:
            if !ask.amount.isEmpty { out.append(("Amount", ask.amount)) }
            if !ask.card.isEmpty { out.append(("Card", "•••• \(ask.card)")) }
        case .send:
            if !ask.to.isEmpty { out.append(("To", ask.to)) }
            if !ask.text.isEmpty { out.append(("Message", "“\(ask.text)”")) }
        case .delete:
            if !ask.count.isEmpty { out.append(("How many", ask.count)) }
        }
        return out
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func answer(_ title: String, key: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(key)
                    .font(.system(size: 10.5, weight: .medium))
                    .opacity(0.7)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(primary ? Palette.onAccent.opacity(0.4) : Palette.hairline, lineWidth: 1))
            }
            .foregroundStyle(primary ? Palette.onAccent : Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(primary ? Palette.accent : Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? Color.clear : Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(primary ? "Let \(ask.agent) click it (Return)" : "Don't let \(ask.agent) click it (Escape)")
    }
}

/// The column's foot (HandsUI.swift `DriveSlot`): "1 needs you" while a card
/// or a hand-off waits on one of this window's tabs; a click goes to it.
struct NeedsYouPill: View {
    let browser: Browser
    @ObservedObject private var approve = Approve.shared
    @ObservedObject private var handoff = Handoff.shared

    var body: some View {
        let tabs = approve.asks(in: browser).map(\.tab) + handoff.asks(in: browser).map(\.tab)
        if let first = tabs.first {
            Button { if let tab = AgentTabs.find(first) { AgentTabs.show(tab) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 16)
                    Text("\(tabs.count) needs you")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(SidePillGround(rim: Palette.accent.opacity(0.5), wash: Palette.accent.opacity(0.08)))
            .help("Go to the tab that is waiting for you")
            .accessibilityLabel("\(tabs.count) needs you")
        }
    }
}

// MARK: - Settings › Agents › Ask before

struct AgentsAskSection: View {
    var body: some View {
        SettingsSection("Ask before", note: "An agent stops and shows you a card before it does these. Headless Copper never waits.") {
            ForEach(Array(Approve.Kind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { Rule() }
                AskBeforeLine(kind: kind)
                    .settingsAnchor("agents.ask." + kind.rawValue)
            }
        }
    }
}

private struct AskBeforeLine: View {
    let kind: Approve.Kind
    @AppStorage private var on: Bool

    init(kind: Approve.Kind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: Approve.defaultOn(testing: Store.testing), "approve." + kind.rawValue, store: Store.settings)
    }

    var body: some View {
        Line(kind.setting, Self.detail[kind] ?? "") { Switch(on: $on) }
    }

    static let detail: [Approve.Kind: String] = [
        .pay: "Pay, buy, place an order or check out",
        .send: "Send, post or reply in your name",
        .delete: "Delete, trash or erase",
        .book: "Book or reserve",
    ]
}
