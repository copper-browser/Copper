import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Copper's own passwords in and out as CSV — the file Chrome, Safari, Apple
/// Passwords and password managers write. Import reads the file once, off
/// the main thread, into `Vault`; export writes the same shape back
/// (Chrome's columns: name, url, username, password, note), so a file Copper
/// writes is one Copper — or any of those — takes back in.
///
/// This is the one CSV module: Settings' import, the Passwords panel, and
/// Move in's Chrome and Safari export paths all read through `columns` (the
/// header spellings the exports use), `take(text:)` and its sentences.
///
/// Every outcome is one sentence that says what happened and, when nothing
/// did, the one thing to try next.
enum PasswordCSV {
    /// What an import came to.
    struct Outcome: Equatable {
        var kept = 0
        var skipped = 0
        /// Two-step code keys kept beside the logins (KeychainCodes).
        var codes = 0
        /// Set when nothing could be read at all: why, in a sentence.
        var refused: String?

        var sentence: String {
            if let refused { return refused }
            if kept == 0, skipped == 0 { return "That file has no passwords in it" }
            if kept == 0 {
                return skipped == 1
                    ? "Nothing imported — its one row has no site or no password"
                    : "Nothing imported — none of its \(skipped) rows has both a site and a password"
            }
            var line = kept == 1 ? "1 password imported" : "\(kept) passwords imported"
            if skipped > 0 { line += ", \(skipped) skipped (no site or no password)" }
            if codes > 0 { line += codes == 1 ? ", with 1 two-step code" : ", with \(codes) two-step codes" }
            return line
        }
    }

    /// Where the columns are in a header.
    struct Columns: Equatable {
        var url: Int
        var user: Int
        var password: Int
        var otp: Int?
        var notes: Int?
    }

    /// What a file holds, before anything is kept.
    struct Summary: Equatable {
        /// Rows with a site and a password: what will be kept.
        var logins = 0
        /// Rows without a site or a password.
        var skipped = 0
        /// Rows with a one-time-code secret.
        var withCodes = 0
        /// Rows with notes, which don't move either.
        var withNotes = 0
        /// Whether the header was understood at all.
        var understood = false
    }

    /// The header spellings, lowercased, of every export Copper knows:
    /// Chrome's `name,url,username,password,note`; Safari's and Apple
    /// Passwords' `Title,URL,Username,Password,Notes,OTPAuth`; the password
    /// managers' `login_uri,login_username,login_password,login_totp` and
    /// their `Url`, `Website`, `Email`, `TOTP` and `Extra` variants.
    static let urlNames: Set<String> = ["url", "website", "web site", "login_uri", "site", "address", "login url", "web address"]
    static let userNames: Set<String> = ["username", "user name", "login_username", "user", "email", "email address", "login", "account"]
    static let passwordNames: Set<String> = ["password", "login_password"]
    static let otpNames: Set<String> = ["otpauth", "otp", "totp", "login_totp", "otpsecret", "one-time code", "verification code"]
    static let notesNames: Set<String> = ["notes", "note", "comments", "extra"]

    /// Where a header's site, username and password are — nil when one of
    /// the three is missing.
    static func columns(_ header: [String]) -> Columns? {
        let names = header.map(normal)
        func find(_ set: Set<String>) -> Int? { names.firstIndex { set.contains($0) } }
        guard let url = find(urlNames), let user = find(userNames), let password = find(passwordNames) else { return nil }
        return Columns(url: url, user: user, password: password, otp: find(otpNames), notes: find(notesNames))
    }

    private static func normal(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static let notPasswords = "That isn't a passwords CSV — export one again from your browser or password manager"

    /// Why a text can't be a passwords export, before anything is saved; nil
    /// when its first line names a site, a username and a password column.
    static func problem(with text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "That file is empty" }
        guard let header = firstRecord(trimmed) else { return notPasswords }
        let names = header.map(normal)
        var missing: [String] = []
        if !names.contains(where: urlNames.contains) { missing.append("website") }
        if !names.contains(where: userNames.contains) { missing.append("username") }
        if !names.contains(where: passwordNames.contains) { missing.append("password") }
        guard missing.isEmpty else {
            let list = missing.count == 1 ? missing[0] : "\(missing.dropLast().joined(separator: ", ")) or \(missing[missing.count - 1])"
            return "That CSV has no \(list) column — export it again as a passwords CSV"
        }
        return nil
    }

