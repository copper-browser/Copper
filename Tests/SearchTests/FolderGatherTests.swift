import Testing
@testable import Search

// A folder split by other rows drew one header per run (Fork/Folders.swift);
// `Folders.gathered` puts its tabs back side by side, nesting kept.
@Suite struct FolderGatherTests {
    // (title, folder)
    let row: [(String, String?)] = [
        ("loose1", nil), ("a1", "Life › Admin"), ("d1", "Life › Daily"), ("x", nil),
        ("a2", "Life › Admin"), ("p1", "Projects"), ("life", "Life"), ("a3", "Life › Admin"),
        ("bf", "Projects › Past › BuildrFi"), ("p2", "Projects"), ("d2", "Life › Daily"),
    ]
    func titles(_ r: [(String, String?)]) -> [String] { r.map(\.0) }

    @Test func gathersEveryFolderOnce() {
        let out = Folders.gathered(row) { $0.1 }
        #expect(titles(out) == ["loose1", "a1", "a2", "a3", "d1", "d2", "life", "x", "p1", "bf", "p2"])
        // Each folder (and each ancestor) is one contiguous run.
        for folder in ["Life › Admin", "Life › Daily", "Projects"] {
            let idx = out.indices.filter { out[$0].1 == folder || (out[$0].1?.hasPrefix(folder + " › ") ?? false) }
            #expect(idx == Array(idx.first!...idx.last!), "\(folder) split")
        }
    }

    @Test func idempotent() {
        let once = Folders.gathered(row) { $0.1 }
        #expect(titles(Folders.gathered(once) { $0.1 }) == titles(once))
    }

    @Test func untouchedWhenAlreadyWhole() {
        let whole: [(String, String?)] = [("a", nil), ("b", "F"), ("c", "F"), ("d", nil)]
        #expect(titles(Folders.gathered(whole) { $0.1 }) == ["a", "b", "c", "d"])
    }
}
