import Testing
@testable import Search

// How a `tab` argument string is read (AgentTabs.reading, Fork/MCP/Backstage.swift):
// a place in the window's row, or a tab id. About one short id in fifty is
// all digits; those must stay ids.

private let ids = [
    "12345678-aaaa-4bbb-8ccc-000000000001",
    "00000012-aaaa-4bbb-8ccc-000000000002",
    "4071b2c9-aaaa-4bbb-8ccc-000000000003",
    "abcdef01-aaaa-4bbb-8ccc-000000000004",
    "abcdef02-aaaa-4bbb-8ccc-000000000005",
    "98765aa1-aaaa-4bbb-8ccc-000000000006",
]

@Test func aSmallNumberIsAPlaceInTheRow() {
    #expect(AgentTabs.reading("3", row: 6, ids: ids) == .index(3))
    #expect(AgentTabs.reading("0", row: 6, ids: ids) == .index(0))
    // Within the row the place wins, even when an id begins with the digit.
    #expect(AgentTabs.reading("4", row: 6, ids: ids) == .index(4))
    // Past the end of the row and no id begins with it: still an index, so the
    // error says there is no tab 50.
    #expect(AgentTabs.reading("50", row: 6, ids: ids) == .index(50))
}

@Test func anAllDigitShortIdIsAnId() {
    #expect(AgentTabs.reading("12345678", row: 6, ids: ids) == .id(0))
    // One that names no tab is no tab, never index twelve million.
    #expect(AgentTabs.reading("87654321", row: 6, ids: ids) == .nothing)
}

@Test func aLeadingZeroMakesItAnIdNotAnIndex() {
    // A row of twenty has a tab 12; 00000012 is still the tab whose id it is.
    #expect(AgentTabs.reading("00000012", row: 20, ids: ids) == .id(1))
    #expect(AgentTabs.reading("0000", row: 20, ids: ids) == .id(1))
    #expect(AgentTabs.reading("012", row: 20, ids: ids) == .nothing)
}

@Test func aShortNumberPastTheRowThatBeginsOneIdIsThatId() {
    #expect(AgentTabs.reading("98765", row: 6, ids: ids) == .id(5))
    #expect(AgentTabs.reading("12", row: 6, ids: ids) == .id(0))
    // Begins two ids: no one tab, so it stays an index (and gets its error).
    let more = ids + ["98765bb2-aaaa-4bbb-8ccc-000000000007"]
    #expect(AgentTabs.reading("98765", row: 6, ids: more) == .index(98765))
}

@Test func anythingElseIsAnIdPrefixAsBefore() {
    #expect(AgentTabs.reading("4071b2c9", row: 6, ids: ids) == .id(2))
    #expect(AgentTabs.reading("abcdef01", row: 6, ids: ids) == .id(3))
    #expect(AgentTabs.reading("12345678-aaaa-4bbb-8ccc-000000000001", row: 6, ids: ids) == .id(0))
    #expect(AgentTabs.reading("ffff", row: 6, ids: ids) == .nothing)
    // Not ASCII digits: not a number.
    #expect(AgentTabs.reading("٣", row: 6, ids: ids) == .nothing)
}

@Test func aPrefixOfSeveralIdsIsStillAmbiguous() {
    #expect(AgentTabs.reading("abcdef", row: 6, ids: ids) == .several)
    #expect(AgentTabs.reading("abc", row: 6, ids: ids) == .several)
}
