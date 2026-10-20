import Foundation

/// What a site says a new password may be: its `passwordrules` attribute
/// (the WHATWG proposal Safari reads), plus the box's own `minlength` and
/// `maxlength`. Every part is optional; what isn't said falls back to the
/// defaults below, which most sites accept as they are.
struct PasswordRules: Equatable {
    var minLength: Int?
    var maxLength: Int?
    /// Each entry is one `required:` rule: the password holds at least one
    /// character from that set.
    var required: [Set<Character>] = []
    /// Every character the password may use. Nil means the default pool.
    var allowed: Set<Character>?
    var maxConsecutive: Int?

    init(minLength: Int? = nil, maxLength: Int? = nil) {
        self.minLength = minLength.flatMap { $0 > 0 ? $0 : nil }
        self.maxLength = maxLength.flatMap { $0 > 0 ? $0 : nil }
    }

    /// `required: lower; required: upper, digit; allowed: [-_]; max-consecutive: 2; minlength: 15; maxlength: 64`
    init(passwordrules text: String, minLength: Int? = nil, maxLength: Int? = nil) {
        self.init(minLength: minLength, maxLength: maxLength)
        var allowed: Set<Character> = []
        var saidAllowed = false
        for rule in text.split(separator: ";") {
            let parts = rule.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased()
            let value = parts[1]
            switch name {
            case "required":
                let set = Self.characters(in: value)
                if !set.isEmpty { required.append(set) }
            case "allowed":
                saidAllowed = true
                allowed.formUnion(Self.characters(in: value))
            case "max-consecutive":
                if let n = Int(value), n > 0 { maxConsecutive = min(maxConsecutive ?? n, n) }
            case "minlength":
                if let n = Int(value), n > 0 { self.minLength = max(self.minLength ?? n, n) }
            case "maxlength":
                if let n = Int(value), n > 0 { self.maxLength = min(self.maxLength ?? n, n) }
            default:
                continue
            }
        }
        // A required set is allowed too, even when `allowed:` didn't repeat it.
        if saidAllowed {
            for set in required { allowed.formUnion(set) }
            self.allowed = allowed
        }
    }

    static let lower = Set("abcdefghijklmnopqrstuvwxyz")
    static let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digit = Set("0123456789")
    /// The spec's `special`: ASCII printable punctuation and space.
    static let special = Set(" !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
    /// The symbols used when a site says nothing: none that need quoting in
    /// a shell or a URL, and none a form commonly refuses (quotes, angle
    /// brackets, backslash, space).
    static let defaultSymbols = Set("!#$%&*+-=?@^_")

    /// The characters a value names: classes (`upper, lower, digit, special,
    /// ascii-printable, unicode`) and bracketed sets like `[-().&@?'#,/"+]`,
    /// separated by commas.
    static func characters(in value: String) -> Set<Character> {
        var result: Set<Character> = []
        var rest = Substring(value)
        while let first = rest.first {
            if first == "[" {
                // A `]` straight after `[` or `-` at either end is literal.
                var body = rest.dropFirst()
                var set: [Character] = []
                if body.first == "]" { set.append("]"); body = body.dropFirst() }
                guard let close = body.firstIndex(of: "]") else { break }
                set.append(contentsOf: body[..<close])
                result.formUnion(set)
                rest = body[body.index(after: close)...]
                continue
            }
            if first == "," || first.isWhitespace { rest = rest.dropFirst(); continue }
            let word = rest.prefix { $0 != "," && $0 != "[" && !$0.isWhitespace }
            guard !word.isEmpty else { rest = rest.dropFirst(); continue }
            switch word.lowercased() {
            case "upper": result.formUnion(upper)
            case "lower": result.formUnion(lower)
            case "digit": result.formUnion(digit)
            case "special": result.formUnion(special)
            case "ascii-printable", "unicode": result.formUnion(lower.union(upper).union(digit).union(special))
            default: break
            }
            rest = rest.dropFirst(word.count)
        }
        return result
    }
}

/// A new password made on this Mac. Random from the system's
/// cryptographically secure generator (`SystemRandomNumberGenerator`, which
/// is `arc4random_buf` here), so it needs no vault to be open — the keychain
/// gets the same strength as Bitwarden or 1Password.
enum StrongPassword {
    static let defaultLength = 20
    /// No character three times in a row unless the site asks for less.
    static let defaultMaxConsecutive = 2

    /// The length a password for these rules will have.
    static func length(for rules: PasswordRules) -> Int {
        var length = max(defaultLength, rules.minLength ?? 0)
        if let most = rules.maxLength { length = min(length, most) }
        return max(length, 1)
    }

    /// A password that keeps every rule given, with all four character
    /// classes when the site doesn't narrow them, and never containing any
    /// of `avoiding` (the username, say — sites refuse that) when it is three
    /// characters or more.
    static func generate(rules: PasswordRules = PasswordRules(), avoiding: [String] = []) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(rules: rules, avoiding: avoiding, using: &generator)
    }

    static func generate<G: RandomNumberGenerator>(
        rules: PasswordRules, avoiding: [String] = [], using generator: inout G
    ) -> String {
        let pool: Set<Character>
        var required: [Set<Character>]
        // A space is legal under `special` but a trap in a password nobody
        // types: forms trim it, and some refuse it.
        if let allowed = rules.allowed, !allowed.subtracting([" "]).isEmpty {
            pool = allowed.subtracting([" "])
            required = rules.required
        } else {
            let symbols = rules.required.reduce(PasswordRules.defaultSymbols) {
                $0.union($1.intersection(PasswordRules.special).subtracting([" "]))
            }
            pool = PasswordRules.lower.union(PasswordRules.upper).union(PasswordRules.digit).union(symbols)
            required = rules.required
            // With no rules from the site, ask for every class: the strictest
            // common policy ("3 of 4") is met with room to spare.
            if required.isEmpty {
                required = [PasswordRules.lower, PasswordRules.upper, PasswordRules.digit, PasswordRules.defaultSymbols]
            }
        }
        // A required set with nothing usable in it can't be honoured; drop
        // it rather than loop forever.
        required = required.map { $0.intersection(pool) }.filter { !$0.isEmpty }
        let chars = Array(pool).sorted()
        let size = max(length(for: rules), required.count)
        let consecutive = rules.maxConsecutive ?? defaultMaxConsecutive
        let banned = avoiding
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 3 }

        var best = ""
        for _ in 0..<200 {
            var picked: [Character] = required.map { set in
                let options = Array(set).sorted()
                return options[Int.random(in: 0..<options.count, using: &generator)]
            }
            while picked.count < size {
                picked.append(chars[Int.random(in: 0..<chars.count, using: &generator)])
            }
            picked.shuffle(using: &generator)
            let candidate = String(picked)
            best = candidate
            guard longestRun(candidate) <= consecutive else { continue }
            let lowered = candidate.lowercased()
            guard !banned.contains(where: { lowered.contains($0) }) else { continue }
            return candidate
        }
        return best
    }

    /// The longest run of one character repeated, for `max-consecutive`.
    static func longestRun(_ text: String) -> Int {
        var longest = 0, run = 0
        var previous: Character?
        for character in text {
            run = character == previous ? run + 1 : 1
            longest = max(longest, run)
            previous = character
        }
        return longest
    }
}
