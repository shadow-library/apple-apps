import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func sampleNovel() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(ProjectionDerivations.all + PlanWorldDerivations.all))
  _ = try await Projection.write(store) { transaction in
    try PlanWorldWrites.volume(novel: novel, "one", ordinal: 1, in: &transaction)
    for key in ["rise", "r\u{E9}ve"] { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
    try PlanWorldWrites.secret(
      novel: novel, "ledger", revealChapter: 2, unlock: unlock(.milestone("rise"), .volume("one"), .chapter(3), .ending), source: .seed, in: &transaction)
    try PlanWorldWrites.secret(novel: novel, "heir", unlock: .object(["all": .string("later")]), in: &transaction)
    try PlanWorldWrites.secret(novel: novel, "salt", in: &transaction)
    _ = try transaction.set(SecretRecord.ref(novel: novel, secret: "salt"), ["text": .int(1)])
    try PlanWorldWrites.putPlan(
      novel: novel, chapter: 1, planContent(volume: "one", contract(learns: [Learn("mara", "ledger")], claims: ["rise"])), in: &transaction)
    try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(learns: [Learn("mara", "heir")], ending: true)), in: &transaction)
    try PlanWorldWrites.putPlan(novel: novel, chapter: 3, planContent(contract()), in: &transaction)
    _ = try transaction.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 3), body: .object(["body": .int(1)]))
    try PlanWorldWrites.finalize(novel: novel, chapter: 1, volume: "one", contract(learns: [Learn("mara", "ledger")], claims: ["rise"]), in: &transaction)
  }
  return store
}

private struct Derived: Equatable {
  let reveals: Set<PlanRevealEntry>
  let claims: Set<MilestoneClaimEntry>
  let milestones: Set<MilestoneStateEntry>
}

private func stored(in store: VaultStore) async throws -> Derived {
  Derived(
    reveals: Set(try await Projection.fetch(PlanRevealDerivation.request(for: novel), in: store)),
    claims: Set(try await Projection.fetch(MilestoneClaimDerivation.request(for: novel), in: store)),
    milestones: Set(try await Projection.fetch(MilestoneStateDerivation.request(for: novel), in: store)))
}

private func computed(in store: VaultStore) async throws -> Derived {
  try await store.read { transaction in
    let context = DerivationContext(records: transaction)
    return Derived(
      reveals: Set(try PlanRevealDerivation().outputs(for: novel, in: context)), claims: Set(try MilestoneClaimDerivation().outputs(for: novel, in: context)),
      milestones: Set(try MilestoneStateDerivation().outputs(for: novel, in: context)))
  }
}

private func corrupt(_ sql: String, in store: VaultStore) async throws {
  _ = try await store.write { transaction in try transaction.database.execute(sql: sql, arguments: [novel]) }
}

private func loaded(in store: VaultStore) async throws -> NovelPlanWorld? {
  try await store.read { transaction in try NovelPlanWorld.load(novel: novel, in: DerivationContext(records: transaction)) }
}

private let goldenWorld = """
  {"chapters":[{"basis":"canon","chapter":1,"claims":["rise"],"ending":false,"learns":[{"entity":"mara","fact":"ledger"}],"pov":["mara"],"volume":"one"},\
  {"basis":"plan","chapter":2,"claims":[],"ending":true,"learns":[{"entity":"mara","fact":"heir"}],"pov":["mara"]}],\
  "facts":[{"fact":"heir","source":"manual","unlockReadable":false},\
  {"fact":"ledger","revealChapter":2,"source":"seed","unlock":{"all":[{"milestone":"rise"},{"volume":"one"},{"chapter":3},{"ending":true}]},"unlockReadable":true}],\
  "frontier":1,"milestones":["rise","r\u{E9}ve"],"plans":[1,2,3],"unreadablePlans":[3],"unreadableSecrets":["salt"],"volumes":[{"ordinal":1,"volume":"one"}]}
  """

private let goldenTerms = #"{"claims":["rise"],"learns":[{"entity":"mara","fact":"ledger"}],"pov":["mara"]}"#

@Suite("Plan world storage", .timeLimit(.minutes(2)))
struct PlanWorldStorageTests {
  // A failure here means a stored shape changed: raise PlanWorldDerivation.version or ChapterContractDerivation.version, then update the golden text.
  @Test
  func shouldEncodeTheStoredWorldAndTermsExactlyAsPinned() async throws {
    let store = try await sampleNovel()
    let world = try #require(try await Projection.fetch(PlanWorldDerivation.request(for: novel), in: store).first)
    #expect(String(decoding: world.world, as: UTF8.self) == goldenWorld)
    let plan = try ChapterPlanRecord.ref(novel: novel, chapter: 1)
    let terms = try #require(try await Projection.fetch(ChapterContractDerivation.request(for: plan), in: store).first)
    #expect(String(decoding: terms.terms, as: UTF8.self) == goldenTerms)
    #expect(PlanWorldDerivation.version == 1 && ChapterContractDerivation.version == 1)
  }

  @Test
  func shouldDeriveFromTheRecordsWhenTheStoredWorldCannotBeDecoded() async throws {
    let store = try await sampleNovel()
    let expected = try await stored(in: store)
    try await corrupt("UPDATE nf_derived_plan_world SET world = x'00' WHERE novel = ?", in: store)
    #expect(try await computed(in: store) == expected)
    _ = try await Projection.write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 4, planContent(contract(claims: ["rise"])), in: &transaction)
    }
    #expect(try await stored(in: store).claims.contains { $0.chapter == 4 && $0.status == .duplicate && $0.holder == 1 })
    #expect(try await Projection.faults(try Projection.reconciler(ProjectionDerivations.all + PlanWorldDerivations.all), in: store).isEmpty)
  }

  @Test
  func shouldReadAChapterAgainFromItsRecordWhenItsStoredTermsCannotBeDecoded() async throws {
    let store = try await sampleNovel()
    let expected = try await stored(in: store)
    let world = try await loaded(in: store)
    try await corrupt("UPDATE nf_derived_chapter_contract SET terms = x'00' WHERE novel = ?", in: store)
    #expect(try await loaded(in: store) == world)
    try await corrupt("UPDATE nf_derived_plan_world SET world = x'00' WHERE novel = ?", in: store)
    #expect(try await computed(in: store) == expected)
  }
}
