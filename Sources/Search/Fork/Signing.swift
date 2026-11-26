import Foundation

// Who Copper is, to macOS, and what an update has to prove before it may take
// the running app's place. docs/releasing.md has the whole story.
//
// macOS remembers a person's grants — Full Disk Access, Files & Folders,
// Automation — and a keychain item's "Always Allow" against an app's
// designated requirement. Copper's releases used to be signed ad hoc, which
// makes that requirement the hash of one build: every update looked like a
// different app and quietly lost all of them. Releases are signed with a
// Developer ID of Exowatt's Apple Developer team, 62D5L6T44Y
// (release/exowatt-developer-id.cer), notarized, with an explicit requirement —
// this identifier, a Developer ID of Copper's teams — that every release
// satisfies, so the grants stay and Gatekeeper opens a download.
//
// Two teams, one requirement: releases up to 1.0.20261126.124 were signed by
// Collin's team, 95X7XYUVNX (release/copper-developer-id.cer); from the next
// one on, by Exowatt's. The requirement names both, so a Copper from either
// side accepts an update from the other and macOS keeps grants made to either.
// A Copper that names only 95X7XYUVNX (1.0.20261126.124) refuses the first
// Exowatt release; it is reinstalled once (docs/releasing.md › The move to
// Exowatt's team).
//
// Development builds (./build.sh without COPPER_RELEASE=1) are a different
// app altogether: `Fork.devBundle`, signed ad hoc, a test world of their own
// (Store.swift). Nothing they do lands on the installed Copper's grants,
// settings, cookies or keychain identity.
enum Signing {
    /// The Apple Developer team that signs Copper's releases: Exowatt Inc.
    nonisolated static let team = "62D5L6T44Y"
    /// The team that signed them before (Collin Rijock), still accepted so
    /// Coppers on either side of the move update to each other.
    nonisolated static let previousTeam = "95X7XYUVNX"

    /// Any Developer ID Application certificate Apple issued to one of
    /// Copper's Apple Developer teams — the requirement Apple's own tools
    /// give such an app, with the team clause widened to both, so it
    /// survives a certificate's renewal and the move between teams. One
    /// literal, so each team is in the binary as text: release/package-app.sh
    /// refuses to sign an app whose binary does not carry the signing team (a
    /// short Swift string is stored inline, out of grep's reach).
    nonisolated static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and (certificate leaf[subject.OU] = \"62D5L6T44Y\" or certificate leaf[subject.OU] = \"95X7XYUVNX\")"

    /// The designated requirement every Copper release is signed with; the
    /// same text is in release/designated-requirement.txt.
    nonisolated static var releaseRequirement: String {
        "identifier \"\(Fork.bundle)\" and \(developerIDRequirement)"
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
