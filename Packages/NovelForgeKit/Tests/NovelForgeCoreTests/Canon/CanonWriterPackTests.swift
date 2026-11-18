import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private let secretText = "The ledger is forged."

/// Chapter 2 teaches `heir`, which unlocks on milestone `rise`, the milestone chapter 1's plan claimed.
private func gated(_ finalize: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws -> WriterPack {
  let store = try Projection.store(try Projection.reconciler())
  _ = try await Projection.write(store) { transaction in
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    try CanonWrites.entity(novel: novel, "mara", in: &transaction)
    try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
    try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 2, unlock: unlock(.milestone("rise")), in: &transaction)
    try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(pov: ["mara"], learns: [Learn("mara", "heir")])), in: &transaction)
    try finalize(&transaction)
  }
  let load = try await store.read { transaction in try WriterPackLoader.load(novel: novel, chapter: 2, in: transaction) }
  #expect(load.unreadable.isEmpty)
  return try WriterPackAssembler.assemble(load.world, chapter: 2).pack
}

private func carries(_ pack: WriterPack, _ text: String) -> Bool {
  pack.rendered.contains(text) || pack.sections.contains { $0.rendered.contains(text) }
}

@Suite("Canon in the writer pack", .timeLimit(.minutes(2)))
struct CanonWriterPackTests {
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:538 reads the character_states and entity_relationships the kept items wrote
  @Test func shouldHandTheWriterTheStatesAndRelationshipsTheWinningCanonKept() async throws {
    let store = try Projection.store(try Projection.reconciler())
    _ = try await Projection.write(store) { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      for key in ["mira", "oren"] { try CanonWrites.entity(novel: novel, key, in: &transaction) }
      try PlanWorldWrites.putPlan(novel: novel, chapter: 2, ChapterPlanContent(body: "The plan.", pov: "mira"), in: &transaction)
      let kept = [
        Kept.state("mira", location: "the pier", conditions: ["tired"]), Kept.relationship("mira", "oren", "ally", note: "wary"), Kept.state("ghost", location: "nowhere"),
      ]
      try CanonWrites.finalize(novel: novel, chapter: 1, review: review(kept), in: &transaction)
    }
    let load = try await store.read { transaction in try WriterPackLoader.load(novel: novel, chapter: 2, in: transaction) }
    #expect(load.unreadable.isEmpty)
    #expect(
      load.world.characterStates == [
        WriterPackCharacterState(entity: "mira", location: "the pier", conditions: ["tired"], immediateGoal: nil, statusNote: nil, lastUpdatedChapter: 1)
      ])
    #expect(load.world.relationships == [WriterPackRelationship(entity: "mira", target: "oren", kind: "ally", note: "wary", chapter: 1, order: 0)])

    let pack = try WriterPackAssembler.assemble(load.world, chapter: 2).pack
    let rendered = { (key: String) in pack.sections.first { $0.key == key }?.rendered ?? "" }
    #expect(rendered("character_state").contains("Location: the pier"))
    #expect(rendered("character_state").contains("Conditions: tired"))
    #expect(rendered("relationships").contains("Mira → oren (ally): wary [ch 1]"))
  }

  // finalize-review-gate.ts:161-166: a claim the review left unreached no longer counts as reached, so the secret it gates stays out of the writer's pack
  @Test func shouldKeepASecretGatedOnAnUnreachedClaimOutOfThePack() async throws {
    let reached = try await gated { transaction in
      try CanonWrites.finalize(novel: novel, chapter: 1, review: review([]), contract: contract(claims: ["rise"]), in: &transaction)
    }
    #expect(carries(reached, secretText))
    let unreached = try await gated { transaction in
      try CanonWrites.finalize(novel: novel, chapter: 1, review: review([], unreached: ["rise"]), contract: contract(claims: ["rise"]), in: &transaction)
    }
    #expect(!carries(unreached, secretText))
    let unreadable = try await gated { transaction in try CanonWrites.finalize(novel: novel, chapter: 1, unreadable: .review, in: &transaction) }
    #expect(!carries(unreadable, secretText))
  }

  @Test(arguments: [CharacterStateEntry.databaseTableName, CanonRelationshipEntry.databaseTableName])
  func shouldRefuseThePackWhenACanonCharacterTableIsFaulted(_ table: String) async throws {
    let store = try Projection.store(try Projection.reconciler(), allowingFaults: true)
    _ = try await Projection.write(store) { transaction in _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction) }
    try await ReadWorld.insertFault(table, key: String(reflecting: novel), in: store)
    let load = try await store.read { transaction in try WriterPackLoader.load(novel: novel, chapter: 1, in: transaction) }
    #expect(load.unreadable == [.characters])
  }
}
