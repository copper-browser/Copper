import Foundation

// The coverage loop's counting (Agent.cover): a question that asks for a JSON
// answer of rows — a fenced template like {"rows": [{"name": …, "value": …,
// "source": …}]} — is checked after the draft answer. Asked rows × fields are
// counted against the ones filled AND backed by a page loaded in this run;
// the rows still short are asked again, a batch at a time, in fresh helper
// conversations, and their rows merged in where they cover more. Without
// such a template nothing here runs. Measured on the bench first (Hegemon
// v3, coverage.py): 100-row research went from 0 to 0.56, hours-style tasks
// from 0.22 to 0.71 mean score.

enum Coverage {
    /// What a rows-of-JSON question asks for.
    struct Spec: Equatable {
        var list: String
        /// The row's fields in the template's order; `key` names the row.
        var fields: [String]
        var key: String
        /// The field holding the row's source page, if the template has one.
        var url: String?
        /// "(N entries" in the question.
        var n: Int?
        /// The N names the question lists, when it lists exactly N.
        var names: [String]?
    }

    /// Where the rows stand: covered fields of all asked, and which rows are short.
    struct Count: Equatable {
        var ratio: Double
        var done: Int
        var asked: Int
        var missing: [String]
        /// Rows still to find when the question asks for N and names none.
        var short: Int
    }

    typealias Row = [String: Any]
    typealias Table = (order: [String], rows: [String: Row])

    static let empty: Set<String> = ["", "notshown", "none", "na", "n/a", "unknown", "null", "-", "notfound", "notavailable", "notlisted"]
    private static let fence = try! NSRegularExpression(pattern: "```(?:json)?\\s*(\\{.*?\\})\\s*```", options: [.dotMatchesLineSeparators])

    // MARK: - words

