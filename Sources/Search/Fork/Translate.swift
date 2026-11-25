import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// Fork (page-tools): Translate Page, on the Mac's own models (Apple's
// Translation framework, macOS 15 and later; nothing leaves the Mac). Hidden
// where it isn't there.
//
// The page's text nodes are walked in Copper's own content world (out of the
// page's reach), what is on screen first, sent to the model in batches, and
// each batch is written back as it comes, so the first lines change in about
// a second. Links, styles and layout stay, since only text nodes change. Show
// Original puts back exactly what was there. Once a tab is translated, the
// next pages that load in it are translated too, until Show Original —
// except on sites marked Never Translate This Site.
//
// The model: on macOS 26 a session made straight from installed languages;
// otherwise SwiftUI's `.translationTask` on a hidden view in the window, the
// route that can also ask to download the languages the first time. Which
// languages count as installed depends on the SDK the app was linked with:
// on a Mac whose languages came with a newer system, an app linked with the
// 15.5 SDK (Copper's release) still gets the download prompt once (measured
// on macOS 26.6: "installed" from 27.2-SDK binaries, "supported" from 26.0).
// Bench: `./bench page translate|original|never|state` (Fork/PageShare.swift).

@MainActor
@Observable
final class PageTranslate {
    static let shared = PageTranslate()

    static var available: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    /// A tab being translated: into what, and how its current page is going.
    struct Job {
        var run: Int
        let target: Locale.Language
        var page: URL?
        /// A page the tab went on to: it says nothing unless it fails, and
        /// keeps the tab translating when there is nothing to do.
        var following = false
        /// reading, waiting (for the view's session), preparing (asking to download the languages),
        /// translating, done, same (already in the target language), failed
        var state = "reading"
        var source = ""
        /// The page's text nodes, the different lines among them, and how many the model has answered.
        var nodes = 0
        var lines = 0
        /// installed, supported (needs a download) or unsupported; and which
        /// route had the session: `session` (macOS 26) or `view` (SwiftUI's).
        var languages = ""
        var route = ""
        var done = 0
        /// Passages whose answer lost its tags and went again node by node.
        var retried = 0
        var note = ""
        var started = Date()
        var firstMs: Int?
        var ms: Int?
    }

