import SwiftUI

/// The accounts and autofill values for a site, hanging from the box the
/// caret is in. The same white and hairline as everything else that floats
/// over a page; a click puts one row into the form.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting

    /// Loading and locked controls belong to a login picker, not an empty card
    /// or identity picker. A login picker with custom-field rows is not empty.
    private var emptyLogin: Bool { asked.rows.isEmpty && asked.credentials.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every row, not a handful: six show, the rest scroll.
            ScrollView(showsIndicators: asked.rows.count > 6) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(asked.rows) { suggestion in
                        Row(
                            suggestion: suggestion,
                            fetching: isFetching(suggestion),
                            pick: { browser.choose(suggestion) }
                        )
                    }
                }
            }
            .frame(maxHeight: 6 * 44 + 22)
            .fixedSize(horizontal: false, vertical: asked.rows.count <= 6)
            // Fork: "Loading your … vault…" / "Unlock Bitwarden…" / "Unlock 1Password…"
            VaultPendingRows(browser: browser, emptyLogin: emptyLogin)
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .medium))
                Text(footer)
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // Just under the box, left edges lined up. The offset is from the
        // stage's top-left, which is also the web view's.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private var footer: String { PickerFooter.text(for: asked) } // Fork: keychain, Bitwarden, 1Password

    private func isFetching(_ suggestion: Browser.Suggestion) -> Bool {
        switch suggestion {
        case .credential(let credential), .code(let credential):
            return browser.fetching == credential.id
        default:
            return false
        }
    }

    private struct Row: View {
        let suggestion: Browser.Suggestion
        let fetching: Bool
        let pick: () -> Void
        @State private var hovering = false

        @ViewBuilder
        var body: some View {
            switch suggestion {
            case .credential(let credential):
                credentialRow(credential)
            case .code(let credential):
                credentialRow(credential, code: true)
            case .username(let name):
                autofillRow(icon: "person", title: "Use \(name)", subtitle: "Most used")
            case .identity(let identity):
                autofillRow(
                    icon: "person.text.rectangle",
                    title: identity.fullName.isEmpty ? identity.name : identity.fullName,
                    subtitle: identity.summary
                )
            case .card(let card):
                autofillRow(
                    icon: "creditcard",
                    title: card.label.isEmpty ? card.name : card.label,
                    subtitle: card.cardholderName.isEmpty ? card.name : card.cardholderName
                )
            case .field(let field):
                let subtitle = field.itemName + (field.hidden ? " · hidden" : "")
                autofillRow(icon: "textformat.123", title: field.name, subtitle: subtitle)
            }
        }

        private func credentialRow(_ credential: Credential, code: Bool = false) -> some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: code ? "number" : credential.source.symbol) // Fork: per-source glyph
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(credential.user.isEmpty ? "No name" : credential.user)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(code ? "Two-step code · \(credential.host)" : credential.hasPasskey ? "\(credential.host) · passkey" : credential.host) // Fork: bitwarden-passkeys
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if fetching {
                        Ring(size: 10)
                        Text("Fetching…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fetching)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }

        private func autofillRow(icon: String, title: String, subtitle: String) -> some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
