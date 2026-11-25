import Foundation

// Who Copper is, to macOS, and what an update has to prove before it may take
// the running app's place. docs/releasing.md has the whole story.
//
// macOS remembers a person's grants — Full Disk Access, Files & Folders,
// Automation — and a keychain item's "Always Allow" against an app's
// designated requirement. Copper's releases used to be signed ad hoc, which
// makes that requirement the hash of one build: every update looked like a
// different app and quietly lost all of them. Releases are now signed with
// one certificate of Copper's own (release/copper-release-signing.cer) and an
// explicit requirement — this identifier, that certificate — that every
// release satisfies, so the grants stay.
//
// Development builds (./build.sh without COPPER_RELEASE=1) are a different
// app altogether: `Fork.devBundle`, signed ad hoc, a test world of their own
// (Store.swift). Nothing they do lands on the installed Copper's grants,
// settings, cookies or keychain identity.
enum Signing {
    /// SHA-1 of Copper's release certificate (DER), as `codesign` and macOS
    /// name a certificate. The same hash is in release/designated-requirement.txt;
    /// release/package-app.sh refuses to sign an app whose binary does not
    /// carry it, so a release never pins a certificate it isn't signed with.
    nonisolated static let releaseCertificate = "76264b1f74fbc16100eb71c855edd6d4165c4fbe"

    /// Copper's Apple Developer team. Releases move from the certificate above
    /// to a Developer ID of this team, notarized (docs/releasing.md › Moving to
    /// Developer ID).
    nonisolated static let developerTeam = "95X7XYUVNX"

    /// Any Developer ID Application certificate Apple issued to that team —
    /// the requirement Apple's own tools give such an app, so it survives the
    /// certificate's renewal.
    nonisolated static var developerIDRequirement: String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(developerTeam)\""
    }

    /// What the updater accepts from the release feed. The bridge: releases
    /// are still signed with `releaseCertificate` (release/designated-requirement.txt),
    /// and this Copper already accepts the team's Developer ID, so the release
    /// that switches can replace it.
    nonisolated static var releaseRequirement: String {
        "identifier \"\(Fork.bundle)\" and (certificate leaf = H\"\(releaseCertificate)\" or (\(developerIDRequirement)))"
    }

    /// What a downloaded bundle must satisfy before it replaces a running app
    /// with this bundle id. Copper itself: the release requirement — the same
    /// one macOS checks its grants against, so an update that passes keeps
    /// them. A development build or an isolated test copy is ad hoc and has
    /// no certificate to pin; it is held to its own identifier.
    nonisolated static func requirement(forBundleID id: String) -> String {
        id == Fork.bundle ? releaseRequirement : "identifier \"\(id)\""
    }

    /// `codesign --verify -R` against a requirement: nil when the bundle
    /// satisfies it, otherwise codesign's last line, for the log.
    nonisolated static func unsatisfied(_ app: URL, requirement: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // A leading "=" makes the argument requirement text rather than a path.
        process.arguments = ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let last = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return last ?? "codesign exited \(process.terminationStatus)"
    }
}