    /// Tabs in translation, by tab. Present from Translate Page until Show Original.
    private(set) var jobs: [Tab.ID: Job] = [:]
    /// Hosts never translated on their own (`translate.never`).
    private(set) var never = Set(Store.settings.stringArray(forKey: "translate.never") ?? [])
    @ObservationIgnored private var follows: [Tab.ID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var hosts: [Tab.ID: NSView] = [:]
    @ObservationIgnored private var runs = 0
    /// Told when a run ends, however it ends (the bench waits on it).
    @ObservationIgnored var ended: [Tab.ID: [(Job) -> Void]] = [:]

    func translated(_ tab: Tab?) -> Bool { tab.map { jobs[$0.id] != nil } ?? false }
    func isNever(_ tab: Tab?) -> Bool { tab?.address?.host.map { never.contains($0.lowercased()) } ?? false }

    /// View › Translate Page, or Show Original once it is translated.
    func toggle(in browser: Browser) {
        guard let tab = browser.active, !tab.isBlank else { return }
        if translated(tab) { showOriginal(tab, in: browser) } else { translate(tab, in: browser) }
    }

    /// View › Never Translate This Site: its pages stay as they are when the
    /// tab goes on translating, and this one goes back to its original.
    func toggleNever(in browser: Browser) {
        guard let tab = browser.active, let host = tab.address?.host?.lowercased() else { return }
        if never.remove(host) == nil {
            never.insert(host)
            if translated(tab) { showOriginal(tab, in: nil) }
            browser.announce("\(host) won't be translated")
        } else {
            browser.announce("\(host) can be translated again")
        }
        Store.settings.set(never.sorted(), forKey: "translate.never")
    }

    func showOriginal(_ tab: Tab, in browser: Browser?) {
        jobs[tab.id] = nil
        follows.removeValue(forKey: tab.id)?.invalidate()
        hosts.removeValue(forKey: tab.id)?.removeFromSuperview()
        tab.built?.evaluateJavaScript("window.__copperTranslate ? window.__copperTranslate.restore() : false", in: nil, in: .copper)
        browser?.announce("Showing the original")
    }

    /// Into `target` (the first of your Mac's languages); `quietly` when the
    /// tab is following on to its next page.
    func translate(_ tab: Tab, in browser: Browser, into target: Locale.Language? = nil, quietly: Bool = false) {
        guard #available(macOS 15, *), let web = tab.built else { return }
        runs += 1
        let target = target ?? jobs[tab.id]?.target ?? Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        jobs[tab.id] = Job(run: runs, target: target, page: tab.address, following: quietly)
        follow(tab, web, in: browser)
        let run = runs
        Task { await self.read(run, tab, web, browser, quietly: quietly) }
    }

    // MARK: - a run

    private func update(_ tab: Tab, _ run: Int, _ change: (inout Job) -> Void) {
        guard var job = jobs[tab.id], job.run == run else { return }
        change(&job)
        jobs[tab.id] = job
    }

    private func end(_ tab: Tab, _ run: Int, _ state: String, note: String = "", in browser: Browser?, say: String? = nil) {
        guard var job = jobs[tab.id], job.run == run else { return }
        job.state = state
        job.note = note
        job.ms = Int(Date().timeIntervalSince(job.started) * 1000)
        jobs[tab.id] = job
        hosts.removeValue(forKey: tab.id)?.removeFromSuperview()
        // Asked for and not done: the tab isn't in translation after all.
        if state != "done", !job.following {
            jobs[tab.id] = nil
            follows.removeValue(forKey: tab.id)?.invalidate()
        }
        if let say { browser?.announce(say) }
        ended.removeValue(forKey: tab.id)?.forEach { $0(job) }
    }

    func alive(_ tab: Tab, _ run: Int) -> Bool { jobs[tab.id]?.run == run }

    @available(macOS 15, *)
    private func read(_ run: Int, _ tab: Tab, _ web: WKWebView, _ browser: Browser, quietly: Bool) async {
        let page = try? await web.callAsyncJavaScript(Self.script + "return T.collect();", arguments: [:], in: nil, contentWorld: .copper) as? [String: Any]
        guard alive(tab, run) else { return }
        guard let page, let texts = page["texts"] as? [String], let order = page["order"] as? [Int], let blocks = page["blocks"] as? [Int],
              let gen = page["gen"] as? Int else {
            return end(tab, run, "failed", note: "couldn't read the page", in: browser, say: quietly ? nil : "Couldn't read this page to translate it")
        }
        guard let target = jobs[tab.id]?.target else { return }
        guard !texts.isEmpty, let source = Self.language(of: texts, declared: page["lang"] as? String ?? "") else {
            return end(tab, run, "failed", note: "no text", in: browser, say: quietly ? nil : "Nothing on this page to translate")
        }
        let from = Self.name(source), into = Self.name(target)
        update(tab, run) { $0.source = from; $0.nodes = texts.count }
        if source.languageCode == target.languageCode {
            return end(tab, run, "same", in: browser, say: quietly ? nil : "This page is already in \(into)")
        }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard alive(tab, run) else { return }
        update(tab, run) { $0.languages = "\(status) \(source.maximalIdentifier)→\(target.maximalIdentifier)" }
        guard status != .unsupported else {
            return end(tab, run, "failed", note: "unsupported", in: browser, say: "\(from) to \(into) isn't available on this Mac")
        }
        if !quietly { browser.announce("Translating from \(from)…") }
        // A test run can take SwiftUI's route even when the languages are in (SEARCH_TRANSLATE_ROUTE=view).
        let viewOnly = Store.testing && ProcessInfo.processInfo.environment["SEARCH_TRANSLATE_ROUTE"] == "view"
        if #available(macOS 26, *), !viewOnly {
            // Straight from the installed languages: no view, no prompt.
            let session = TranslationSession(installedSource: source, target: target)
            if await session.isReady {
                update(tab, run) { $0.route = "session" }
                await pour(session, run, tab, web, browser, texts: texts, order: order, blocks: blocks, gen: gen, download: false, quietly: quietly)
                return
            }
        }
        let work: (TranslationSession) async -> Void = { session in
            await self.pour(session, run, tab, web, browser, texts: texts, order: order, blocks: blocks, gen: gen, download: status != .installed, quietly: quietly)
        }
        // SwiftUI's route: a view in the window hands over the session, and
        // asks to download the languages first when they aren't on the Mac.
        guard let stage = web.superview else {
            return end(tab, run, "failed", note: "not on screen", in: browser, say: "Show the tab to translate it")
        }
        update(tab, run) { $0.state = "waiting"; $0.route = "view" }
        let host = NSHostingView(rootView: TranslateHost(configuration: .init(source: source, target: target), work: work))
        host.frame = NSRect(x: web.frame.midX, y: web.frame.midY, width: 1, height: 1)
        stage.addSubview(host)
        hosts[tab.id] = host
    }

