import Foundation

// What the owner watching an agent thread sees of a Jev run while it runs:
// the `progress` object of a link `progress` frame (LinkWire.progress), built
// from the same Drive.Run the pane beside the page reads.
//
// A pure function with hard caps, so a frame stays small whatever the page
// says: goal ≤ 300, note ≤ 300, url ≤ 500, title ≤ 200, the last ≤ 12
// cycles, phase title ≤ 120 / detail ≤ 160, outcome operation ≤ 40 / label
// ≤ 120 / text ≤ 120. Lengths are UTF-16 units — what the service's zod
// `.max()` counts. The whole frame is then held under 16 KB by
// `LinkWire.progress`, which drops the oldest cycles until it fits.
//
// Nothing secret is in a trace to begin with: SIGN_IN and AUTOFILL fill
// in-process and carry no text, and `text` is only what Jev wrote into an
// ordinary field. As a second fence, text aimed at a field whose label
// reads like a secret (password, code, card number …) is masked here.
//
// The JSON shape (contracts `JevProgress`):
//   {v:1, kind:'jev', goal, status, note?, startedAt, endedAt?,
//    page:{url,title}, cycles:<total>,
//    recent:[{n, startedAt, endedAt?, phases:[{kind,title,detail?,ms?}],
//             outcome?:{operation,label,text?,probability,pageChanged?,stale}}]}

enum JevProgress {
    static let recentLimit = 12

    static func build(_ run: Drive.Run) -> [String: Any] {
        var out: [String: Any] = [
            "v": 1,
            "kind": "jev",
            "goal": cap(run.goal, 300),
            "status": run.status.rawValue,
            "startedAt": iso(run.started),
            "page": ["url": cap(run.url, 500), "title": cap(run.title, 200)],
            "cycles": run.cycles.count,
            "recent": run.cycles.suffix(recentLimit).map(cycle),
        ]
        let note = run.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { out["note"] = cap(note, 300) }
        if let ended = run.ended { out["endedAt"] = iso(ended) }
        // Fork (secret-redact): what a linked app is told never holds a secret Copper filled.
        return AgentSecrets.scrub(json: out) as? [String: Any] ?? out
    }

    static func cycle(_ c: Drive.Cycle) -> [String: Any] {
        var out: [String: Any] = [
            "n": c.number,
            "startedAt": iso(c.started),
            "phases": c.phases.map(phase),
        ]
        if let ended = c.ended { out["endedAt"] = iso(ended) }
        if let o = c.outcome { out["outcome"] = outcome(o) }
        return out
    }

    static func phase(_ p: Drive.Phase) -> [String: Any] {
        var out: [String: Any] = ["kind": p.kind.rawValue, "title": cap(p.title, 120)]
        if let detail = p.detail, !detail.isEmpty { out["detail"] = cap(detail, 160) }
        if let ms = p.ms { out["ms"] = max(0, ms) }
        return out
    }

    static func outcome(_ o: Drive.Outcome) -> [String: Any] {
        let probability = o.probability.isFinite ? min(1, max(0, o.probability)) : 0
        var out: [String: Any] = [
            "operation": cap(o.operation, 40),
            "label": cap(o.label, 120),
            "probability": (probability * 1000).rounded() / 1000,
            "stale": o.stale,
        ]
        if let text = o.text, !text.isEmpty {
            out["text"] = looksSecret(o.label) ? "•••" : cap(text, 120)
        }
        if let changed = o.pageChanged { out["pageChanged"] = changed }
        if let result = o.result { out["result"] = result }
        return out
    }

    /// A field label that names something that must never be shown.
    static func looksSecret(_ label: String) -> Bool {
        let l = label.lowercased()
        if ["password", "passcode", "passphrase", "passwd", "one-time", "verification code", "security code",
            "card number", "social security"].contains(where: { l.contains($0) }) { return true }
        // Short words only as whole words: "pin" is not "shipping".
        let words = Set(l.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !words.isDisjoint(with: ["otp", "totp", "2fa", "mfa", "cvv", "cvc", "csc", "pin", "ssn", "secret", "token"])
    }

    /// At most `limit` UTF-16 units, ending in "…" when cut; never splits a
    /// character.
    static func cap(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf16.count
            if used + n > limit - 1 { break }
            out.append(ch)
            used += n
        }
        return out + "…"
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
