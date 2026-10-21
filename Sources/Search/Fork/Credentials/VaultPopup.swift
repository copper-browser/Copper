import SwiftUI

/// Fork (vault-popup): every account Copper can fill — keychain, Bitwarden,
/// 1Password — in one list you can search, from the key door beside
/// Bookmarks or ⇧⌘Y (Bitwarden's own shortcut for its popup). What the
/// Bitwarden extension's popup is for, without the extension: copy a name,
/// password or two-step code, open the site, or fill this page.
///
/// Fill is offered only for accounts this page (or the frame with the caret)
/// would offer anyway, so a password never goes to a site it isn't for.
struct VaultPopup: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bitwarden = Bitwarden.shared
    @ObservedObject private var onePassword = OnePassword.shared

    @State private var needle = ""
    @State private var all: [Credential] = []
    @State private var here: Set<CredentialID> = []
    @State private var picked = 0
    @FocusState private var hunting: Bool

    private var rows: [Credential] { Self.rows(all, here: here, needle: needle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hunt(text: $needle, prompt: "Search accounts", focus: $hunting)
                .padding(10)
            Divider().overlay(Palette.hairline)
            let shown = rows
            if shown.isEmpty {
                VaultPendingRows(browser: browser, emptyLogin: true)
                if !Browser.vaultPending {
                    Text(all.isEmpty ? "Nothing kept yet" : "Nothing matches")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(14)
                }
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, credential in
                                Row(credential: credential, fills: here.contains(credential.id), picked: index == picked) { act in
                                    Self.run(act, credential, in: browser)
                                }
                                .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    // A popover gives a scroll view no height of its own: ask for the rows'.
                    .frame(height: min(CGFloat(shown.count) * 40 + 8, 380))
                    .onChange(of: picked) { _, now in scroller.scrollTo(now) }
                }
                // Locked or loading vaults still say so under what is shown.
                VaultPendingRows(browser: browser, emptyLogin: true)
            }
        }
        .frame(width: 440)
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .onAppear { reload(); hunting = true }
        .onChange(of: bitwarden.cacheVersion) { _, _ in reload() }
        .onChange(of: onePassword.cacheVersion) { _, _ in reload() }
        .onChange(of: needle) { _, _ in picked = 0 }
        .onKeyPress(.downArrow) { picked = min(picked + 1, max(rows.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { picked = max(picked - 1, 0); return .handled }
        .onKeyPress(.return) {
            let shown = rows
            guard shown.indices.contains(picked) else { return .ignored }
            let credential = shown[picked]
            Self.run(here.contains(credential.id) ? .fill : .password, credential, in: browser)
            return .handled
        }
    }

    /// Read once on opening and when a vault's index changes — not per keystroke:
    /// the keychain half is a query.
    private func reload() {
        all = Credentials.all()
        here = Self.fillable(in: browser)
    }

    /// The accounts the page with the caret (or the page) would offer.
    static func fillable(in browser: Browser) -> Set<CredentialID> {
        guard let host = browser.active?.formHost else { return [] }
        return Set(Credentials.candidates(for: host).map(\.id))
    }

    /// The list as shown: this page's accounts first, then by name; narrowed
    /// by every word of the search against name, user, host and sites.
    static func rows(_ all: [Credential], here: Set<CredentialID>, needle: String) -> [Credential] {
        let words = needle.lowercased().split(separator: " ").map(String.init)
        let matching = all.filter { credential in
            let text = ([credential.name, credential.user, credential.host] + credential.sites).joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
        return matching.enumerated().sorted { a, b in
            let ha = here.contains(a.element.id), hb = here.contains(b.element.id)
            if ha != hb { return ha }
            let na = label(a.element).lowercased(), nb = label(b.element).lowercased()
            return na != nb ? na < nb : a.offset < b.offset
        }.map(\.element)
    }

    static func label(_ credential: Credential) -> String {
        credential.name.isEmpty || credential.name == credential.user ? credential.host : credential.name
    }

    enum Act: String { case fill, user, password, code, open }

    /// One thing done with an account. Secrets are read only now, for this
    /// one account, and go to the page or the pasteboard — never to the view.
    static func run(_ act: Act, _ credential: Credential, in browser: Browser) {
        switch act {
        case .fill:
            guard fillable(in: browser).contains(credential.id) else {
                browser.announce("That account isn't for this page")
                return
            }
            browser.vaultOpen = false
            browser.choose(credential)
        case .user:
            SettingsActions.copy(credential.user)
            browser.announce("Username copied")
        case .password:
            Task {
                do {
                    SettingsActions.copy(try await Credentials.secret(credential.id))
                    Credentials.touch(credential)
                    browser.announce("Password copied")
                } catch {
                    browser.announce(error.localizedDescription)
                }
            }
        case .code:
            Task {
                do {
                    SettingsActions.copy(try await Credentials.totp(credential.id))
                    browser.announce("Two-step code copied")
                } catch {
                    browser.announce(error.localizedDescription)
                }
            }
        case .open:
            guard let url = site(of: credential) else {
                browser.announce("That account has no site")
                return
            }
            browser.vaultOpen = false
            _ = browser.open(url, foreground: true)
        }
    }

    /// The first web address the account keeps, or its host.
    static func site(of credential: Credential) -> URL? {
        for raw in credential.sites + [credential.host] {
            let text = raw.contains("://") ? raw : "https://" + raw
            if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http", url.host() != nil {
                return url
            }
        }
        return nil
    }

    private struct Row: View {
        let credential: Credential
        let fills: Bool
        let picked: Bool
        let act: (Act) -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: credential.source.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(VaultPopup.label(credential))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(credential.user.isEmpty ? credential.host : "\(credential.user) · \(credential.host)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if hovering || picked {
                    HStack(spacing: 4) {
                        if fills { Quick("Fill") { act(.fill) } }
                        if !credential.user.isEmpty { Quick("Name") { act(.user) } }
                        Quick("Password") { act(.password) }
                        if credential.hasTOTP { Quick("Code") { act(.code) } }
                        Quick("Open") { act(.open) }
                    }
                    .fixedSize()
                } else if fills {
                    Text("This site")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(hovering || picked ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}