    @available(macOS 15, *)
    private func pour(_ session: TranslationSession, _ run: Int, _ tab: Tab, _ web: WKWebView, _ browser: Browser,
                      texts: [String], order: [Int], blocks: [Int], gen: Int, download: Bool, quietly: Bool) async {
        if download {
            update(tab, run) { $0.state = "preparing" } // the system asks to download the languages
            do { try await session.prepareTranslation() } catch {
                return end(tab, run, "failed", note: "\(error)", in: browser, say: "The languages to translate this page aren't on this Mac")
            }
        }
        update(tab, run) { $0.state = "translating" }
        // What goes to the model: on macOS 26.4 a passage, a paragraph's text
        // nodes as one text, each node a run tagged with its place, so the
        // sentence is translated whole and every node gets back the words the
        // model marks as its own (links and styles stay where they were).
        // Before 26.4 each node on its own. Each passage once (a page repeats
        // "modifier" and its menus), on-screen ones first. The model answers
        // a few short lines a second however they are batched, so answers go
        // onto the page as they come, the first in about a second.
        var rich = false
        if #available(macOS 26.4, *) { rich = true }
        var rank = [Int](repeating: 0, count: texts.count)
        for (place, index) in order.enumerated() { rank[index] = place }
        var passages: [[Int]] = [], size = 0
        for index in texts.indices {
            if rich, let last = passages.last?.last, blocks.indices.contains(index), blocks[last] == blocks[index], passages[passages.count - 1].count < 80, size < 1500 {
                passages[passages.count - 1].append(index)
            } else {
                passages.append([index])
                size = 0
            }
            size += texts[index].count
        }
        // Punctuation and numbers ride with their sentence; on their own they stay as they are.
        passages.removeAll { passage in !passage.contains { texts[$0].contains(where: \.isLetter) } }
        passages.sort { rank[$0[0]] < rank[$1[0]] }
        var copies: [[[Int]]] = [], pieces: [[String]] = [], seen: [String: Int] = [:]
        for passage in passages {
            // HTML's own spacing: runs of white space are one space, none at the passage's ends.
            var words = passage.map { texts[$0].split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            for (k, index) in passage.enumerated() {
                if k > 0, texts[index].first?.isWhitespace == true { words[k] = " " + words[k] }
                if k < passage.count - 1, texts[index].last?.isWhitespace == true { words[k] += " " }
            }
            let key = words.joined(separator: "\u{1F}")
            if let id = seen[key] { copies[id].append(passage); continue }
            seen[key] = pieces.count
            copies.append([passage])
            pieces.append(words)
        }
        update(tab, run) { $0.lines = pieces.count }
        var pending: [[Any]] = [], trouble: Error?
        func flush() async -> Bool {
            let pairs = pending
            pending = []
            let written = try? await web.callAsyncJavaScript(
                "return window.__copperTranslate ? window.__copperTranslate.put(g, pairs) : -1",
                arguments: ["g": gen, "pairs": pairs], in: nil, contentWorld: .copper) as? Int
            // -1: another page, or Show Original, since this run read it.
            guard alive(tab, run), let written, written >= 0 else { return false }
            update(tab, run) { job in
                if job.firstMs == nil { job.firstMs = Int(Date().timeIntervalSince(job.started) * 1000) }
            }
            return true
        }
        // One passage a call: only a single answer carries the tagged runs
        // (the batch calls drop them), and the model works one at a time anyway.
        var queue = Array(pieces.indices), next = 0
        while next < queue.count {
            guard alive(tab, run) else { return }
            let id = queue[next], words = pieces[id]
            next += 1
            let answered: [String]?
            do {
                if #available(macOS 26.4, *), words.count > 1 {
                    var source = AttributedString()
                    for (k, word) in words.enumerated() {
                        var piece = AttributedString(word)
                        piece.link = URL(string: "copper-node:\(k)")
                        source += piece
                    }
                    let answer = try await session.translate(source)
                    answered = Self.parts(of: answer, count: words.count)
                } else {
                    let answer = try await session.translate(words.joined())
                    answered = [answer.targetText]
                }
            } catch {
                trouble = error
                update(tab, run) { $0.note = "\(error)" }
                continue
            }
            guard alive(tab, run) else { return }
            guard let parts = answered else {
                // The answer lost most of its nodes' tags: the passage again, node by node, next.
                var again: [Int] = []
                for (k, word) in words.enumerated() where word.contains(where: \.isLetter) {
                    again.append(pieces.count)
                    copies.append(copies[id].map { [$0[k]] })
                    pieces.append([word.trimmingCharacters(in: .whitespaces)])
                }
                queue.insert(contentsOf: again, at: next)
                update(tab, run) { $0.lines += again.count; $0.retried += 1 }
                continue
            }
            for passage in copies[id] {
                for (index, text) in zip(passage, parts) { pending.append([index, text]) }
            }
            update(tab, run) { $0.done += 1 }
            if pending.count >= 6 || jobs[tab.id]?.firstMs == nil {
                guard await flush() else { return endChanged(tab, run, browser) }
            }
        }
        if !pending.isEmpty {
            guard await flush() else { return endChanged(tab, run, browser) }
        }
        if jobs[tab.id]?.done ?? 0 == 0, let trouble {
            return end(tab, run, "failed", note: "\(trouble)", in: browser, say: "Couldn't translate this page")
        }
        end(tab, run, "done", in: browser, say: quietly ? nil : "Translated from \(jobs[tab.id]?.source ?? "")")
    }

