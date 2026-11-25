import Foundation
import Security
import Testing
@testable import Search

// Release signing (Fork/Signing.swift, docs/releasing.md): the team the
// updater pins is the one in release/'s Developer ID certificate, the
// requirement text is the one the release workflow signs with, and
// `unsatisfied` tells a bundle that meets a requirement from one that doesn't.
// Ad-hoc bundles only — nothing here touches a keychain.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct SigningTests {
    @Test func theUpdaterPinsTheTeamInRelease() throws {
        let cer = try Data(contentsOf: repo.appendingPathComponent("release/copper-developer-id.cer"))
        let certificate = try #require(SecCertificateCreateWithData(nil, cer as CFData))
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        #expect(subject == "Developer ID Application: Collin Rijock (\(Signing.developerTeam))")
        let text = try String(contentsOf: repo.appendingPathComponent("release/designated-requirement.txt"), encoding: .utf8)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == Signing.releaseRequirement)
        #expect(Signing.releaseRequirement == "identifier \"com.collinrijock.copper\" and \(Signing.developerIDRequirement)")
        #expect(Signing.developerIDRequirement.hasSuffix("certificate leaf[subject.OU] = \"95X7XYUVNX\""))
    }

    @Test func theRequirementCompiles() throws {
        // codesign -R refuses a requirement it can't parse the same way it
        // refuses a bundle that fails it; csreq tells the two apart.
        let csreq = Process()
        csreq.executableURL = URL(fileURLWithPath: "/usr/bin/csreq")
        csreq.arguments = ["-r=" + Signing.releaseRequirement, "-t"]
        let pipe = Pipe()
        csreq.standardOutput = pipe
        csreq.standardError = FileHandle.nullDevice
        try csreq.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        csreq.waitUntilExit()
        #expect(csreq.terminationStatus == 0)
        #expect(out.contains("anchor apple generic") && out.contains("95X7XYUVNX"))
    }

    @Test func eachIdentityIsHeldToItsOwnRequirement() {
        #expect(Signing.requirement(forBundleID: Fork.bundle) == Signing.releaseRequirement)
        #expect(Signing.requirement(forBundleID: Fork.devBundle) == "identifier \"com.collinrijock.copper.dev\"")
        #expect(Fork.devBundle != Fork.bundle && Fork.devBundle.hasPrefix(Fork.bundle + "."))
    }

    @Test func anAdHocBundleMeetsOnlyItsOwnIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copper-signing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Probe.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Probe"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.collinrijock.copper.dev", "CFBundleExecutable": "Probe",
                                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)

        #expect(Signing.unsatisfied(app, requirement: Signing.requirement(forBundleID: Fork.devBundle)) == nil)
        #expect(Signing.unsatisfied(app, requirement: Signing.releaseRequirement) != nil)
        #expect(Signing.unsatisfied(app, requirement: "identifier \"com.collinrijock.copper\"") != nil)
        // A certificate requirement an ad-hoc signature can never meet.
        #expect(Signing.unsatisfied(app, requirement: "identifier \"com.collinrijock.copper.dev\" and \(Signing.developerIDRequirement)") != nil)
    }
}
