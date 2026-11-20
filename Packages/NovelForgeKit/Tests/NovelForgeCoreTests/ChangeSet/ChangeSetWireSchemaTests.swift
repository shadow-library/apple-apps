import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

struct WireSchemaCase: Decodable {
  let ops: [String]
  let form: Int
  let text: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    ops = try container.decode([String].self)
    form = try container.decode(Int.self)
    text = try container.decode(String.self)
  }
}

struct WireSchemaFixture: Decodable {
  let organise: [String]
  let cases: [WireSchemaCase]

  static func load() throws -> WireSchemaFixture {
    try ReferenceFixture.decode(WireSchemaFixture.self, from: "change-set/wire-schema.json")
  }
}

private func options(_ form: Int) -> OpVocabularyOptions {
  OpVocabularyOptions(quotes: form == 3)
}

struct ChangeSetWireSchemaTests {
  @Test func shouldRenderTheItemSchemaExactlyAsTheReferenceDoes() throws {
    let fixture = try WireSchemaFixture.load()
    #expect(fixture.cases.count >= 150)
    var mismatches: [Int] = []
    for (index, item) in fixture.cases.enumerated() {
      let ops = item.ops.compactMap { OpType(exactly: $0) }
      guard ops.count == item.ops.count else {
        mismatches.append(index)
        continue
      }
      if !ChangeSetItemSchema(ops, options: options(item.form)).text.jsEquals(item.text) { mismatches.append(index) }
    }
    #expect(mismatches.isEmpty, "cases \(mismatches.prefix(5)) of \(mismatches.count) differ")
  }

  @Test func shouldCoverEveryOperationAlone() throws {
    let covered = try WireSchemaFixture.load().cases.filter { $0.ops.count == 1 }.compactMap { OpType(exactly: $0.ops[0]) }
    #expect(Set(covered) == Set(OpType.allCases))
  }

  @Test func shouldKeepFieldsOffTheWireThatTheReferenceKeepsOff() {
    let volume = ChangeSetItemSchema([.volumeUpsert]).text
    #expect(!volume.contains("\"state\""))
    let fact = ChangeSetItemSchema([.factUpsert]).text
    #expect(!fact.contains("\"unlock\""))
    #expect(fact.contains(#""revealChapter":{"type":"integer","minimum":1}"#))
  }

  @Test func shouldKeepServerStampedFieldsAndTheQuoteOffTheWireUnlessQuotesAreOn() {
    let approve = ChangeSetItemSchema([.actionApproveDraft], options: OpVocabularyOptions(quotes: true)).text
    #expect(!approve.contains("\"revision\"") && !approve.contains("\"draftId\"") && !approve.contains("\"quote\""))
    #expect(ChangeSetItemSchema([.briefUpdate]).text.contains("\"quote\"") == false)
    #expect(ChangeSetItemSchema([.briefUpdate], options: OpVocabularyOptions(quotes: true)).text.contains("\"quote\""))
  }

  @Test func shouldRenderAnEmptyScopeAsAnEmptyUnion() {
    #expect(ChangeSetItemSchema([]).text == #"{"anyOf":[]}"#)
  }
}
