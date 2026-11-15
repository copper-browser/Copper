import AppKit
import SwiftUI

// browser_handoff: an agent gives a step back to the person — a human check,
// a payment, a choice only they can make — and waits until they say done.
//
// Nothing moves on its own. The agent's tab stays where it is (often
// backstage, off screen); the window that holds it shows a bar at the bottom,
// in the same capsule as the camera's question: "<agent> needs you on <tab>:
// <message>", with Show (go to that tab — your click, never the agent's),
// Done and Not now. Copper in the background bounces its Dock icon once, the
// way a Mac app asks for attention without taking it. The call answers on
// Done, on Not now (an error: the agent must not carry on as if it were
// done), or after its timeout with the bar still up, so the agent can call
// again and keep waiting.

@MainActor
final class Handoff: ObservableObject {
    static let shared = Handoff()

    struct Ask: Identifiable, Equatable {
        let id = UUID()
        let tab: UUID
        let agent: String
        var message: String
    }

    enum Answer { case done, notNow }

    /// What is waiting on the person, oldest first; one per tab.
    @Published private(set) var asks: [Ask] = []
    /// Calls waiting on an ask: waiter id → (ask id, its continuation).
    private var waiters: [UUID: (ask: UUID, resume: CheckedContinuation<Answer?, Never>)] = [:]

    /// The ask open on this tab (its message brought up to date), else a new one.
    func ask(tab: UUID, agent: String, message: String) -> Ask {
        if let i = asks.firstIndex(where: { $0.tab == tab }) {
            asks[i].message = message
            return asks[i]
        }
        let ask = Ask(tab: tab, agent: agent, message: message)
        asks.append(ask)
        if !NSApp.isActive, !Headless.on { NSApp.requestUserAttention(.informationalRequest) }
        return ask
    }

    /// The person's answer, or nil when `timeout` passed first (the ask stays up).
    func wait(_ ask: Ask, timeout: TimeInterval) async -> Answer? {
        let waiter = UUID()
        return await withCheckedContinuation { (resume: CheckedContinuation<Answer?, Never>) in
            waiters[waiter] = (ask.id, resume)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.waiters.removeValue(forKey: waiter)?.resume.resume(returning: nil)
            }
        }
    }

    /// Done or Not now, from the bar: the ask goes, and every call waiting on it answers.
    func answer(_ id: UUID, _ answer: Answer) {
        asks.removeAll { $0.id == id }
        for (key, waiter) in waiters where waiter.ask == id {
            waiters[key] = nil
            waiter.resume.resume(returning: answer)
        }
    }

    /// The asks this window shows: those on its tabs (an agent's tab backstage
    /// belongs to the window that would show it). Gone tabs ask nothing.
    func asks(in browser: Browser) -> [Ask] {
        asks.filter { ask in AgentTabs.find(ask.tab).map { AgentTabs.owner(of: $0) === browser } ?? false }
    }

    /// `bench agent handoff [done|not-now]`: what is open, or answer the oldest — for the e2e.
    func bench(_ arg: String) -> [String: Any] {
        if let first = asks.first, arg == "done" || arg == "not-now" { answer(first.id, arg == "done" ? .done : .notNow) }
        return ["asks": asks.map { ["tab": String($0.tab.uuidString.prefix(8)).lowercased(), "agent": $0.agent, "message": $0.message] }]
    }

    // MARK: - the tool

    nonisolated static var tool: [String: Any] { [
        "name": "browser_handoff",
        "description": "Hand your tab to the user for a step only they should do (a human check, a payment, a choice) and wait for Done; their tab and focus never move unless they click Show.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "message": ["type": "string", "description": "What the user should do"],
                "timeout": ["type": "number", "description": "Seconds to wait, default 15, at most 600"],
                "reason": Tools.reasonProperty,
                "tab": Tools.tabProperty,
            ] as [String: Any],
            "required": [String](),
        ] as [String: Any],
    ] }

    static func call(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        // Not Tools.current: the tab is not staged or touched, only named in the bar.
        guard let tab = AgentTabs.target(in: browser) else { throw Tools.Failure(text: AgentTabs.missing()) }
        let said = [args["message"], args["reason"]].lazy.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let seconds = (args["timeout"] as? NSNumber)?.doubleValue ?? 15
        guard seconds.isFinite, seconds > 0 else { throw Tools.Failure(text: "timeout must be a number of seconds, more than 0 (at most 600)") }
        let ask = shared.ask(tab: tab.id, agent: DriveCaller.who?.agent ?? "An agent", message: said ?? "Finish this step yourself")
        switch await shared.wait(ask, timeout: min(seconds, 600)) {
        case .done:
            return [.text("The user says it is done. Take a fresh browser_snapshot before going on. \(Tools.pageLine(tab))")]
        case .notNow:
            throw Tools.Failure(text: "The user said not now. Leave this step undone and tell them in your reply. \(Tools.pageLine(tab))")
        case nil:
            return [.text("No answer yet after \(Int(min(seconds, 600))) s; the bar is still up for the user. Call browser_handoff again to keep waiting (timeout up to 600), or go on without this step. \(Tools.pageLine(tab))")]
        }
    }
}

/// The bar at the bottom of the window (App.swift `bars`), one ask at a time.
struct HandoffSlot: View {
    let browser: Browser
    @ObservedObject private var handoff = Handoff.shared

    var body: some View {
        if let ask = handoff.asks(in: browser).first {
            HandoffBar(ask: ask, tab: AgentTabs.find(ask.tab), elsewhere: ask.tab != browser.activeID && !Split.shared.has(ask.tab))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct HandoffBar: View {
    let ask: Handoff.Ask
    let tab: Tab?
    let elsewhere: Bool

    var body: some View {
        let title = tab.map { $0.title.isEmpty ? ($0.address?.host ?? "a tab") : $0.title } ?? "a tab"
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accent)
            (Text("\(ask.agent) needs you").fontWeight(.semibold) + Text(elsewhere ? " on \(title): \(ask.message)" : ": \(ask.message)"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if elsewhere, let tab {
                Button("Show") { AgentTabs.show(tab) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .help("Go to the tab the agent handed you")
            }
            Button { Handoff.shared.answer(ask.id, .done) } label: {
                Text("Done")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Tell \(ask.agent) the step is done")
            Button("Not now") { Handoff.shared.answer(ask.id, .notNow) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ask.agent) needs you: \(ask.message)")
    }
}
