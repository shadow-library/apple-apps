import ShadowText
import Testing

@testable import NovelForgeCore

private func ledgerState(_ world: DisclosureWorld) -> OrderedJSON {
  let rows = world.ledger.map { row -> OrderedJSON in
    .array([
      .string(row.factKey), .string(row.entityKey), .int(Int64(row.learnedInChapter)), row.source.map { .string($0.rawValue) } ?? .null, .string(row.status.rawValue),
      row.draftRevision.map { .int(Int64($0)) } ?? .null,
    ])
  }
  return .array([.array(rows), .array(world.facts.map { $0.disclosedInChapter.map { .int(Int64($0)) } ?? .null })])
}

@Suite("Provisional knowledge ledger against the reference")
struct ProvisionalKnowledgeParityTests {
  @Test("should ledger, revoke, re-ledger, commit and disclose as the reference's writes leave the tables")
  func shouldMatchLedger() throws {
    let cases = try DisclosureFixture.cases("ledger.json", "ledgerCases")
    #expect(cases.count > 50)
    for row in cases {
      var world = fixtureWorld(row.at(0))
      for (index, step) in row.at(1).items.enumerated() {
        let op = step.at(0)
        let before = ledgerState(world)
        let label = "step \(index) \(op) of \(row.at(0).at(0).items.map { $0.at(0).stringValue ?? "" })"
        switch op.at(0).stringValue {
        case "ledger":
          let outcome = world.ledgerBriefReveals(chapter: op.at(1).intValue ?? 0, draftRevision: op.at(2).intValue ?? 0)
          #expect(outcome.applied == step.at(1).at(0).intValue, "\(label)")
          #expect(sameTexts(outcome.skipped, step.at(1).at(1).strings ?? []), "\(label)")
        case "revoke":
          world.revokeProvisionalReveals(chapters: op.at(1).items.compactMap(\.intValue))
        case "commit":
          world.commitChapterKnowledge(chapter: op.at(1).intValue ?? 0, draftRevision: op.at(2).intValue ?? 0)
        case "disclose":
          world.discloseChapterReveals(chapter: op.at(1).intValue ?? 0)
        case "retract":
          let pair = LedgerPair(factKey: op.at(1).stringValue ?? "", entityKey: op.at(2).stringValue ?? "")
          world.knowledge.removeAll { $0.pair == pair }
        default:
          let draft = try #require(fixtureDraft(.array(Array(op.items.dropFirst()))))
          world.drafts = world.drafts.filter { $0.chapter != draft.chapter } + [draft]
        }
        #expect(ledgerState(world) == (step.at(2) == .null ? before : step.at(2)), "\(label)")
      }
    }
  }
}
