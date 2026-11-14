import AppKit
import WebKit

// alert(), confirm() and prompt() on a page an agent is working in.
//
// A page hung backstage (Backstage.swift) is on no screen, so its questions
// were declined on the spot — confirm() false, prompt() null — and the agent
// never knew one was asked: "Delete?" said no, the button did nothing, and
// the agent went looking for why. Now every question on an agent's tab is
// written down (what kind, what it said, what it was told) and the next tool
// answer for that tab carries it under "### Dialogs".
//
// `browser_handle_dialog` (Playwright MCP's name and arguments) answers it:
//   - called after the click, it answers the question still open, as in
//     Playwright: an unanswered question stays open until then — or until
//     the agent's next other call on that tab, or `holdFor`, which give it
//     the answer a closed sheet gives (OK, false, null);
//   - called before, it arms the answer for the next question, given the
//     moment it comes.
// A question is never held while one of Copper's own scripts waits on that
// page (`Tools.Page.waiting`): the page is stopped inside the question, so
// the script would wait on it too. That one gets the closed-sheet answer at
// once, or the armed one.
//
// A tab on the user's screen keeps its sheet for the user, unless the agent
// armed an answer first; the question is noted as shown to the user.

@MainActor
enum AgentDialogs {
    enum Kind: String { case alert, confirm, prompt }

    private struct Plan { let accept: Bool; let text: String? }
    private struct Open {
        let kind: Kind
        let message: String
        let defaultText: String?
        let finish: (Bool, String?) -> Void
        let timer: Timer
    }

    /// How long a question waits open for browser_handle_dialog.
    static let holdFor: TimeInterval = 30

    /// One armed answer per tab, for the next question its page asks.
    private static var armed: [UUID: Plan] = [:]
    /// The question each tab's page is stopped in, waiting for an answer.
    private static var open: [UUID: Open] = [:]
    /// What pages asked and what they were told, until a tool answer for
    /// the tab carries it.
    private static var asked: [UUID: [String]] = [:]

    /// The page asks. True when the agent's side takes the question —
    /// `finish(accepted, promptText)` is then called exactly once, now or
    /// later; false when it is the user's, and the sheet is shown as before.
    static func take(_ web: WKWebView, _ kind: Kind, _ message: String, defaultText: String? = nil,
                     finish: @escaping (Bool, String?) -> Void) -> Bool {
        guard let tab = AgentTabs.all.first(where: { $0.built === web }) else { return false }
        let unattended = Dialogs.unattended(web)
        guard unattended || Backstage.shared.holds(tab.id) || armed[tab.id] != nil else { return false }
        if let plan = armed.removeValue(forKey: tab.id) {
            let text = kind == .prompt && plan.accept ? (plan.text ?? defaultText ?? "") : nil
            note(tab.id, kind, message, plan.accept ? (text.map { "accepted with \(quoted($0))" } ?? "accepted") : "dismissed")
            finish(plan.accept, text)
            return true
        }
        guard unattended else {
            note(tab.id, kind, message, "shown to the user, who answers it")
            return false
        }
        if Tools.Page.waiting[ObjectIdentifier(web), default: 0] > 0 {
            note(tab.id, kind, message, closed(kind) + " — a script of Copper's was waiting on the page; arm browser_handle_dialog before the action to answer it")
            finish(false, nil)
            return true
        }
        let id = tab.id
        close(id, because: "a new question came") // a page asks one at a time; never leave one hanging
        let timer = Timer(timeInterval: holdFor, repeats: false) { _ in
            MainActor.assumeIsolated { close(id, because: "unanswered for \(Int(holdFor)) s") }
        }
        RunLoop.main.add(timer, forMode: .common)
        open[id] = Open(kind: kind, message: message, defaultText: defaultText, finish: finish, timer: timer)
        note(id, kind, message, "open — answer it with browser_handle_dialog (accept, promptText); your next other call on this tab dismisses it")
        return true
    }

    /// browser_handle_dialog: answer the question open on the tab, or arm
    /// the answer for the next one. Says which, for the tool answer.
    static func handle(_ tab: Tab, accept: Bool, text: String?) -> String {
        guard let question = open.removeValue(forKey: tab.id) else {
            armed[tab.id] = Plan(accept: accept, text: text)
            let how = accept ? "accepted" + (text.map { " with \(quoted($0))" } ?? "") : "dismissed"
            return "No dialog is open on this tab. The next alert, confirm or prompt will be \(how) the moment it comes — now do what makes the page ask."
        }
        question.timer.invalidate()
        let answer = question.kind == .prompt && accept ? (text ?? question.defaultText ?? "") : nil
        question.finish(accept, answer)
        let how = accept ? (answer.map { "Accepted with \(quoted($0))" } ?? "Accepted") : "Dismissed"
        return "\(how): the \(question.kind.rawValue) \(quoted(question.message))."
    }

    /// The agent moved on (a call on this tab that isn't browser_handle_dialog):
    /// an open question gets the closed-sheet answer, so the page runs again.
    static func moveOn(_ tab: Tab?) {
        guard let tab else { return }
        close(tab.id, because: "you moved on without browser_handle_dialog")
    }

    /// What the tab's pages asked since the last answer, once, as a section
    /// of a tool answer.
    static func report(_ tab: Tab?) -> [Tools.Content] {
        guard let tab, let lines = asked.removeValue(forKey: tab.id), !lines.isEmpty else { return [] }
        return [.text("### Dialogs\n" + lines.joined(separator: "\n"))]
    }

    private static func close(_ id: UUID, because why: String) {
        guard let question = open.removeValue(forKey: id) else { return }
        question.timer.invalidate()
        note(id, question.kind, question.message, "\(closed(question.kind)) (\(why))")
        question.finish(false, nil)
    }

    /// The answer a closed sheet gives.
    private static func closed(_ kind: Kind) -> String { kind == .alert ? "OK" : "dismissed" }

    private static func note(_ id: UUID, _ kind: Kind, _ message: String, _ outcome: String) {
        var lines = asked[id] ?? []
        lines.append("- \(kind.rawValue) \(quoted(message)) → \(outcome)")
        asked[id] = Array(lines.suffix(20))
    }

    private static func quoted(_ text: String) -> String {
        Tools.Page.quote(text.count > 300 ? String(text.prefix(299)) + "…" : text)
    }
}
