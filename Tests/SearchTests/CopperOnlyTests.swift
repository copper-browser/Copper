import Foundation
import Testing
@testable import Search

// Copper only (CHANGELOG): what the rename must not break. A test world's
// settings follow it to the new suite name once, and an extension prepared
// under the old shim marker gets Copper's shim in place of that one, not on
// top of it.

@Suite struct CopperOnlyTests {
    @Test func aWorldsSettingsMoveToTheNewSuiteOnce() {
        let id = UUID().uuidString
        let old = "com.officecommun.search.test.unit-\(id)", new = "com.collinrijock.copper.test.unit-\(id)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        Store.adopt(new, from: old)
        #expect(defaults.persistentDomain(forName: new) == nil) // nothing to take
        defaults.setPersistentDomain(["bench": false, "look": "dark"], forName: old)
        defaults.setPersistentDomain(["bench": true], forName: new) // written before launch
        Store.adopt(new, from: old)
        #expect(defaults.persistentDomain(forName: new)?["look"] as? String == "dark")
        #expect(defaults.persistentDomain(forName: new)?["bench"] as? Bool == true) // the new name wins
        #expect(defaults.persistentDomain(forName: old) == nil) // moved, so a wipe stays wiped
        defaults.removePersistentDomain(forName: new)
        Store.adopt(new, from: old)
        #expect(defaults.persistentDomain(forName: new) == nil) // once only
    }

    @Test @MainActor func aWorkerShimmedUnderTheOldMarkerGetsOneShim() throws {
        guard #available(macOS 15.4, *) else { return }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("copper-only-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        try #"{"manifest_version": 3, "name": "t", "version": "1", "background": {"service_worker": "bg.js"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let before = "/* Search: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */\nold shim\n/* Search: end of shim */\nconsole.log('mine');\n"
        try before.write(to: folder.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)

        try ExtensionShims.prepare(folder)

        let worker = try String(contentsOf: folder.appendingPathComponent("bg.js"), encoding: .utf8)
        #expect(worker.hasPrefix(ExtensionShims.marker))
        #expect(worker.components(separatedBy: ExtensionShims.ender).count == 2)
        #expect(!worker.contains("/* Search:"))
        #expect(!worker.contains("old shim"))
        #expect(worker.hasSuffix("console.log('mine');\n"))
    }
}