    static func norm(_ value: Any?) -> String {
        let text = string(value).decomposedStringWithCompatibilityMapping.lowercased()
        return String(text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) }.map(Character.init))
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let v?: return "\(v)"
        }
    }

    static func filled(_ value: Any?) -> Bool {
        if let dict = value as? [String: Any] { return dict.values.contains { filled($0) } }
        if let list = value as? [Any] { return list.contains { filled($0) } }
        let raw = string(value).trimmingCharacters(in: .whitespaces).lowercased()
        return !empty.contains(norm(value)) && !empty.contains(raw)
    }

    /// An address as pages are compared: no scheme, www, fragment or trailing slash; host lowercased.
    static func canon(_ url: Any?) -> String {
        var u = string(url).trimmingCharacters(in: .whitespaces)
        u = String(u.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if let r = u.range(of: "^https?://(www\\.)?", options: [.regularExpression, .caseInsensitive]) { u.removeSubrange(r) }
        let parts = u.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var out = parts[0].lowercased() + "/" + (parts.count > 1 ? parts[1] : "")
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    // MARK: - the question

    /// The JSON documents in fenced blocks, last first, each with its raw text.
    private static func blocks(_ text: String) -> [(json: [String: Any], raw: String, range: Range<String.Index>)] {
        let ns = text as NSString
        return fence.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed().compactMap { m in
            let raw = ns.substring(with: m.range(at: 1))
            guard let doc = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let range = Range(m.range, in: text) else { return nil }
            return (doc, raw, range)
        }
    }

    /// The row template's fields in the order the question wrote them.
    private static func ordered(_ row: Row, in raw: String) -> [String] {
        func at(_ key: String) -> Int {
            let quoted = (try? JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\(key)\""
            guard let r = raw.range(of: quoted + "\\s*:", options: .regularExpression) else { return Int.max }
            return raw.distance(from: raw.startIndex, to: r.lowerBound)
        }
        return row.keys.sorted { (at($0), $0) < (at($1), $1) }
    }

    private static func names(_ question: String, _ n: Int) -> [String]? {
        let pattern = try! NSRegularExpression(pattern: ":\\s*([^:]+?)\\.(?:\\s|$)")
        let ns = question as NSString
        for m in pattern.matches(in: question, range: NSRange(location: 0, length: ns.length)) {
            let segment = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            for sep in [";", ","] {
                let parts = segment.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^(and|or)\\s+", with: "", options: .regularExpression) }
                    .filter { !$0.isEmpty }
                if parts.count == n, parts.allSatisfy({ $0.count <= 80 }) { return parts }
            }
        }
        return nil
    }

    /// The question's rows template, or nil when it asks for no rows of JSON.
    static func spec(_ question: String) -> Spec? {
        for block in blocks(question) {
            for (list, value) in block.json.sorted(by: { $0.key < $1.key }) {
                guard let rows = value as? [Any], let row = rows.first as? Row, !row.isEmpty else { continue }
                let fields = ordered(row, in: block.raw)
                let url = fields.first { ["source", "url", "sourceurl"].contains(norm($0)) }
                    ?? fields.last { string(row[$0]).hasPrefix("http") }
                let n = (firstInt(#"\((\d+) entries"#, question) ?? firstInt(#"\b(\d+) entries\b"#, question))
                return Spec(list: list, fields: fields, key: fields[0], url: url, n: n, names: n.flatMap { names(question, $0) })
            }
        }
        return nil
    }

    private static func firstInt(_ pattern: String, _ text: String) -> Int? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(text[r].filter(\.isNumber))
    }

    // MARK: - an answer's rows

    /// The reply's rows: its last JSON block's list (the spec's, else its first list of objects).
    static func rows(_ reply: String, _ spec: Spec) -> [Row] {
        guard let doc = blocks(reply).first?.json else { return [] }
        let list = (doc[spec.list] as? [Any]) ?? doc.sorted(by: { $0.key < $1.key }).lazy.compactMap { $0.value as? [Any] }.first ?? []
        return list.compactMap { $0 as? Row }
    }

    private static func variants(_ value: Any?) -> Set<String> {
        let s = string(value)
        var out: Set<String> = [norm(s), norm(s.components(separatedBy: ",")[0]), norm(s.components(separatedBy: "(")[0])]
        out.formUnion(out.filter { $0.hasPrefix("the") }.map { String($0.dropFirst(3)) })
        out.remove("")
        return out
    }

    /// The spec fitted to the draft's rows: the key is the first field whose
    /// values all differ (a year shared by rows is no key); the names go when
    /// fewer than half the rows name one (they listed fields, not rows).
    static func fit(_ spec: Spec, draft: [Row]) -> Spec {
        var spec = spec
        if draft.count >= 2 {
            for field in spec.fields {
                let values = draft.compactMap { row -> String? in
                    let v = row[field]
                    return v is [String: Any] || v is [Any] || !filled(v) ? nil : norm(v)
                }
                if values.count == draft.count, Set(values).count == values.count { spec.key = field; break }
            }
        }
        if spec.names != nil, !draft.isEmpty, 2 * draft.filter({ which($0, spec) != nil }).count < draft.count { spec.names = nil }
        return spec
    }

    /// The asked name a row is about (names known), else its key value; nil if none.
    static func which(_ row: Row, _ spec: Spec) -> String? {
        guard let names = spec.names else { let k = norm(row[spec.key]); return k.isEmpty ? nil : k }
        let got = variants(row[spec.key])
        return names.first { !got.isDisjoint(with: variants($0)) }
    }

    /// A row's covered fields: the filled ones, when its source was loaded
    /// (or the template has no source field); an unbacked row counts its name only.
    static func done(_ row: Row?, _ spec: Spec, loaded: Set<String>) -> Int {
        guard let row else { return 0 }
        if let url = spec.url, !loaded.contains(canon(row[url])) { return filled(row[spec.key]) ? 1 : 0 }
        return spec.fields.filter { filled(row[$0]) }.count
    }

    /// The rows by the name they answer, in asked order (names known) or reply order.
    static func table(_ rows: [Row], _ spec: Spec) -> Table {
        var order: [String] = [], out: [String: Row] = [:]
        for row in rows {
            guard let k = which(row, spec), out[k] == nil else { continue }
            order.append(k)
            out[k] = row
        }
        if let names = spec.names { order = names.filter { out[$0] != nil } }
        return (order, out)
    }

    static func count(_ table: Table, _ spec: Spec, loaded: Set<String>) -> Count {
        let nf = spec.fields.count
        let names = spec.names ?? table.order
        let n = max(spec.n ?? 0, names.count, table.order.count)
        let got = names.reduce(0) { $0 + done(table.rows[$1], spec, loaded: loaded) }
        let missing = names.filter { done(table.rows[$0], spec, loaded: loaded) < nf }
        let short = spec.names == nil ? max(0, (spec.n ?? 0) - table.order.count) : 0
        let ratio = n == 0 ? 1 : (Double(got) / Double(n * nf) * 10_000).rounded() / 10_000
        return Count(ratio: ratio, done: got, asked: n * nf, missing: missing, short: short)
    }

    static func batches<T>(_ items: [T], _ size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: max(1, size)).map { Array(items[$0..<min($0 + max(1, size), items.count)]) }
    }

    private static func label(_ k: String, _ table: Table, _ spec: Spec) -> String {
        spec.names != nil ? k : (table.rows[k].map { string($0[spec.key]) } ?? k)
    }

    /// A helper's question: the whole task for context, then only these rows,
    /// what the draft has for them, and the reply's shape.
    static func batchPrompt(_ task: String, _ spec: Spec, items: [String], table: Table, short: Int = 0) -> String {
        let have = items.compactMap { table.rows[$0] }
        let names = items.map { label($0, table, spec) }
        let extra = short > 0 ? " Also find up to \(short) more entries the task asks for that are not among: \(table.order.map { label($0, table, spec) }.joined(separator: "; "))." : ""
        let gaps = have.isEmpty ? "" : "\nWhat an earlier pass has for them (fields \"not shown\" or missing, or a source page that was not loaded, still need a page):\n```json\n\(json(have, spec))\n```"
        let what = items.isEmpty ? extra.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Also find", with: "Find")
            : "Do the task above for ONLY these \(items.count) entries: \(names.joined(separator: "; ")).\(extra)"
        return "\(task)\n\n---\nThis is one batch of a larger job; other workers do the other entries. \(what)\(gaps)\n"
            + "For each entry, load its own page on the site the task requires and fill every field from that page. Go straight to the "
            + "official site when you know or can guess its address; if a search engine blocks you or its results are unusable, use another "
            + "engine or open the official address directly. Write \"not shown\" only after you loaded that entry's own page and it does "
            + "not show the value. Do every entry in this batch before you answer.\n"
            + "End your reply with one JSON code block {\"\(spec.list)\": [...]} with only these entries, in this order, each in the "
            + "exact row shape the task asks for."
    }

    /// Merges a helper's rows: one replaces the row for its name when it covers
    /// more. `items` are the names it may change (a new row may come in when
    /// the question names none). How many rows got better.
    @discardableResult
    static func absorb(_ table: inout Table, _ rows: [Row], _ spec: Spec, loaded: Set<String>, items: Set<String>? = nil) -> Int {
        var better = 0
        for row in rows {
            guard let k = which(row, spec) else { continue }
            if let items, !items.contains(k), spec.names != nil || table.rows[k] != nil { continue }
            guard done(row, spec, loaded: loaded) > done(table.rows[k], spec, loaded: loaded) else { continue }
            if table.rows[k] == nil, spec.names == nil { table.order.append(k) }
            table.rows[k] = row
            better += 1
        }
        if let names = spec.names { table.order = names.filter { table.rows[$0] != nil } }
        return better
    }

    /// The reply with its last JSON block's rows replaced by the merged ones
    /// (other keys kept); a reply without a block gets one at its end.
    static func render(_ reply: String, _ spec: Spec, _ table: Table) -> String {
        let found = blocks(reply).first
        var doc = found?.json ?? [:]
        doc[spec.list] = nil
        let rest = doc.sorted { $0.key < $1.key }.map { "\(quote($0.key)): \(value($0.value))" }
        let body = "{\(quote(spec.list)): \(json(table.order.compactMap { table.rows[$0] }, spec))" + rest.map { ", " + $0 }.joined() + "}"
        let block = "```json\n\(body)\n```"
        guard let found else { return reply.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block }
        return reply.replacingCharacters(in: found.range, with: block)
    }

    /// Rows as JSON, each one's fields in the template's order.
    private static func json(_ rows: [Row], _ spec: Spec) -> String {
        "[" + rows.map { row in
            let keys = spec.fields.filter { row[$0] != nil } + row.keys.filter { !spec.fields.contains($0) }.sorted()
            return "{" + keys.compactMap { k in row[k].map { "\(quote(k)): \(value($0))" } }.joined(separator: ", ") + "}"
        }.joined(separator: ", ") + "]"
    }

    private static func quote(_ s: String) -> String { value(s) }

    private static func value(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: - pages loaded

    /// The pages a tool says it loaded: browser_read's `[n] ok · asked → final`
    /// lines and a page block's `- URL:` line.
    static func pages(in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("- URL: ") {
                out.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            } else if let r = line.range(of: #"^\[\d+\] ok · "#, options: .regularExpression) {
                let rest = line[r.upperBound...].components(separatedBy: " · ")[0]
                out += rest.components(separatedBy: " → ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("http") }
            }
        }
        return out
    }

    /// The addresses a call itself names (`url`, `urls`): pages it was sent to.
    static func pages(args: [String: Any]) -> [String] {
        ((args["urls"] as? [Any]) ?? [args["urls"] as Any, args["url"] as Any]).compactMap { $0 as? String }.filter { $0.hasPrefix("http") }
    }
}
