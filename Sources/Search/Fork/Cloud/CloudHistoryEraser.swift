import SwiftUI

// Settings › Cloud › Delete history on cloud, and the same for an agent
// (`cloud_history_delete`, `copper cloud-history delete`). The person
// chooses — a time range, maybe one site — and CloudSync.deleteHistory does
// the deleting; History on this Mac is never touched.

/// One delete from the page at a time, kept here rather than in the card so
/// it goes on, and its result stays, when Settings closes.
@MainActor
final class CloudHistoryEraser: ObservableObject {
    static let shared = CloudHistoryEraser()

    enum Span: String, CaseIterable, Identifiable {
        case hour, day, week, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hour: return "Last hour"
            case .day: return "Last 24 hours"
            case .week: return "Last 7 days"
            case .all: return "All time"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .hour: return 3_600
            case .day: return 86_400
            case .week: return 604_800
            case .all: return nil
            }
        }

        /// "the last hour"; nil for all time.
        var words: String? { seconds == nil ? nil : "the " + title.lowercased() }
    }

    @Published private(set) var working = false
    /// Looking through history on this Mac (a site was given): can be stopped.
    @Published private(set) var looking = false
    @Published private(set) var result: String?
    @Published private(set) var problem: String?
    private var task: Task<Void, Never>?

    /// No site and all time is everything — said, never assumed.
    static func selector(_ span: Span, site: String?, now: Date = Date()) -> CloudHistoryDelete.Selector {
        var selector = CloudHistoryDelete.Selector()
        if let seconds = span.seconds { selector.since = now.addingTimeInterval(-seconds) }
        if let site { selector.hosts = [site] }
        selector.everything = !selector.narrowed
        return selector
    }

    func run(_ span: Span, site: String?) {
        guard !working else { return }
        let selector = Self.selector(span, site: site)
        working = true
        looking = selector.scans
        result = nil
        problem = nil
        task = Task {
            defer {
                working = false
                looking = false
                task = nil
            }
            do {
                let outcome = try await CloudSync.shared.deleteHistory(selector)
                result = "Deleted \(outcome.deleted.formatted()) visit\(outcome.deleted == 1 ? "" : "s") from the cloud"
                    + (outcome.cut ? " — only the oldest \((CloudHistoryDelete.pageLimit * CloudHistoryDelete.pageSize).formatted()) were looked through" : "")
            } catch is CancellationError {
                result = "Stopped — nothing was deleted"
            } catch {
                problem = (error as? Cloud.Failure)?.message ?? error.localizedDescription
            }
        }
    }

    /// While looking only: once deleting has begun it finishes.
    func stop() { task?.cancel() }
}

struct CloudHistoryDeleteCard: View {
    @ObservedObject var cloud: Cloud
    @ObservedObject private var eraser = CloudHistoryEraser.shared
    @State private var span: CloudHistoryEraser.Span = .hour
    @State private var typed = ""
    @State private var asked = false
    @State private var confirming = false