    /// The first record of a CSV: quoted fields, doubled quotes, a newline
    /// inside quotes.
    static func firstRecord(_ text: String) -> [String]? {
        let first = records(text, limit: 1).first ?? []
        // One column is a list of words, not a table.
        return first.count > 1 ? first : nil
    }

    /// Every record: quoted fields, doubled quotes, newlines inside quotes,
    /// CR, LF or CRLF between records, a leading byte-order mark; blank
    /// lines (and lines of empty fields) dropped.
    static func parse(_ text: String) -> [[String]] {
        records(text, limit: .max)
    }

    private static func records(_ text: String, limit: Int) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        if text.first == "\u{FEFF}" { index = text.index(after: index) }
        func endRow() {
            row.append(field)
            field = ""
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }
        while index < text.endIndex, rows.count < limit {
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); index = next } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
            index = text.index(after: index)
        }
        if rows.count < limit, !(row.isEmpty && field.isEmpty) { endRow() }
        return rows
    }

    /// What a file holds — counts only; no value is kept or logged.
    static func summary(_ text: String) -> Summary {
        var rows = parse(text)
        var out = Summary()
        guard !rows.isEmpty, let columns = columns(rows.removeFirst()) else { return out }
        out.understood = true
        for row in rows {
            guard let login = login(row, columns) else { out.skipped += 1; continue }
            out.logins += 1
            if login.code { out.withCodes += 1 }
            if login.notes { out.withNotes += 1 }
        }
        return out
    }

    /// The same logins under `url,username,password` — the header
    /// `Vault.take(csv:)` reads — with the rows it would skip left out. Nil
    /// when the header isn't a passwords export's.
    static func canonical(_ text: String) -> String? {
        var rows = parse(text)
        guard !rows.isEmpty, let columns = columns(rows.removeFirst()) else { return nil }
        var out = "url,username,password\n"
        for row in rows where login(row, columns) != nil {
            out += [row[columns.url], row[columns.user], row[columns.password]].map(cell).joined(separator: ",") + "\n"
        }
        return out
    }

    /// Each login a file would bring, as `host` + U+0001 + `user` — no
    /// password — so Move in can tell what is already here before it keeps
    /// anything.
    static func accounts(_ text: String) -> [String] {
        var rows = parse(text)
        guard !rows.isEmpty, let columns = columns(rows.removeFirst()) else { return [] }
        return rows.compactMap { row in
            guard login(row, columns) != nil else { return nil }
            return Vault.host(of: row[columns.url]) + "\u{1}" + row[columns.user]
        }
    }

    /// Each kept login's one-time-code column, as host, user and key.
    static func seeds(_ text: String) -> [(host: String, user: String, seed: String)] {
        var rows = parse(text)
        guard !rows.isEmpty, let columns = columns(rows.removeFirst()), let at = columns.otp else { return [] }
        return rows.compactMap { row in
            guard login(row, columns) != nil, at < row.count else { return nil }
            let seed = row[at].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seed.isEmpty else { return nil }
            return (Vault.host(of: row[columns.url]), row[columns.user], seed)
        }
    }

    private static func login(_ row: [String], _ columns: Columns) -> (code: Bool, notes: Bool)? {
        guard row.count > max(columns.url, max(columns.user, columns.password)) else { return nil }
        guard !Vault.host(of: row[columns.url]).isEmpty, !row[columns.password].isEmpty else { return nil }
        func filled(_ at: Int?) -> Bool {
            guard let at, at < row.count else { return false }
            return !row[at].trimmingCharacters(in: .whitespaces).isEmpty
        }
        return (filled(columns.otp), filled(columns.notes))
    }

    /// Checks, then keeps: the import itself, for a text already read. Runs
    /// wherever it is called — call it off the main thread.
    static func take(text: String) -> Outcome {
        if let refused = problem(with: text) { return Outcome(refused: refused) }
        guard let plain = canonical(text) else { return Outcome(refused: notPasswords) }
        let found = summary(text)
        let result = Vault.take(csv: plain)
        // Fork (keychain-codes): each row's authenticator key goes beside its
        // password; one that makes no code is left out, not guessed at.
        var codes = 0
        for (host, user, seed) in seeds(text) where Vault.logins(for: host).contains(where: { $0.user == user }) {
            if KeychainCodes.save(seed, host: host, user: user) { codes += 1 }
        }
        return Outcome(kept: result.kept, skipped: found.skipped + result.skipped, codes: codes)
    }

    /// Text from a file the way exports come: UTF-8 (with or without a BOM),
    /// else UTF-16, else Latin-1 — or nil for something that isn't text.
    static func text(of data: Data) -> String? {
        if data.isEmpty { return "" }
        if data.contains(0), !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])) { return nil }
        if var utf8 = String(data: data, encoding: .utf8) {
            if utf8.hasPrefix("\u{FEFF}") { utf8.removeFirst() }
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Reads, checks and keeps — off the main thread. `done` runs on the main
    /// queue with the outcome.
    static func take(_ url: URL, done: @escaping @MainActor (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            if let data = try? Data(contentsOf: url), let text = text(of: data) {
                outcome = take(text: text)
            } else {
                outcome = Outcome(refused: "Couldn't read that file as text — choose the .csv the export made")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }

    // MARK: - out

    /// One field, quoted when it has to be.
    static func cell(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The export's text: Chrome's header, then one row per login.
    static func csv(_ logins: [Login]) -> String {
        var lines = ["name,url,username,password,note"]
        for login in logins {
            lines.append([login.host, "https://\(login.host)/", login.user, login.password, ""].map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every password, secrets read one by one, written to `url` readable by
    /// this user only. Returns how many were written and how many the
    /// keychain would not give up.
    static func export(to url: URL) throws -> (written: Int, refused: Int) {
        var full: [Login] = []
        var refused = 0
        for login in Vault.all() {
            if let resolved = Vault.resolve(login) { full.append(resolved) } else { refused += 1 }
        }
        let data = Data(csv(full).utf8)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (full.count, refused)
    }

    static func exportSentence(_ written: Int, refused: Int, file: String) -> String {
        let head = written == 1 ? "1 password exported to \(file)" : "\(written) passwords exported to \(file)"
        guard refused > 0 else { return head }
        return "\(head) — \(refused) the keychain wouldn't give up"
    }
}

extension Browser {
    /// Settings › Passwords › Import a CSV file, and the Passwords panel's
    /// "CSV file…": a file chosen, then `PasswordCSV.take`.
    func importPasswordsCSV(from url: URL) {
        announce("Importing passwords…")
        PasswordCSV.take(url) { [weak self] outcome in
            guard let self else { return }
            self.relist()
            self.announce(outcome.sentence)
            PasswordsBench.lastImport = outcome
        }
    }

    /// The Passwords panel's Export…: Touch ID (or the Mac's password) first,
    /// then where to put the file, then the file — readable by you only.
    func exportPasswordsCSV() {
        guard !saved.isEmpty else {
            announce("No passwords to export yet")
            return
        }
        Vault.prove("export your passwords") { [weak self] ok in
            guard let self else { return }
            guard ok else { self.announce("Nothing exported"); return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Copper Passwords.csv"
            panel.message = "Anyone who opens this file can read every password in it. Delete it when you're done with it."
            panel.prompt = "Export"
            // On the window, so the other windows stay usable meanwhile.
            let chosen: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    let result = try PasswordCSV.export(to: url)
                    self.announce(PasswordCSV.exportSentence(result.written, refused: result.refused, file: url.lastPathComponent))
                } catch {
                    self.announce("Couldn't write \(url.lastPathComponent) — choose another folder")
                }
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
                panel.beginSheetModal(for: window, completionHandler: chosen)
            } else {
                chosen(panel.runModal())
            }
        }
    }
}

/// Settings › Passwords › Import and export: a CSV in, a CSV out.
struct PasswordCSVLines: View {
    let browser: Browser

    var body: some View {
        Group {
            Rule()
            Line("From a CSV file", "A passwords export from Chrome, Safari, Apple Passwords or a password manager") {
                Pill("Choose File…") { browser.importPasswords() }
            }
            .settingsAnchor("passwords.csv")
            Rule()
            Line("Export to a CSV file", "Every password Copper keeps, after Touch ID. Anyone with the file can read them — delete it when you're done.") {
                Pill("Export…") { browser.exportPasswordsCSV() }
            }
            .settingsAnchor("passwords.export")
        }
    }
}
