import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private struct StalenessFixture: Decodable {
  struct Terms: Decodable {
    let pov: [String]
    let learns: [[String]]
    let claims: [String]?

    var contract: ChapterContract {
      NovelForgeCoreTests.contract(pov: pov, learns: learns.map { Learn($0[0], $0[1]) }, claims: claims ?? [])
    }
  }

  struct TermCase: Decodable {
    let before: Terms?
    let after: Terms
    let reset: Bool
    let marked: Bool
  }

  struct Term: Decodable {
    let chapter: Int
  }

  struct Fact: Decodable {
    let fact: String
    let revealChapter: Int?
    let unlock: [Term]?
    let source: String
  }

  struct Plan: Decodable {
    let chapter: Int
    let pov: [String]
    let learns: [[String]]
  }

  enum Cell: Decodable, Equatable {
    case text(String)
    case number(Int)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Int.self) {
        self = .number(number)
      } else {
        self = .text(try container.decode(String.self))
      }
    }

    var text: String? {
      guard case .text(let text) = self else { return nil }
      return text
    }

    var number: Int? {
      guard case .number(let number) = self else { return nil }
      return number
    }
  }

  struct LedgerCase: Decodable {
    let facts: [Fact]
    let entities: [String]
    let plans: [Plan]
    let finals: [Int]
    let approved: [Int]
    let manual: [[Cell]]
    let retracted: [[String]]
    let expected: [[Cell]]
  }

  let termCases: [TermCase]
  let ledgerCases: [LedgerCase]
}

private func fixture() throws -> StalenessFixture {
  try ReferenceFixture.decode(StalenessFixture.self, from: "chapters/staleness.json")
}

private func write(_ fixture: StalenessFixture.LedgerCase, novel: UUID, in transaction: inout WriteTransaction) throws {
  for fact in fixture.facts {
    guard let source = FactSource(rawValue: fact.source) else { throw ProjectionPropertyFailure.oracle("unknown source \(fact.source)") }
    let unlock = fact.unlock.map { terms in JSONValue.object(["all": .array(terms.map { PlanWorldTerm.chapter($0.chapter).json })]) }
    let record = SecretRecord(novel: novel, secret: fact.fact, text: fact.fact, revealChapter: fact.revealChapter, unlock: unlock, source: .known(source))
    _ = try record.create(in: &transaction)
  }
  for entity in fixture.entities { try ChapterWrites.entity(novel: novel, entity, in: &transaction) }
  for plan in fixture.plans {
    let planned = contract(pov: plan.pov, learns: plan.learns.map { Learn($0[0], $0[1]) })
    try PlanWorldWrites.putPlan(novel: novel, chapter: plan.chapter, planContent(planned), in: &transaction)
  }
  for plan in fixture.plans { try ChapterWrites.draft(novel: novel, chapter: plan.chapter, in: &transaction) }
  for chapter in (fixture.finals + fixture.approved).sorted() { try ChapterWrites.approve(novel: novel, chapter: chapter, in: &transaction) }
  for chapter in fixture.finals.sorted() { try ChapterWrites.finalize(novel: novel, chapter: chapter, in: &transaction) }
  for row in fixture.manual {
    guard let fact = row[0].text, let entity = row[1].text, let chapter = row[2].number else { throw ProjectionPropertyFailure.oracle("a manual row \(row)") }
    try ChapterWrites.reveal(novel: novel, fact: fact, entity: entity, chapter: chapter, in: &transaction)
  }
  for pair in fixture.retracted { try ChapterWrites.retract(novel: novel, fact: pair[0], entity: pair[1], in: &transaction) }
}

@Suite("Chapter lifecycle parity with the reference", TestTimeLimit.standard)
struct ChapterParityTests {
  @Test func shouldResetAndMarkExactlyAsResetApprovalForPlanChangeDoes() throws {
    let cases = try fixture().termCases
    #expect(cases.count == 400)
    #expect(cases.contains(where: \.reset) && cases.contains(where: \.marked) && cases.contains { $0.reset && !$0.marked } && cases.contains { !$0.reset })
    for (index, item) in cases.enumerated() {
      let before = item.before?.contract
      #expect((ChapterFingerprint.planTerms(before) != ChapterFingerprint.planTerms(item.after.contract)) == item.reset, "case \(index)")
      #expect((ChapterFingerprint.learns(before ?? ChapterContract()) != ChapterFingerprint.learns(item.after.contract)) == item.marked, "case \(index)")
    }
  }

  @Test(arguments: 0..<4)
  func shouldLeaveTheLedgerTheReferenceLeavesAfterAnyOrderOfApprovalsRevisionsAndFinalizes(shard: Int) async throws {
    let cases = try fixture().ledgerCases.enumerated().filter { $0.offset % 4 == shard }
    let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
    let novels = cases.map { _ in UUID() }
    for ((_, item), novel) in zip(cases, novels) { _ = try await Projection.write(store) { transaction in try write(item, novel: novel, in: &transaction) } }
    for ((index, item), novel) in zip(cases, novels) {
      let expected = Set(
        try item.expected.map { row in
          guard let fact = row[0].text, let entity = row[1].text, let chapter = row[2].number, let source = row[3].text.flatMap(FactSource.init(rawValue:)),
            let status = row[4].text.flatMap(KnowledgeStatus.init(rawValue:))
          else { throw ProjectionPropertyFailure.oracle("an expected row \(row)") }
          return LedgerView(fact, entity, chapter, source, status)
        })
      #expect(try await ChapterTables.knowledge(novel, in: store) == expected, "case \(index)")
    }
  }
}
