import Testing
@testable import Search

// Fork (ardia layout): the interface size's scale (Design.swift `.ui`) and the
// page frame's margins (Fork/SplitPane.swift `PageFrameSize`).

@Suite("Interface size and page frame")
@MainActor
struct ArdiaLayoutTests {
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    @Test func theColumnsMeasuresFollowTheInterfaceSize() {
        let was = Metrics.ui
        defer { Metrics.ui = was }
        Metrics.ui = InterfaceSize.standard.scale
        #expect(SideBar.title == 14 && GroupedRows.row == 34)
        Metrics.ui = InterfaceSize.large.scale
        #expect(near(SideBar.title, 16.1) && near(GroupedRows.row, 39.1) && near(16.ui, 18.4))
        Metrics.ui = InterfaceSize.small.scale
        #expect(near(SideBar.title, 12.25) && near(GroupedRows.row, 29.75))
    }

    @Test func smallNeverShrinksWordsUnderTheTenPointFloor() {
        let was = Metrics.ui
        defer { Metrics.ui = was }
        Metrics.ui = InterfaceSize.small.scale
        #expect(11.ui == 10)   // would be 9.6
        #expect(9.ui == 9)     // already under: kept, never shrunk
        #expect(12.5.ui > 10.9 && 12.5.ui < 11)
        Metrics.ui = InterfaceSize.large.scale
        #expect(near(9.ui, 10.35)) // larger still grows
    }

    @Test func noFrameIsEdgeToEdgeWithSquareCorners() {
        let was = SplitMetrics.frame
        defer { SplitMetrics.frame = was }
        SplitMetrics.frame = .off
        #expect(SplitMetrics.margin == 0 && SplitMetrics.corner == 0)
        SplitMetrics.frame = .standard
        #expect(SplitMetrics.margin == 7 && SplitMetrics.corner == 11) // the look before the setting
        #expect(PageFrameSize.thin.margin < PageFrameSize.standard.margin)
    }
}
