import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

private enum BibleDocsFixture {
  static let cases: Result<JSONValue, any Error> = Result { try ReferenceFixture.decode(JSONValue.self, from: "bible-docs/cases.json") }

  static func section(_ key: String) throws -> [JSONValue] {
    try cases.get()[key].orThrow("section \(key)").list()
  }

  static func units(_ value: JSONValue) throws -> [UInt16] {
    try value.ints().map { UInt16(truncatingIfNeeded: $0) }
  }
}

// A Swift String cannot hold a lone surrogate, so a cut through a surrogate pair drops its first half where JavaScript keeps it
private func removingLoneSurrogates(_ units: [UInt16]) -> [UInt16] {
  units.indices.compactMap { index in
    let unit = units[index]
    if UTF16.isLeadSurrogate(unit), index + 1 == units.count || !UTF16.isTrailSurrogate(units[index + 1]) { return nil }
    if UTF16.isTrailSurrogate(unit), index == 0 || !UTF16.isLeadSurrogate(units[index - 1]) { return nil }
    return unit
  }
}

// Fixtures/bible-docs/generate.ts runs apps/novel-forge-server/src/modules/ai/context/bible-docs.ts, modules/eval/bible-readiness.ts and
// platform/apps/novel-forge-web/src/lib/bible-topics.ts on every case
struct BibleDocExcerptParityTests {
  @Test func shouldMatchTheReferenceExcerptOnEveryCase() throws {
    let cases = try BibleDocsFixture.section("excerpts")
    #expect(cases.count >= 400)
    let failed = try mismatches(cases) { row in
      let expected = try BibleDocsFixture.units(row.at(2))
      let actual = Array(bibleDocExcerpt(body: try row.at(0).string(), maxChars: try row.at(1).int()).utf16)
      return actual == removingLoneSurrogates(expected)
    }
    #expect(failed.isEmpty, "excerpts differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferencePlainTextOnEveryCase() throws {
    let cases = try BibleDocsFixture.section("plainText")
    #expect(cases.count >= 150)
    let failed = try mismatches(cases) { row in Array(bibleDocPlainText(try row.at(0).string()).utf16) == (try BibleDocsFixture.units(row.at(1))) }
    #expect(failed.isEmpty, "plain text differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceClipOnEveryCase() throws {
    let cases = try BibleDocsFixture.section("clip")
    #expect(cases.count >= 250)
    let failed = try mismatches(cases) { row in
      Array(clipAtBoundary(try row.at(0).string(), maxChars: try row.at(1).int()).utf16) == removingLoneSurrogates(try BibleDocsFixture.units(row.at(2)))
    }
    #expect(failed.isEmpty, "clips differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldDropALoneSurrogateAtACutWhereTheReferenceKeepsItAsADeliberateDeviation() throws {
    let deviating = try BibleDocsFixture.section("excerpts").filter { row in
      let expected = try BibleDocsFixture.units(row.at(2))
      return removingLoneSurrogates(expected) != expected
    }
    #expect(deviating.count == 1)
    let body = "Averyveryv\u{1F600}rylongwordwithoutspaces"
    #expect(try deviating.first?.at(0).string() == body)
    #expect(Array(bibleDocExcerpt(body: body, maxChars: 11).utf16) == Array("Averyveryv…".utf16))
  }

  @Test func shouldMatchTheReferenceRolesAndTopicsOnEveryCase() throws {
    let cases = try BibleDocsFixture.section("roles")
    #expect(cases.count >= 150)
    let novel = UUID()
    let failed = try mismatches(cases) { row in
      let input = try row["input"].orThrow("input")
      let pages = try input["docs"].orThrow("docs").list().map { doc in
        let body = try doc["body"].orThrow("body").string()
        return PageSummary(
          section: try BiblePageSection(rawValue: try doc["section"].orThrow("section").string()).orThrow("a known section"),
          slug: try doc["slug"].orThrow("slug").string(), title: try doc["title"].orThrow("title").string(), wordCount: 0, isEmpty: body.jsTrim().isEmpty,
          excerpt: nil, writerExcluded: false, plannerOnly: false)
      }
      let entities = try input["entities"].orThrow("entities").list().map { entity in
        let key = try entity["key"].orThrow("key").string()
        return EntityRecord(
          novel: novel, entity: key, type: StoredEnum(rawValue: try entity["type"].orThrow("type").string()), name: key,
          significance: try entity["significance"]?.optionalString().map { StoredEnum(rawValue: $0) })
      }
      let volumes = try input["volumes"].orThrow("volumes").list().enumerated().map { index, volume in
        VolumeRecord(novel: novel, volume: try volume["key"].orThrow("key").string(), ordinal: index + 1, objective: try volume["objective"].orThrow("objective").optionalString())
      }
      let roles = BibleRoles.roles(pages: pages, entities: entities, volumes: volumes)
      let expected = try row["roles"].orThrow("roles").list()
      guard roles.count == expected.count else { return false }
      for (role, want) in zip(roles, expected) {
        let fields = [role.stage.rawValue, role.label, role.address].map { JSString($0) }
        guard fields == (try [want.at(0).string(), want.at(1).string(), want.at(2).string()].map { JSString($0) }) else { return false }
        guard role.coveredBy.map { JSString($0) } == (try want.at(3).strings().map { JSString($0) }) else { return false }
      }
      let stages = BibleRoles.stages(of: roles)
      let topics = try row["topics"].orThrow("topics").list()
      for (page, want) in zip(pages, topics) {
        guard BibleTopics.topic(of: page).rawValue == (try want.at(0).string()) else { return false }
        guard BibleTopics.topic(of: page, stages: stages).rawValue == (try want.at(1).string()) else { return false }
      }
      return pages.count == topics.count
    }
    #expect(failed.isEmpty, "roles or topics differ for cases \(failed.prefix(10)) of \(failed.count)")
  }
}
