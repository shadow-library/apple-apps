import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

/// Fixtures/canon-refresh/generate.ts runs the reference's renderRefreshMaterial (bible-audit-material.ts:273-337), buildCanonRefreshReport and
/// renderReportSummary (bible-audit-report.ts:245-276) over generated rows and replies, with the inputs chapter-canon-refresh.service.ts:96-107 gives them.
@Suite("Canon refresh parity", TestTimeLimit.standard)
struct CanonRefreshParityTests {
  private static func cases(_ file: String) throws -> [OrderedJSON] {
    let json = try OrderedJSON(parsing: String(decoding: try ReferenceFixture.data("canon-refresh/\(file)"), as: UTF8.self))
    return json.objectValue?["cases"]?.arrayValue ?? []
  }

  static func rows(_ json: OrderedJSON) throws -> RefreshRows {
    let fields = try #require(json.objectValue)
    let string = { (value: OrderedJSON?) in value?.stringValue }
    let int = { (value: OrderedJSON?) in value?.numberValue.map { Int($0) } }
    let strings = { (value: OrderedJSON?) in value?.arrayValue?.compactMap(\.stringValue) }
    let documents = (fields["documents"]?.arrayValue ?? []).compactMap(\.objectValue).map { doc in
      RefreshDocumentRow(section: string(doc["section"]) ?? "", slug: string(doc["slug"]) ?? "", body: string(doc["body"]))
    }
    let entities = (fields["entities"]?.arrayValue ?? []).compactMap(\.objectValue).map { entity in
      RefreshEntityRow(
        entityKey: string(entity["entityKey"]) ?? "", type: string(entity["type"]) ?? "", name: string(entity["name"]) ?? "", status: string(entity["status"]),
        motivation: string(entity["motivation"]), notes: string(entity["notes"]), body: string(entity["body"]))
    }
    let facts = (fields["facts"]?.arrayValue ?? []).compactMap(\.objectValue).map { fact in
      RefreshFactRow(
        factKey: string(fact["factKey"]) ?? "", text: string(fact["text"]) ?? "", writerNote: string(fact["writerNote"]), terms: strings(fact["terms"]),
        allowedClues: strings(fact["allowedClues"]), revealChapter: int(fact["revealChapter"]), disclosedInChapter: int(fact["disclosedInChapter"]),
        source: string(fact["source"]).flatMap(FactSource.init(rawValue:)))
    }
    let chapter = try #require(fields["chapter"]?.objectValue)
    let number = try #require(int(chapter["number"]))
    let items = (fields["reviewItems"]?.arrayValue ?? []).compactMap(\.objectValue).compactMap { item -> RefreshReviewItem? in
      guard let claim = string(item["claim"]), let decision = string(item["decision"]).flatMap(FinalizeDecision.init(rawValue:)) else { return nil }
      return RefreshReviewItem(claim: claim, decision: decision)
    }
    return RefreshRows(
      documents: documents, entities: entities, facts: facts,
      chapter: RefreshChapterRow(
        number: number, title: string(chapter["title"]), summary: string(chapter["summary"]), content: string(chapter["content"]) ?? ""),
      reviewItems: items)
  }

  @Test func shouldRenderTheMaterialAsTheReferenceDoes() throws {
    let cases = try Self.cases("material.json")
    #expect(cases.count == 61)
    for (index, fixture) in cases.enumerated() {
      let fields = try #require(fixture.objectValue)
      let input = try #require(fields["rows"])
      let material = RefreshMaterialRender.render(try Self.rows(input))
      let expected = try #require(fields["material"]?.objectValue)
      let checked = try #require(expected["checked"])
      #expect(material.bible.jsEquals(expected["bible"]?.stringValue ?? ""), "case \(index) bible")
      #expect(material.chapter.jsEquals(expected["chapter"]?.stringValue ?? ""), "case \(index) chapter")
      let sources = (expected["sources"]?.arrayValue ?? []).compactMap { pair -> (JSString, String)? in
        guard let label = pair.arrayValue?.first?.stringValue, let text = pair.arrayValue?.last?.stringValue else { return nil }
        return (JSString(label), text)
      }
      #expect(material.sources.count == sources.count, "case \(index) sources")
      for (label, text) in sources { #expect(material.sources[label]?.jsEquals(text) == true, "case \(index) source \(label)") }
      #expect(material.partial.map(\.value).jsSorted() == (expected["partial"]?.arrayValue ?? []).compactMap(\.stringValue), "case \(index) partial")
      #expect(JSONValue.object(material.checked.json) == JSONValue(schema: checked), "case \(index) checked")
    }
  }

  @Test func shouldBuildTheReportAndItsSummaryAsTheReferenceDoes() throws {
    let rule = try #require(QuoteRule.shared)
    let cases = try Self.cases("report.json")
    #expect(cases.count == 240)
    var staged = 0
    for (index, fixture) in cases.enumerated() {
      let fields = try #require(fixture.objectValue)
      let (input, refresh) = (try #require(fields["rows"]), try #require(fields["refresh"]))
      let (findings, expectedOps) = (try #require(fields["findings"]), try #require(fields["changeSet"]))
      let rows = try Self.rows(input)
      let material = RefreshMaterialRender.render(rows)
      let updates = try #require(RefreshUpdate.updates(in: refresh))
      let built = try RefreshCall.build(updates, chapterRef: "chapter:\(rows.chapter.number)", material: material, rows: rows, rule: rule)
      #expect(.array(built.findings.map { .object($0.json) }) == JSONValue(schema: findings), "case \(index) findings")
      let changeSet = built.changeSet.map { JSONValue(schema: .object($0.fields)) }
      #expect(.array(changeSet) == JSONValue(schema: expectedOps), "case \(index) change set")
      let summary = built.findings.isEmpty ? nil : "Chapter \(rows.chapter.number): \(renderRefreshSummary(built.findings, checkedCopy: material.checked.copy))"
      #expect(summary == fields["summary"]?.stringValue, "case \(index) summary")
      staged += built.changeSet.isEmpty ? 0 : 1
    }
    #expect(staged > 40)
  }
}
