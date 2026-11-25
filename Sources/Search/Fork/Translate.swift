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
        /// installed, supported (needs a download) or unsupported; and which
        /// route had the session: `session` (macOS 26) or `view` (SwiftUI's).
        var languages = ""
        var route = ""
        var total = 0
        var done = 0
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
        guard let page, let texts = page["texts"] as? [String], let order = page["order"] as? [Int], let gen = page["gen"] as? Int else {
            return end(tab, run, "failed", note: "couldn't read the page", in: browser, say: quietly ? nil : "Couldn't read this page to translate it")
        }
        guard let target = jobs[tab.id]?.target else { return }
        guard !texts.isEmpty, let source = Self.language(of: texts, declared: page["lang"] as? String ?? "") else {
            return end(tab, run, "failed", note: "no text", in: browser, say: quietly ? nil : "Nothing on this page to translate")
        }
        let from = Self.name(source), into = Self.name(target)
        update(tab, run) { $0.source = from; $0.total = texts.count }
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
                await pour(session, run, tab, web, browser, texts: texts, order: order, gen: gen, download: false, quietly: quietly)
                return
            }
        }
        let work: (TranslationSession) async -> Void = { session in
            await self.pour(session, run, tab, web, browser, texts: texts, order: order, gen: gen, download: status != .installed, quietly: quietly)
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
                      texts: [String], order: [Int], gen: Int, download: Bool, quietly: Bool) async {
        if download {
            update(tab, run) { $0.state = "preparing" } // the system asks to download the languages
            do { try await session.prepareTranslation() } catch {
                return end(tab, run, "failed", note: "\(error)", in: browser, say: "The languages to translate this page aren't on this Mac")
            }
        }
        update(tab, run) { $0.state = "translating" }
        // Batches of about forty lines: big enough to be quick, small enough
        // that what is on screen comes back first.
        var batches: [[TranslationSession.Request]] = [[]]
        var size = 0
        for index in order {
            let text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if batches[batches.count - 1].count >= 40 || size >= 2500 { batches.append([]); size = 0 }
            batches[batches.count - 1].append(.init(sourceText: text, clientIdentifier: String(index)))
            size += text.count
        }
        var trouble: Error?
        for batch in batches where !batch.isEmpty {
            guard alive(tab, run) else { return }
            let answers: [TranslationSession.Response]
            do { answers = try await session.translations(from: batch) } catch { trouble = error; continue }
            let pairs: [[Any]] = answers.compactMap { answer in answer.clientIdentifier.flatMap(Int.init).map { [$0, answer.targetText] as [Any] } }
            let written = try? await web.callAsyncJavaScript(
                "return window.__copperTranslate ? window.__copperTranslate.put(g, pairs) : -1",
                arguments: ["g": gen, "pairs": pairs], in: nil, contentWorld: .copper) as? Int
            guard alive(tab, run) else { return }
            // -1: another page, or Show Original, since this run read it.
            guard let written, written >= 0 else { return end(tab, run, "failed", note: "page changed", in: browser) }
            update(tab, run) { job in
                job.done += batch.count
                if job.firstMs == nil { job.firstMs = Int(Date().timeIntervalSince(job.started) * 1000) }
            }
        }
        let done = jobs[tab.id]?.done ?? 0
        if done == 0, let trouble {
            return end(tab, run, "failed", note: "\(trouble)", in: browser, say: "Couldn't translate this page")
        }
        end(tab, run, "done", in: browser, say: quietly ? nil : "Translated from \(jobs[tab.id]?.source ?? "")")
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
          return /\p{L}/u.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
        } });
        for (var n = walker.nextNode(); n; n = walker.nextNode()) { nodes.push(n); was.push(n.nodeValue); }
        // On screen or about to be first, then the rest in reading order.
        var near = [], far = [], h = innerHeight;
        for (var i = 0; i < nodes.length; i++) {
          var r = nodes[i].parentElement ? nodes[i].parentElement.getBoundingClientRect() : null;
          (r && r.bottom > -h && r.top < 2 * h ? near : far).push(i);
        }
        return { gen: gen, lang: document.documentElement.lang || '', texts: was, order: near.concat(far) };
      }
      function put(g, pairs) {
        if (g !== gen) return -1;
        var count = 0;
        for (var k = 0; k < pairs.length; k++) {
          var i = pairs[k][0], node = nodes[i];
          if (!node || node.nodeValue !== was[i]) continue;
          var edge = /^(\s*)[\s\S]*?(\s*)$/.exec(was[i]);
          now[i] = node.nodeValue = edge[1] + pairs[k][1] + edge[2];
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
