import AppKit
import Foundation
import UniformTypeIdentifiers

/// The way in that needs no permission: a file the browser exported.
///
/// When macOS keeps Chrome's folder private, Chrome can still hand over two
/// things on its own — its bookmarks as an HTML file, its passwords as a
/// CSV. The locked card's "Use an export instead…" takes either, dropped on
/// the sheet or picked. A file brings only what is in it: no open tabs,
/// history or sign-ins, and the pane says so.
///
/// Bookmarks go through the same merge as a direct read
/// (`FlowBookmarks.take(_, from:)`), so taking the same file twice — or the
/// file after a direct read — replaces rather than doubles. Passwords are
/// read by the one CSV module (`PasswordCSV`: its header spellings, checks
/// and parser) and go where a move's passwords go (`FlowSecrets.sink`): the
/// keychain, or in a test run the probe's stand-in.
///
/// Safari's export pane takes its zip (or one of its files) through
/// `Flow.takeSafariExport` instead: that file becomes Safari's source for
/// the session rather than being taken on the spot.
enum FlowFiles {
    enum Kind: Equatable { case bookmarks, passwords, neither }

    /// What a file is, by what is in it rather than its name.
    static func kind(of text: String) -> Kind {
        if FlowBookmarksHTML.isBookmarkFile(text) { return .bookmarks }
        if PasswordCSV.problem(with: text) == nil { return .passwords }
        return .neither
    }

    /// Text the way exports come: UTF-8 (with or without a byte-order mark),
    /// UTF-16 with one, or a single-byte file as Latin-1.
    static func text(_ data: Data) -> String? { FlowBookmarksHTML.text(data) }

    /// The sentence a passwords file comes to.
    static func passwordSentence(kept: Int, skipped: Int, new: Int?) -> String {
        if kept == 0, skipped == 0 { return "That file has no passwords in it" }
        if kept == 0 {
            return skipped == 1
                ? "Nothing imported — its one row has no site or no password"
                : "Nothing imported — none of its \(skipped.formatted()) rows has both a site and a password"
        }
        var head = kept == 1 ? "1 password imported" : "\(kept.formatted()) passwords imported"
        if let new, new < kept { head += new == 0 ? " — all were already here" : " — \(new.formatted()) new" }
        return skipped == 0 ? head : "\(head), \(skipped.formatted()) skipped (no site or no password)"
    }

    /// The sentence a bookmarks file comes to.
    static func bookmarkSentence(read: Int, new: Int, source: String) -> String {
        if read == 0 { return "That file has no bookmarks in it" }
        if new == 0 {
            return read == 1
                ? "Nothing new — the bookmark in that file was already here"
                : "Nothing new — the \(read.formatted()) bookmarks in that file were already here"
        }
        let head = read == 1 ? "1 bookmark from \(source)'s file" : "\(read.formatted()) bookmarks from \(source)'s file"
        return new < read ? "\(head), \(new.formatted()) new" : head
    }
}

extension Flow {
    /// The locked card's secondary button: the export pane for this source.
    func showExport(for source: FlowSource) {
        guard !moving else { return }
        exporting = source
        log("export", source.name)
    }

    /// Takes one exported file, as dropped or picked. The file is read and
    /// parsed off the main actor, and its bookmarks merged there too (a
    /// large export takes a moment, never the window); one file at a time.
    func takeFile(_ url: URL, from source: String, into browser: Browser) {
        if source == FlowSafari.name { return takeSafariExport(url) }
        guard !fileBusy else { return }
        fileBusy = true
        fileResult = nil
        log("file", "reading")
        Task {
            let result = await bring(url, from: source, into: browser)
            fileResult = result
            fileBusy = false
            log("file", "\(result.ok ? "ok" : "no") \(result.text)")
        }
    }

    /// What a file is, read off the main actor.
    private enum Opened {
        case unreadable
        case bookmarks(FlowBookmarks.Read, count: Int, new: Int)
        case passwords(String)
        case neither
    }

