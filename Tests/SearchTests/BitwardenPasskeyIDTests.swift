import Foundation
import Testing
@testable import Search

// A Bitwarden passkey's credential id as the vault writes it — a GUID for
// one Bitwarden made, `b64.` + base64url for an imported one — and as the
// site knows it (raw bytes). allowCredentials matching rests on these.

@Suite("Bitwarden passkey ids")
struct BitwardenPasskeyIDTests {
    @Test func guidIsItsSixteenBytes() {
        let raw = BitwardenPasskeys.rawID("6f1b3a52-1c0e-4a37-9c55-2d1f0e9a7b01")
        #expect(raw == Data([0x6f, 0x1b, 0x3a, 0x52, 0x1c, 0x0e, 0x4a, 0x37, 0x9c, 0x55, 0x2d, 0x1f, 0x0e, 0x9a, 0x7b, 0x01]))
    }

    @Test func b64PrefixIsBase64URL() {
        #expect(BitwardenPasskeys.rawID("b64.Ym9iLWNyZWRlbnRpYWwtaWQtMDAwMQ") == Data("bob-credential-id-0001".utf8))
    }

    @Test func roundTrips() {
        let guid = Data((0..<16).map { UInt8($0 * 7) })
        #expect(BitwardenPasskeys.vaultID(guid).count == 36)
        #expect(BitwardenPasskeys.rawID(BitwardenPasskeys.vaultID(guid)) == guid)
        let long = Data((0..<32).map { UInt8($0) })
        #expect(BitwardenPasskeys.vaultID(long).hasPrefix("b64."))
        #expect(BitwardenPasskeys.rawID(BitwardenPasskeys.vaultID(long)) == long)
    }

    /// A passkey made here and saved to the vault has a valid v4 GUID id.
    @Test @MainActor func madeIDsAreVersion4UUIDs() throws {
        for _ in 0..<8 {
            let made = PasskeyStore.make(rpId: "example.test", userHandle: Data([1]), userName: "u", displayName: "U")
            #expect(made.id.count == 16)
            let text = BitwardenPasskeys.vaultID(made.id)
            let uuid = try #require(UUID(uuidString: text))
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            #expect(bytes[6] >> 4 == 4)
            #expect(bytes[8] & 0xC0 == 0x80)
            #expect(BitwardenPasskeys.rawID(text) == made.id)
        }
    }

    /// Counters advance by one, never wrap to zero, and zero stays zero.
    @Test func countersSaturate() {
        #expect(BitwardenPasskeys.advanced(0) == 0)
        #expect(BitwardenPasskeys.advanced(5) == 6)
        #expect(BitwardenPasskeys.advanced(UInt32.max - 1) == UInt32.max)
        #expect(BitwardenPasskeys.advanced(UInt32.max) == UInt32.max)
    }
}
