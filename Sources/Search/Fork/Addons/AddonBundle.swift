import CryptoKit
import Foundation

// A served addon bundle (contract §3): one JSON document,
// `{"format":"copper-addon-bundle/1","manifest":{…},"files":[{path,size,sha256,data}]}`,
// so Copper needs no zip code; its SHA-256 is the version's identity.
//
// `AddonBundle.verify` checks, in the contract's order: the size, the
// SHA-256 of the exact bytes, the format, the manifest (valid, and the same
// id/version/slot the cloud listed), then every file's path and its own
// SHA-256. Anything wrong and the bundle is dropped — the install that was
// working stays. `write(to:)` unpacks into a folder that appears whole or
// not at all.

enum AddonDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct AddonBundle {
    struct File: Equatable {
        var path: String
        var sha256: String
        var data: Data
    }

    static let maxFiles = 1000
    static let maxDecodedBytes = 10 * 1024 * 1024
    static let maxServedBytes = 14 * 1024 * 1024

    /// The served bytes' SHA-256.
    var sha256: String
    var manifest: AddonManifest
    /// Sorted by path.
    var files: [File]

    func file(_ path: String) -> File? { files.first { $0.path == path } }

    /// Verify served bytes against what the cloud listed for them.
    static func verify(_ bytes: Data, sha256 expected: String, id: String, version: String, slot: String) throws -> AddonBundle {
        try checkSize(bytes)
        let actual = Addons.sha256(bytes)
        guard actual == expected.trimmingCharacters(in: .whitespaces).lowercased() else {
            throw AddonProblem(code: "sha256", message: "the bundle's SHA-256 is \(actual), expected \(expected)")
        }
        let bundle = try parseChecked(bytes, sha256: actual)
        for (field, want, got) in [("id", id, bundle.manifest.id), ("version", version, bundle.manifest.version), ("slot", slot, bundle.manifest.slot)]
        where want != got {
            throw AddonProblem(code: "mismatch", message: "the bundle's \(field) is \"\(got)\", expected \"\(want)\"")
        }
        return bundle
    }

    /// Parse and check served bytes with nothing to compare them with (a
    /// bundle file opened from disk by the bench); the SHA-256 is computed.
    static func parse(_ bytes: Data) throws -> AddonBundle {
        try checkSize(bytes)
        return try parseChecked(bytes, sha256: Addons.sha256(bytes))
    }

    private static func checkSize(_ bytes: Data) throws {
        if bytes.count > maxServedBytes {
            throw AddonProblem(code: "too_large", message: "the bundle is \(bytes.count) bytes; the limit is \(maxServedBytes)")
        }
    }

    private static func parseChecked(_ bytes: Data, sha256: String) throws -> AddonBundle {
        guard let doc = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw AddonProblem(code: "json", message: "the bundle is not a JSON object")
        }
        guard doc["format"] as? String == Addons.bundleFormat else {
            throw AddonProblem(code: "format", message: "unknown bundle format \"\(doc["format"] as? String ?? "")\"")
        }
        guard let object = doc["manifest"] as? [String: Any] else {
            throw AddonProblem(code: "manifest", message: "the bundle has no manifest")
        }
        let manifest = AddonManifest(object)
        if let problem = manifest.problems().first {
            throw AddonProblem(code: "manifest", message: "manifest \(problem.code): \(problem.message)")
        }
        guard let entries = doc["files"] as? [Any] else { throw AddonProblem(code: "json", message: "the bundle has no files array") }
        if entries.count > maxFiles {
            throw AddonProblem(code: "too_many_files", message: "the bundle has \(entries.count) files; the limit is \(maxFiles)")
        }
        var files: [File] = []
        var seen = Set<String>()
        var total = 0
        for case let entry as [String: Any] in entries {
            guard let path = entry["path"] as? String else { throw AddonProblem(code: "json", message: "a file has no path") }
            guard Addons.validPath(path) else { throw AddonProblem(code: "path", message: "bad file path \"\(path)\"") }
            // The Mac's file system folds case: two names that differ only in
            // case would be one file on disk.
            guard seen.insert(path.lowercased()).inserted else { throw AddonProblem(code: "file", message: "\(path): listed twice") }
            guard let text = entry["data"] as? String, let data = Data(base64Encoded: text) else {
                throw AddonProblem(code: "file", message: "\(path): data is not base64")
            }
            if let size = entry["size"], AddonManifest.wholeNumber(size) != data.count {
                throw AddonProblem(code: "file", message: "\(path): size doesn't match the data")
            }
            total += data.count
            if total > maxDecodedBytes {
                throw AddonProblem(code: "too_large", message: "the bundle's files come to more than \(maxDecodedBytes) bytes")
            }
            guard let want = entry["sha256"] as? String else { throw AddonProblem(code: "file", message: "\(path): no sha256") }
            let got = Addons.sha256(data)
            guard got == want.lowercased() else { throw AddonProblem(code: "file", message: "\(path): sha256 doesn't match the data") }
            files.append(File(path: path, sha256: got, data: data))
        }
        if files.count != entries.count { throw AddonProblem(code: "json", message: "a file entry is not an object") }
        // A file may not also be a folder of another (`a` and `a/b`).
        for file in files {
            let prefix = file.path.lowercased() + "/"
            if seen.contains(where: { $0.hasPrefix(prefix) }) {
                throw AddonProblem(code: "file", message: "\(file.path): is both a file and a folder")
            }
        }
        files.sort { $0.path < $1.path }
        guard files.contains(where: { $0.path == manifest.entry }) else {
            throw AddonProblem(code: "entry", message: "the entry \"\(manifest.entry)\" is not in the bundle")
        }
        return AddonBundle(sha256: sha256, manifest: manifest, files: files)
    }

    /// Unpack into `folder`, which appears whole or not at all: the files go
    /// into a hidden sibling first, which is then renamed into place. A
    /// folder already there is the same bundle (folders are named by the
    /// bundle's SHA-256 and never change), and is kept.
    func write(to folder: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: folder.appendingPathComponent(manifest.entry).path) { return }
        let parent = folder.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: temporary, withIntermediateDirectories: true)
            for file in self.files {
                let target = temporary.appendingPathComponent(file.path)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: target)
            }
            if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
            try files.moveItem(at: temporary, to: folder)
        } catch {
            try? files.removeItem(at: temporary)
            throw AddonProblem(code: "io", message: "couldn't unpack into \(folder.path): \(error.localizedDescription)")
        }
    }
}