    private func bring(_ url: URL, from source: String, into browser: Browser) async -> FileResult {
        let before = browser.bookmarks.roots
        let opened = await Task.detached(priority: .userInitiated) { () -> Opened in
            guard let data = try? Data(contentsOf: url), let text = FlowFiles.text(data) else { return .unreadable }
            switch FlowFiles.kind(of: text) {
            case .bookmarks:
                let read = FlowBookmarksHTML.read(data, layout: .chromium, file: url)
                let new = FlowBookmarks.addresses(read.nodes).subtracting(FlowBookmarks.addresses(before)).count
                return .bookmarks(read, count: read.complete ? FlowBookmarks.count(read.nodes) : 0, new: new)
            case .passwords: return .passwords(text)
            case .neither: return .neither
            }
        }.value
        switch opened {
        case .unreadable:
            return FileResult(ok: false, text: "Couldn't read that file — choose the file the export made")
        case .bookmarks(let read, let count, let new):
            guard count > 0 else {
                return FileResult(ok: false, text: FlowFiles.bookmarkSentence(read: 0, new: 0, source: source))
            }
            await FlowBookmarks.takeInBackground(read, from: source, into: browser.bookmarks)
            return FileResult(ok: new > 0, text: FlowFiles.bookmarkSentence(read: count, new: new, source: source))
        case .passwords(let text):
            let seams = FlowSecrets.seams
            let sink = FlowSecrets.sink
            // Each row is a keychain write in a real run: off the main actor.
            let result = await Task.detached(priority: .userInitiated) { () -> (kept: Int, skipped: Int, new: Int?) in
                // Every header the exports use, under the one Vault reads.
                guard let plain = PasswordCSV.canonical(text) else { return (0, 0, nil) }
                let skipped = PasswordCSV.summary(text).skipped
                guard seams else {
                    // What is already here, by site and account — no secret read.
                    let have = Set(Vault.all(in: nil).map { $0.host + "\u{1}" + $0.user })
                    let new = Set(PasswordCSV.accounts(text)).subtracting(have).count
                    let taken = Vault.take(csv: plain)
                    return (taken.kept, skipped + taken.skipped, new)
                }
                var new = 0
                var known = true
                let taken = Vault.take(csv: plain) { host, user, password in
                    let saved = sink.savePassword(host: host, user: user, password: password, used: nil)
                    if let isNew = saved.new { if isNew && saved.kept { new += 1 } } else { known = false }
                    return saved.kept
                }
                return (taken.kept, skipped + taken.skipped, known ? new : nil)
            }.value
            if !seams { browser.relist() }
            return FileResult(ok: result.kept > 0,
                              text: FlowFiles.passwordSentence(kept: result.kept, skipped: result.skipped, new: result.new))
        case .neither:
            return FileResult(ok: false, text: "That isn't a bookmarks or passwords file — export one from \(source) as described above")
        }
    }

    /// "Choose a file…": a panel on the sheet itself, starting in Downloads.
    func chooseFile(from source: String, into browser: Browser) {
        guard let sheet = FlowPresenter.shared.sheetWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if source == FlowSafari.name {
            // The zip, the folder it unzips to, or one of its files.
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.zip, .folder, .html, .commaSeparatedText, .plainText, .json]
            panel.message = "Choose the .zip Safari saved (File › Export Browsing Data to File…), or a bookmarks .html or passwords .csv."
        } else {
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText]
            panel.message = "Choose the bookmarks (.html) or passwords (.csv) file \(source) exported."
        }
        panel.prompt = "Bring In"
        log("file-panel", source)
        panel.beginSheetModal(for: sheet) { [weak self, weak browser] response in
            guard response == .OK, let url = panel.url, let self, let browser else { return }
            self.takeFile(url, from: source, into: browser)
        }
    }
}