    /// A passage's answer, node by node: each run goes to the node its tag
    /// names, untagged words to the node before them. Nil when the answer
    /// kept the tags of fewer than half its nodes (the passage goes again,
    /// node by node, so its links keep their words).
    @available(macOS 15, *)
    nonisolated static func parts(of answer: TranslationSession.Response, count: Int) -> [String]? {
        guard count > 1 else { return [answer.targetText] }
        guard #available(macOS 26.4, *), let text = answer.attributedTargetText else { return nil }
        var out = [String](repeating: "", count: count), tagged = Set<Int>(), at = 0
        for run in text.runs {
            if let k = run.link?.absoluteString.split(separator: ":").last.flatMap({ Int($0) }), k < count { at = k; tagged.insert(k) }
            out[at] += String(text[run.range].characters)
        }
        return tagged.count * 2 >= count ? out : nil
    }

    private func endChanged(_ tab: Tab, _ run: Int, _ browser: Browser) {
        if alive(tab, run) { end(tab, run, "failed", note: "page changed", in: browser) }
    }

    /// The tab's next pages, translated as they load (a new page ends its load; a scroll or a click in it doesn't).
    private func follow(_ tab: Tab, _ web: WKWebView, in browser: Browser) {
        guard follows[tab.id] == nil else { return }
        follows[tab.id] = web.observe(\.isLoading, options: [.new]) { [weak self, weak tab, weak browser] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in
                guard let self, let tab, let browser, self.translated(tab), !self.isNever(tab), tab.built != nil else { return }
                self.translate(tab, in: browser, quietly: true)
            }
        }
    }

    // MARK: - languages

    /// What the page is written in: the text's own language when the
    /// recogniser is sure, otherwise what the page says (`<html lang>`).
    nonisolated static func language(of texts: [String], declared: String) -> Locale.Language? {
        var sample = "", size = 0
        for text in texts where size < 6000 {
            sample += text + " "
            size += text.utf16.count + 1
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.5 { return Locale.Language(identifier: best.key.rawValue) }
        let declared = declared.trimmingCharacters(in: .whitespaces)
        if !declared.isEmpty { return Locale.Language(identifier: declared) }
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    nonisolated static func name(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - the page's side

    /// Installs `T` (window.__copperTranslate, in Copper's world) once per
    /// document: `collect()` reads the text nodes worth translating (no code,
    /// fields, `translate="no"` or `.notranslate`), `put(gen, [[i, text]])`
    /// writes some back keeping each node's own spacing, `restore()` puts back
    /// every node still showing what was written.
    static let script = #"""
    var T = window.__copperTranslate;
    if (!T) T = window.__copperTranslate = (function () {
      var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, TEXTAREA: 1, SELECT: 1, CODE: 1, PRE: 1, KBD: 1, SAMP: 1, VAR: 1, SVG: 1, MATH: 1, IFRAME: 1, CANVAS: 1 };
      var inline = { A: 1, ABBR: 1, B: 1, BDI: 1, BDO: 1, CITE: 1, DFN: 1, EM: 1, FONT: 1, I: 1, LABEL: 1, MARK: 1, Q: 1, S: 1, SMALL: 1, SPAN: 1, STRONG: 1, SUB: 1, SUP: 1, TIME: 1, U: 1 };
      var nodes = [], was = [], now = [], gen = 0;
      function restore() {
        for (var i = 0; i < nodes.length; i++) if (now[i] !== undefined && nodes[i].nodeValue === now[i]) nodes[i].nodeValue = was[i];
        nodes = []; was = []; now = []; gen++;
        return true;
      }
      function collect() {
        restore();
        var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, { acceptNode: function (n) {
          if (n.nodeType === 1) return skip[n.nodeName.toUpperCase()] || n.getAttribute('translate') === 'no' || n.classList.contains('notranslate') || n.isContentEditable ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
          return /\S/.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
        } });
        for (var n = walker.nextNode(); n; n = walker.nextNode()) { nodes.push(n); was.push(n.nodeValue); }
        // Each node's block: the nearest ancestor that isn't inline text styling or a link.
        var ids = new Map(), blocks = [];
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i].parentElement;
          while (el && inline[el.nodeName] && el.parentElement) el = el.parentElement;
          if (!ids.has(el)) ids.set(el, ids.size);
          blocks.push(ids.get(el));
        }
        // On screen or about to be first, then the rest in reading order, then what is hidden (closed menus).
        var near = [], far = [], hidden = [], h = innerHeight;
        for (var i = 0; i < nodes.length; i++) {
          var r = nodes[i].parentElement ? nodes[i].parentElement.getBoundingClientRect() : null;
          if (!r || (!r.width && !r.height)) hidden.push(i);
          else (r.bottom > -h && r.top < 2 * h ? near : far).push(i);
        }
        return { gen: gen, lang: document.documentElement.lang || '', texts: was, order: near.concat(far, hidden), blocks: blocks };
      }
      function put(g, pairs) {
        if (g !== gen) return -1;
        var count = 0;
        for (var k = 0; k < pairs.length; k++) {
          var i = pairs[k][0], node = nodes[i];
          if (!node || node.nodeValue !== was[i]) continue;
          // The node's own spacing at its ends, if the answer lost it.
          var text = pairs[k][1], lead = /^\s/.test(was[i]) && !/^\s/.test(text) ? ' ' : '', trail = /\s$/.test(was[i]) && !/\s$/.test(text) ? ' ' : '';
          now[i] = node.nodeValue = text ? lead + text + trail : '';
          count++;
        }
        return count;
      }
      return { collect: collect, put: put, restore: restore };
    })();
    """#
}

/// The hidden view that hands over a session on macOS 15 (and when the
/// languages still need downloading).
@available(macOS 15, *)
private struct TranslateHost: View {
    let configuration: TranslationSession.Configuration
    let work: (TranslationSession) async -> Void

    var body: some View {
        Color.clear.translationTask(configuration) { session in await work(session) }
    }
}

/// View › Translate Page / Show Original and Never Translate This Site, under Reading Mode (App.swift).
struct TranslateItems: View {
    let browser: Browser

    var body: some View {
        if PageTranslate.available {
            let translate = PageTranslate.shared
            let tab = browser.active
            Button(translate.translated(tab) ? "Show Original" : "Translate Page") { translate.toggle(in: browser) }
                .disabled(tab?.isBlank ?? true)
            Toggle("Never Translate This Site", isOn: Binding(get: { translate.isNever(tab) }, set: { _ in translate.toggleNever(in: browser) }))
                .disabled(tab?.address?.host == nil)
        }
    }
}