    /// The site typed, as it will be matched; nil when none is.
    private var site: String? { CloudHistoryDelete.site(typed) }
    private var typedBadly: Bool { !typed.trimmingCharacters(in: .whitespaces).isEmpty && site == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Delete history on cloud")
            Card {
                switch cloud.deletesHistory {
                case true?: controls
                case false?: Line("Delete history on cloud", CloudHistoryDelete.unsupported) { EmptyView() }
                case nil:
                    Line("Delete history on cloud", asked ? "Couldn't reach the cloud to ask whether it can delete history." : "Asking the cloud what it can do…") {
                        if !asked { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let problem = eraser.problem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    Text(problem).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.red.opacity(0.85))
                .padding(.leading, 2)
            }
        }
        .task {
            if cloud.deletesHistory == nil { await cloud.loadInfo() }
            asked = true
        }
    }

    @ViewBuilder
    private var controls: some View {
        Line("Time range", "Visits on Copper Cloud, from every Mac signed in as you") {
            Segmented(options: CloudHistoryEraser.Span.allCases.map { ($0, $0.title) }, selection: $span)
        }
        Rule()
        Line("Only this site", "Optional; its subdomains too. Found by reading your history on this Mac — the cloud never looks inside it.") {
            TextField("example.com", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .autocorrectionDisabled()
                .frame(width: 170)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .settingsField() // SB-04
        }
        Rule()
        HStack(spacing: 8) {
            Text(status)
                .font(.system(size: 11.5))
                .foregroundStyle(typedBadly ? Color.red.opacity(0.85) : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if eraser.working {
                ProgressView().controlSize(.small)
                if eraser.looking {
                    Button("Stop", action: eraser.stop)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            Pill("Delete history on cloud…", tint: Color.red.opacity(0.85)) { confirming = true }
                .disabled(eraser.working || typedBadly)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .confirmationDialog(question, isPresented: $confirming) {
            Button("Delete", role: .destructive) { eraser.run(span, site: site) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copper Cloud deletes them for every Mac signed in as you. History on this Mac — and what your other Macs already have — stays as it is. This can't be undone.")
        }
    }

    private var status: String {
        if typedBadly { return "That isn't a site — try example.com" }
        if eraser.working { return eraser.looking ? "Looking through your history on this Mac…" : "Deleting…" }
        return eraser.result ?? "History on this Mac stays as it is."
    }

    private var question: String {
        switch (site, span.words) {
        case (nil, nil): return "Delete all of your history on the cloud?"
        case (nil, let words?): return "Delete \(words) of history on the cloud?"
        case (let site?, nil): return "Delete every visit to \(site) on the cloud?"
        case (let site?, let words?): return "Delete visits to \(site) from \(words) on the cloud?"
        }
    }
}

/// `cloud_history_delete`: the same for an agent the person runs on this
/// Mac, over the loopback server or `copper cloud-history delete`. Never the
/// pane beside the page (a page could ask it to) nor a bot through an agent
/// link: MCP lists it only to loopback clients, and a call from either is
/// refused.
@MainActor
enum CloudHistoryTool {
    static let name = "cloud_history_delete"

    static var schema: [String: Any] {
        func string(_ text: String) -> [String: Any] { ["type": "string", "description": text] }
        let list: [String: Any] = ["type": "array", "items": ["type": "string"]]
        var host = list, page = list
        host["description"] = "Only visits to these sites, each with its subdomains (x.com matches www.x.com, not notx.com). Matched on this Mac by paging through the history; the cloud never filters by content."
        page["description"] = "Only visits to exactly these pages (addresses; the query string is ignored, as History does)."
        let properties: [String: Any] = [
            "since": string("From when (inclusive): 30m, 1h, 24h, 7d, 2w, or an RFC 3339 time"),
            "until": string("Up to when (exclusive): the same forms"),
            "host": host,
            "page": page,
            "device": string("Only rows from this device id, or \"this\" for this Mac"),
            "all": ["type": "boolean", "description": "Delete all of the user's cloud history. Required when nothing else is given; not with the others."] as [String: Any],
            "reason": Tools.reasonProperty,
        ]
        return [
            "name": name,
            "description": "Delete the user's browsing history on Copper Cloud — every Mac's rows on their account — by time, site, page or device, or all of it. History on this Mac and on their other Macs is untouched; what is deleted is not sent back up. Irreversible: only on the user's explicit request. Returns {deleted, matched, looked, scanned, requests, complete, what}.",
            "inputSchema": ["type": "object", "properties": properties] as [String: Any],
        ]
    }

    static func call(_ args: [String: Any]) async throws -> [Tools.Content] {
        if let caller = AgentTabs.callerKey, caller == "pane" || caller.hasPrefix("bot:") || caller.hasPrefix("jev") {
            throw Tools.Failure(text: "\(name) is only for agents the user runs on this Mac — ask them to use Settings › Cloud")
        }
        do {
            let selector = try CloudHistoryDelete.selector(from: args, now: Date(), me: Cloud.shared.account?.deviceId)
            let outcome = try await CloudSync.shared.deleteHistory(selector)
            var json = outcome.json
            json["what"] = CloudHistoryDelete.words(selector)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            return [.text(String(decoding: data, as: UTF8.self))]
        } catch let failure as Cloud.Failure {
            throw Tools.Failure(text: failure.message)
        } catch is CancellationError {
            throw Tools.Failure(text: "Stopped — nothing was deleted")
        }
    }
}
