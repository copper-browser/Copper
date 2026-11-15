import AppKit
import SwiftUI

// A canvas's row, the way Arc keeps a board: a row you keep, renamed and
// deleted from its own context menu.
//
// - Its menu (TabMenu's first items, so the sidebar row, a favourite and the
//   top bar all have them): Rename Canvas… — a field on the row, as a
//   folder's Rename… is, or a sheet where there is no row — and Delete
//   Canvas… (Leave Canvas… on a shared canvas somebody else owns), a sheet
//   that says what happens first. Then Copper's ordinary tab items.
// - Renaming and deleting go through the Canvas registry (Canvases.rename,
//   .delete, .leave), so a shared canvas changes on the cloud for everyone,
//   every tab holding it follows (CanvasHost.renamed / .removed), and the
//   door's list says the same thing. Personal is neither renamed nor deleted.

@MainActor
enum CanvasRowActions {
    /// Whether the row's menu offers Rename Canvas… — and, when it can't be
    /// done right now, why not.
    static func canRename(_ entry: Canvases.Entry) -> Bool {
        !entry.isPersonal && entry.isOwner
    }

    /// Rename Canvas…, done. Nothing when the name is the same or empty; a
    /// failure (a shared canvas with no cloud) is said in the window.
    static func rename(_ id: String, to name: String, in browser: Browser) {
        guard let entry = Canvases.shared.entry(id) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, Canvases.clean(clean) != entry.name else { return }
        Task {
            do {
                try await Canvases.shared.rename(id, to: clean)
            } catch {
                browser.announce(Canvases.explain(error))
            }
        }
    }
}

// MARK: - the row's menu

/// The first items on a canvas's context menu — in the sidebar, a favourite
/// and the top bar alike (TabMenu). Nothing for any other tab, nor for
/// Personal, which is never renamed or deleted.
struct CanvasTabMenu: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var canvases = Canvases.shared

    var body: some View {
        if let id = CanvasTabs.showing(tab), let entry = canvases.entry(id), !entry.isPersonal {
            if CanvasRowActions.canRename(entry) {
                Button("Rename Canvas…") { CanvasRenaming.shared.ask(tab, in: browser) }
                    .disabled(entry.isShared && !canvases.cloudReady)
            }
            Button("Share…") { CanvasUI.shared.openShare(entry.id, in: browser) }
            Button(CanvasDelete.leaving(entry) ? "Leave Canvas…" : "Delete Canvas…", role: .destructive) {
                CanvasDelete.ask(id, in: browser)
            }
            .disabled(entry.isShared && !canvases.cloudReady)
            Divider()
        }
    }
}

// MARK: - renaming

/// Which canvas row is showing its name field, and where the rows that can
/// show one are. A row that is not on screen (a favourite, the top bar) gets
/// a sheet instead.
@MainActor
final class CanvasRenaming: ObservableObject {
    static let shared = CanvasRenaming()

    @Published var target: Tab.ID?
    /// Canvas rows on screen, by tab, in window points from the top left.
    var rows: [Tab.ID: CGRect] = [:]
    /// The browser whose row asked, so a failure is said in its window.
    weak var browser: Browser?

    func ask(_ tab: Tab, in browser: Browser) {
        guard let id = CanvasTabs.showing(tab) else { return }
        self.browser = browser
        guard rows[tab.id] != nil, tab.pin == nil else { return CanvasRenameSheet.ask(id, in: browser) }
        // After the menu has gone: a popover asked for while the context
        // menu is still closing is dropped.
        DispatchQueue.main.async { self.target = tab.id }
    }
}

/// On SideRow: the name field a canvas's row shows, and the row's place for
/// `ask` and the bench. Every row wears it; only a canvas's ever opens.
struct CanvasTabRow: ViewModifier {
    @ObservedObject var tab: Tab
    @ObservedObject private var renaming = CanvasRenaming.shared

    func body(content: Content) -> some View {
        content
            .popover(isPresented: Binding(get: { renaming.target == tab.id },
                                          set: { if !$0, renaming.target == tab.id { renaming.target = nil } }),
                     arrowEdge: .trailing) {
                CanvasRenameField(tab: tab)
            }
            .background { if CanvasTabs.showing(tab) != nil { CanvasRowSpot(id: tab.id) } }
    }
}

private struct CanvasRowSpot: View {
    let id: Tab.ID

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CanvasRenaming.shared.rows[id] = $0 }
            .onDisappear { CanvasRenaming.shared.rows[id] = nil }
    }
}

/// The field itself: the name as it is, selected, Return to keep the new one
/// and Escape (or a click away) to leave it — a folder's rename, for a canvas.
private struct CanvasRenameField: View {
    let tab: Tab
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Canvas name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .padding(8)
            .focused($focused)
            .onAppear {
                draft = CanvasTabs.showing(tab).flatMap { Canvases.shared.entry($0)?.name } ?? tab.title
                focused = true
            }
            .onSubmit {
                if let id = CanvasTabs.showing(tab) {
                    CanvasRowActions.rename(id, to: draft, in: CanvasRenaming.shared.browser ?? CanvasTabs.owner(of: tab))
                }
                CanvasRenaming.shared.target = nil
            }
    }
}

