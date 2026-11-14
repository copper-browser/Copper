import AppKit
import SwiftUI

// Invites, from the side of the person invited. Two places say one is
// waiting, and both read `Canvases.invites` (`GET /v1/invites`):
//
// - The pill at the window's foot (`CanvasInviteBar`): "<who> invited you to
//   “<name>” · Open ×". It rises for an invite this Copper hasn't shown
//   since it started and again whenever its sender reminds you (copper-cloud
//   0.5.0 moves the invite's `nudged_at` and sends a `canvas` event). It is
//   drawn over the panels — Settings, History, Downloads — so signing up in
//   Settings › Cloud doesn't hide the invite that was waiting for the
//   account. Open joins and opens the canvas; × is "Not now" — the pill goes,
//   the invite stays.
// - Invitations in the Canvas card at the sidebar's foot (CanvasUI.swift),
//   with Join and Decline, for as long as the invite is waiting; ⌘K offers
//   Join Canvas · <name> for each one too (CommandBar.swift).

@MainActor
enum CanvasInvites {
    /// What a Join came to.
    enum Joined: Equatable {
        /// The canvas is open in front (accepted, or a member already).
        case opened
        /// The invite had gone and the canvas isn't ours: the window said
        /// `Canvases.closedInvite`, quietly. Not an error.
        case closed
        /// It didn't work; the sentence that says why (also announced).
        case failed(String)

        var problem: String? { if case .failed(let said) = self { return said }; return nil }
    }

    /// Join: accept, then open the canvas in front. An invite that is no
    /// longer open (accepted elsewhere, joined through a link, withdrawn)
    /// leaves the pill and the list either way, and opens the canvas when
    /// this account is a member of it already.
    @discardableResult
    static func join(_ invite: Canvases.Invite, in browser: Browser) async -> Joined {
        do {
            if try await Canvases.shared.answer(invite, accept: true) == .closed {
                browser.announce(Canvases.closedInvite)
                return .closed
            }
            if let entry = Canvases.shared.entry(invite.canvasId) { CanvasHost.show(entry.id, in: browser, foreground: true) }
            return .opened
        } catch {
            let said = Canvases.explain(error)
            browser.announce(said)
            return .failed(said)
        }
    }

    /// The pill's sentence. A long name is cut here, so the pill keeps to
    /// a sentence's width instead of spanning the window.
    static func line(_ invite: Canvases.Invite) -> String {
        let reminded = invite.nudgedAt != nil
        let name = invite.canvasName.count > 48 ? String(invite.canvasName.prefix(46)) + "…" : invite.canvasName
        if invite.from.isEmpty {
            return reminded ? "A reminder: you were invited to “\(name)”" : "You were invited to “\(name)”"
        }
        return reminded ? "\(invite.from) reminded you about “\(name)”" : "\(invite.from) invited you to “\(name)”"
    }
}

/// The pill, over everything at the window's foot — the panels included.
/// ContentView draws it after `panels` (App.swift) and keeps its place in
/// `bars` with `CanvasInviteSlot`, so the other lines there stack above it.
struct CanvasInviteBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var canvases = Canvases.shared

    var body: some View {
        VStack(spacing: 8) {
            CanvasMentionStack(browser: browser) // Fork (canvas chat): a mention of you (CanvasChatUI.swift)
            if let invite = canvases.newInvite {
                CanvasInvitePill(invite: invite, browser: browser)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: canvases.newInvite)
    }
}

/// The pill's room in `bars`, unseen: whatever else rises from the foot
/// stands above it instead of under it.
struct CanvasInviteSlot: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var canvases = Canvases.shared

    var body: some View {
        CanvasMentionStack(browser: browser, placeholder: true)
        if let invite = canvases.newInvite {
            CanvasInvitePill(invite: invite, browser: browser)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

/// "<who> invited you to “<name>”  Open  ×".
struct CanvasInvitePill: View {
    let invite: Canvases.Invite
    @ObservedObject var browser: Browser
    @State private var joining = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(CanvasInvites.line(invite))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if joining {
                ProgressView().controlSize(.mini)
            }
            Button("Open") { open() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.accent, in: Capsule()) // Fork (ui-system)
                .disabled(joining)
                .help("Join “\(invite.canvasName)” and open it")
            Button {
                Canvases.shared.dismissNewInvite()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Not now — it stays under Invitations in the Canvas card")
            .accessibilityLabel("Not now")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invitation to \(invite.canvasName)\(invite.from.isEmpty ? "" : " from \(invite.from)")")
    }

    private func open() {
        guard !joining else { return }
        joining = true
        Task {
            await CanvasInvites.join(invite, in: browser)
            joining = false
        }
    }
}
