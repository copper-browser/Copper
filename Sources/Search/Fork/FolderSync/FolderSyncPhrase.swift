import CryptoKit
import Foundation
import Security

// The recovery phrase: 24 BIP-39 English words for 256 bits of entropy and an
// 8-bit checksum (the first byte of the entropy's SHA-256) — the format Dia's
// and Ardia's sync use. The phrase is the key: every sealed file in the sync
// folder opens with what it derives (FolderSyncCrypto.swift), and nothing else.
//
// Reading is lenient: case, punctuation, the kit's numbering ("1. abandon")
// and a word's first four letters are all taken.

enum SyncPhrase {
    static let count = 24

    static let words: [String] = SyncWordlist.english.split(whereSeparator: \.isWhitespace).map(String.init)
    private static let index: [String: Int] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
    /// Every BIP-39 word is told apart by its first four letters.
    private static let prefixes: [String: Int] = Dictionary(words.enumerated().map { (String($1.prefix(4)), $0) }, uniquingKeysWith: { a, _ in a })

    enum Problem: Error, Equatable, LocalizedError {
        case count(Int)
        case word(String)
        case checksum

        var errorDescription: String? {
            switch self {
            case .count: return "Recovery phrase must be exactly 24 words."
            case .word(let word): return "“\(word)” is not a valid recovery phrase word."
            case .checksum: return "This recovery phrase is not valid. Please check for typos."
            }
        }
    }

    /// 32 bytes of entropy as its 24 words.
    static func words(for entropy: Data) -> [String] {
        precondition(entropy.count == 32, "a phrase is 256 bits")
        var bits: [Bool] = []
        bits.reserveCapacity(264)
        for byte in entropy + [checksum(entropy)] {
            for shift in (0..<8).reversed() { bits.append((byte >> UInt8(shift)) & 1 == 1) }
        }
        return (0..<count).map { n in
            let value = bits[(n * 11)..<(n * 11 + 11)].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
            return words[value]
        }
    }

    /// The words typed, as they will be read: lower case, numbers and
    /// punctuation dropped. For the "12/24 words" counter as well.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isASCII && $0.isLetter) }
            .map(String.init)
    }

    /// The list word a typed one stands for: itself, or the one word that
    /// begins with its first four letters.
    static func word(_ token: String) -> Int? {
        if let at = index[token] { return at }
        guard token.count >= 4, let at = prefixes[String(token.prefix(4))], words[at].hasPrefix(token) else { return nil }
        return at
    }

    /// The entropy a phrase stands for, or what is wrong with it.
    static func entropy(from text: String) throws -> Data {
        let typed = tokens(text)
        guard typed.count == count else { throw Problem.count(typed.count) }
        var values: [Int] = []
        for token in typed {
            guard let value = word(token) else { throw Problem.word(token) }
            values.append(value)
        }
        var bits: [Bool] = []
        for value in values { for shift in (0..<11).reversed() { bits.append((value >> shift) & 1 == 1) } }
        var bytes = [UInt8](repeating: 0, count: 33)
        for (i, bit) in bits.enumerated() where bit { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
        let entropy = Data(bytes[0..<32])
        guard checksum(entropy) == bytes[32] else { throw Problem.checksum }
        return entropy
    }

    /// The checksum byte: the first of the entropy's SHA-256.
    private static func checksum(_ entropy: Data) -> UInt8 { Array(SHA256.hash(data: entropy))[0] }

    /// 32 fresh random bytes.
    static func fresh() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no randomness")
        return Data(bytes)
    }
}
