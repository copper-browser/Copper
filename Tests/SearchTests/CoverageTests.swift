import Foundation
import Testing
@testable import Search

// The coverage loop's counting (Coverage.swift): what a question asks for,
// what a reply covers, the helpers' batches and the merged answer.

@Test func coverageCountsRowsFieldsAndLoadedSources() throws {
    let question = "Find these 3 things: Alpha; Beta (b); Gamma.\n\nEnd with one JSON code block (3 entries; \"not shown\" if missing):\n"
        + "```json\n{\"rows\": [{\"name\": \"X\", \"value\": \"1\", \"source\": \"https://... (page)\"}]}\n```"
    let spec = try #require(Coverage.spec(question))
    #expect(spec == Coverage.Spec(list: "rows", fields: ["name", "value", "source"], key: "name", url: "source", n: 3, names: ["Alpha", "Beta (b)", "Gamma"]))

    let reply = "Here.\n```json\n{\"rows\": [{\"name\": \"Alpha\", \"value\": \"7\", \"source\": \"https://a.example/x\"}, "
        + "{\"name\": \"Beta\", \"value\": \"not shown\", \"source\": \"https://b.example/\"}, {\"name\": \"Delta\", \"value\": \"1\", \"source\": \"https://d.example/\"}]}\n```\nbye"
    var loaded: Set<String> = [Coverage.canon("https://www.a.example/x/"), Coverage.canon("https://b.example")]
    var table = Coverage.table(Coverage.rows(reply, spec), spec)
    #expect(table.order == ["Alpha", "Beta (b)"])  // Delta was not asked for
    let count = Coverage.count(table, spec, loaded: loaded)
    #expect(count.missing == ["Beta (b)", "Gamma"] && count.asked == 9 && count.done == 3 + 2)

    let prompt = Coverage.batchPrompt("TASK", spec, items: count.missing, table: table)
    #expect(prompt.contains("ONLY these 2 entries: Beta (b); Gamma.") && prompt.contains("\"value\": \"not shown\"") && prompt.contains("{\"rows\": [...]}"))

    // A helper's rows: better ones replace, a row outside its batch or from an unloaded page does not.
    let found: [Coverage.Row] = [["name": "Gamma", "value": "3", "source": "https://g.example/"], ["name": "Beta", "value": "2", "source": "https://b.example/"],
                                 ["name": "Alpha", "value": "0", "source": "https://never.example/"]]
    loaded.insert(Coverage.canon("https://g.example/"))
    #expect(Coverage.absorb(&table, found, spec, loaded: loaded, items: Set(count.missing)) == 2)
    #expect(table.rows["Alpha"]?["value"] as? String == "7")
    let after = Coverage.count(table, spec, loaded: loaded)
    #expect(after.ratio == 1 && after.missing.isEmpty)

    // The answer keeps its words around the block; the rows come in asked order.
    let merged = Coverage.render(reply, spec, table)
    #expect(merged.hasPrefix("Here.\n```json") && merged.hasSuffix("```\nbye"))
    #expect(Coverage.rows(merged, spec).compactMap { $0["name"] as? String } == ["Alpha", "Beta", "Gamma"])
}

@Test func coverageWithoutSourcesNamesOrRows() throws {
    // A comma list and no source field: filled is enough.
    let packages = try #require(Coverage.spec("Check 2 packages: foo, bar.\n```json\n{\"packages\": [{\"name\": \"foo\", \"version\": \"1.2\"}]}\n```\n(2 entries)"))
    #expect(packages.names == ["foo", "bar"] && packages.url == nil)

    // Names unknown: N asked, rows short, and a helper may bring new rows.
    let repos = try #require(Coverage.spec("The 5 biggest. One JSON code block (5 entries):\n```json\n{\"repos\": [{\"repo\": \"o/n\", \"stars\": 1}]}\n```"))
    var table = Coverage.table([["repo": "a/b", "stars": 3], ["repo": "c/d", "stars": "not shown"]], repos)
    let count = Coverage.count(table, repos, loaded: [])
    #expect(repos.names == nil && count.short == 3 && count.missing == ["cd"] && count.asked == 10)
    #expect(Coverage.batchPrompt("T", repos, items: count.missing, table: table, short: 3).contains("Also find up to 3 more entries"))
    #expect(Coverage.batchPrompt("T", repos, items: count.missing, table: table).contains("c/d"))
    #expect(Coverage.batchPrompt("T", repos, items: [], table: table, short: 3).contains("other workers do the other entries. Find up to 3 more entries"))
    #expect(Coverage.absorb(&table, [["repo": "e/f", "stars": 9]], repos, loaded: [], items: ["cd"]) == 1 && table.rows["ef"] != nil)

    // Prose questions are left alone.
    #expect(Coverage.spec("Tell me about X in prose.") == nil)

    // Fitted to the draft: a value shared by rows is no key; names that are fields, not rows, go.
    let year = try #require(Coverage.spec("For each of the 2 give: its a, its b.\n```json\n{\"r\": [{\"year\": 1, \"name\": \"N\", \"b\": 2}]}\n```\n(2 entries)"))
    let fitted = Coverage.fit(year, draft: [["year": 1, "name": "P", "b": 1], ["year": 1, "name": "Q", "b": 1]])
    #expect(fitted.key == "name" && fitted.names == nil)

    #expect(!Coverage.filled("Not shown") && Coverage.filled(["a": "not shown", "b": 1]) && !Coverage.filled([Any]()) && !Coverage.filled(NSNull()))
}

@Test func coverageReadsThePagesToolsLoaded() {
    let read = "browser_read: 2 pages read in 1.2 s (1 ok, 1 error); tabs closed.\n```\n[1] ok · https://a.example/x → https://a.example/y · A page\ntext\n[2] error · https://b.example — 404\n```"
    #expect(Coverage.pages(in: read) == ["https://a.example/x", "https://a.example/y"])
    #expect(Coverage.pages(in: "### Page\n- URL: https://c.example/\n- Title: C") == ["https://c.example/"])
    #expect(Coverage.pages(args: ["urls": ["https://d.example", "not a url"]]) == ["https://d.example"])
    #expect(Coverage.pages(args: ["url": "https://e.example"]) == ["https://e.example"])
    #expect(Coverage.canon("HTTPS://www.Site.example/Path/#top") == "site.example/Path")
}