/// Rename Canvas… where there is no row to hang a field from.
@MainActor
enum CanvasRenameSheet {
    /// The sheet while it is up, for the bench.
    private(set) static var asking: NSAlert?
    private static var held: ((NSApplication.ModalResponse) -> Void)?

    static func ask(_ id: String, in browser: Browser) {
        guard let entry = Canvases.shared.entry(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Canvas"
        let field = NSTextField(string: entry.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            asking = nil
            held = nil
            guard response == .alertFirstButtonReturn else { return }
            CanvasRowActions.rename(id, to: field.stringValue, in: browser)
        }
        asking = alert
        CanvasSheets.present(alert, in: browser, decide: decide, hold: { held = $0 })
    }

    /// `bench canvas answer rename NAME|cancel` while this sheet is up.
    static func answer(_ choice: String, name: String) -> Bool {
        guard let alert = asking else { return false }
        if choice != "cancel", !name.isEmpty { (alert.accessoryView as? NSTextField)?.stringValue = name }
        let response: NSApplication.ModalResponse = choice == "cancel" ? .alertSecondButtonReturn : .alertFirstButtonReturn
        if let held { held(response) } else { alert.buttons[choice == "cancel" ? 1 : 0].performClick(nil) }
        return true
    }
}

/// Presenting the row's sheets. A window somebody can see gets a sheet; a
/// bench run with no window to see (headless, where every alert is declined
/// on the spot) holds the question open for `bench canvas answer` instead,
/// so the same decision runs either way.
@MainActor
enum CanvasSheets {
    static func present(_ alert: NSAlert, in browser: Browser, decide: @escaping (NSApplication.ModalResponse) -> Void,
                        hold: @escaping (@escaping (NSApplication.ModalResponse) -> Void) -> Void) {
        if Headless.on, Store.testing {
            hold(decide)
            return
        }
        DispatchQueue.main.async {
            if let window = Windows.window(of: browser) ?? Links.window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: decide)
            } else {
                decide(alert.runModal())
            }
        }
    }
}

// MARK: - deleting

/// Delete Canvas… asks first, and says what happens: a local canvas goes
/// from this Mac, a shared one you own goes for every member, and a shared
/// one somebody else owns is left — it stays for everyone else.
@MainActor
enum CanvasDelete {
    /// The sheet while it is up, so `bench canvas answer` can press a button.
    private(set) static var asking: NSAlert?
    /// What the last sheet did, for the bench.
    private(set) static var last = ""

    static var describe: [String: Any] {
        guard let alert = asking else { return ["last": last] }
        return ["message": alert.messageText, "detail": alert.informativeText, "buttons": alert.buttons.map(\.title), "last": last]
    }

    /// A member who isn't the owner leaves rather than deletes.
    static func leaving(_ entry: Canvases.Entry) -> Bool { entry.isShared && !entry.isOwner }

    /// What goes, said plainly — the door's words (CanvasUI's delete card).
    static func consequence(_ entry: Canvases.Entry) -> String {
        if leaving(entry) { return "It stays for everyone else. Someone will have to invite you again." }
        if entry.isShared { return "Permanently deletes this canvas and everything on it, for every member. This can't be undone." }
        return "Permanently deletes this canvas and everything on it from this Mac. This can't be undone."
    }

    static func ask(_ id: String, in browser: Browser) {
        guard let entry = Canvases.shared.entry(id), !entry.isPersonal else { return }
        let leave = leaving(entry)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = leave ? "Leave “\(entry.name)”?" : "Delete “\(entry.name)”?"
        alert.informativeText = consequence(entry)
        alert.addButton(withTitle: leave ? "Leave" : "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // Return confirms nothing here; Escape is Cancel.
        alert.buttons.first?.keyEquivalent = ""
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            asking = nil
            held = nil
            guard response == .alertFirstButtonReturn else { last = "cancelled"; return }
            last = leave ? "leaving" : "deleting"
            Task {
                do {
                    if leave { try await Canvases.shared.leave(id) } else { try await Canvases.shared.delete(id) }
                    last = leave ? "left" : "deleted"
                } catch {
                    last = "failed: " + Canvases.explain(error)
                    browser.announce(Canvases.explain(error))
                }
            }
        }
        asking = alert
        CanvasSheets.present(alert, in: browser, decide: decide, hold: { held = $0 })
    }

    private static var held: ((NSApplication.ModalResponse) -> Void)?

    /// `bench canvas answer delete|leave|cancel`: that button, pressed.
    static func answer(_ choice: String) -> Bool {
        guard let alert = asking else { return false }
        if let held {
            held(choice == "cancel" ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            return true
        }
        let wanted = choice == "cancel" ? "Cancel" : (alert.buttons.first?.title ?? "Delete")
        guard let button = alert.buttons.first(where: { $0.title == wanted }) else { return false }
        button.performClick(nil)
        return true
    }
}
