import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let chapterOne = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000e1")

private let introduced: [ProposedChange] = [
  Kept.entity("kael"), Kept.appearance("kael"), Kept.state("kael", location: "the pier"), Kept.relationship("kael", "mira", "rival", note: "wary"),
  Kept.knowledge("kael", "heir"),
]

/// A commit as ChapterFinalize writes it: the entities the review keeps as new are created in the write that sets the canon.
private func commit(_ chapter: Int, _ kept: [ProposedChange], id: UUID = UUID(), in transaction: inout WriteTransaction) throws {
  for case .entity(let entity) in kept { try CanonWrites.entity(novel: novel, entity.entityKey, in: &transaction) }
  try CanonWrites.finalize(novel: novel, chapter: chapter, review: review(kept, id: id), in: &transaction)
}

private func seed(_ transaction: inout WriteTransaction) throws {
  try ChapterWrites.entity(novel: novel, "mira", in: &transaction)
  for (secret, chapter) in [("heir", 1), ("tide", 2)] { try PlanWorldWrites.secret(novel: novel, secret, revealChapter: chapter, in: &transaction) }
}

/// Two devices synced on the seed; the second runs five seconds ahead, so whatever both create is last created there.
private func devices() async throws -> (CausalReplicas, NovelForgeReconciler) {
  let reconciler = try Projection.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0xE10))
  try await replicas.write(0) { transaction in try seed(&transaction) }
  try await replicas.settle()
  await replicas.advanceClock(of: 1, by: .seconds(5))
  return (replicas, reconciler)
}

private func expectRebuilt(_ reconciler: NovelForgeReconciler, _ store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

/// A canon-derived view whose rows name the entities they are about.
enum KeptEntityView: String, CaseIterable, Sendable {
  case appearance
  case state
  case relationship
  case event
  case knowledge

  func rows(in store: VaultStore) async throws -> Set<String> {
    switch self {
    case .appearance: try await CanonTables.appearances(novel, in: store)
    case .state: Set(try await CanonTables.states(novel, in: store).map(\.description))
    case .relationship: try await CanonTables.relationships(novel, in: store)
    case .event: Set(try await CanonTables.events(novel, in: store).map(Self.line))
    case .knowledge: Set(try await ChapterTables.knowledge(novel, in: store).map(\.description))
    }
  }

  private static func line(_ event: EventView) -> String {
    let json = { (value: JSONValue?) in value.map(CanonicalText.of) ?? "null" }
    return "\(event.entity)@\(event.chapter) \(event.kind.rawValue) \(event.detail) \(json(event.before)) -> \(json(event.after))"
  }

  /// What chapter 1 committing `introduced` derives.
  var introduced: Set<String> {
    switch self {
    case .appearance: ["kael@1"]
    case .state: [StateView("kael", location: "the pier", chapter: 1).description]
    case .relationship: ["kael→mira:rival@1 wary"]
    case .event:
      Set(
        [
          EventView("kael", 1, .appearance, before: nil, after: nil), EventView("kael", 1, .state, before: nil, after: stateJSON(location: "the pier")),
          EventView("kael", 1, .relationship, detail: "mira:rival", before: nil, after: edgeJSON("mira", "rival", note: "wary")),
        ].map(Self.line))
    case .knowledge: [LedgerView("heir", "kael", 1, .generated, .committed).description]
    }
  }
}

@Suite("A kept new entity across devices", TestTimeLimit.standard)
struct CanonKeptEntityTests {
  // Each device's commit creates kael, so its live-since clock ends at the later create while the canon that wins is the earlier write
  @Test(arguments: KeptEntityView.allCases)
  func shouldKeepWhatTheCanonKeepsOfANewEntityWhenTwoDevicesCommitTheSameChapter(_ view: KeptEntityView) async throws {
    let (replicas, reconciler) = try await devices()
    for index in 0..<2 { try await replicas.write(index) { transaction in try commit(1, introduced, id: chapterOne, in: &transaction) } }
    for index in 0..<2 { #expect(try await view.rows(in: await replicas.store(index)) == view.introduced, "replica \(index) before syncing") }
    try await replicas.settle()
    for index in 0..<2 {
      let store = await replicas.store(index)
      #expect(try await view.rows(in: store) == view.introduced, "replica \(index) after syncing")
      try await expectRebuilt(reconciler, store)
    }
  }

  // The device whose canon wins goes on to chapter 2 before the other's later create of kael arrives
  @Test func shouldKeepALaterChaptersRowsOfAnEntityAnEarlierCanonKeptAsNew() async throws {
    let (replicas, reconciler) = try await devices()
    try await replicas.write(0) { transaction in
      try commit(1, introduced, id: chapterOne, in: &transaction)
      try commit(2, [Kept.state("kael", location: "the tower"), Kept.relationship("kael", "mira", "rival", note: "trusted"), Kept.knowledge("kael", "tide")], in: &transaction)
    }
    try await replicas.write(1) { transaction in try commit(1, introduced, id: chapterOne, in: &transaction) }
    try await replicas.settle()
    for index in 0..<2 {
      let store = await replicas.store(index)
      let created = try await store.read { transaction in try transaction.state(of: EntityRecord.ref(novel: novel, entity: "kael"))?.liveSince }
      let chapterTwo = try await Projection.finals(in: store).first { $0.chapter == 2 }?.canonClock
      #expect(try #require(created) > (try #require(chapterTwo)), "kael is last created after chapter 2's canon")
      #expect(try await CanonTables.states(novel, in: store) == [StateView("kael", location: "the tower", chapter: 2)])
      #expect(try await CanonTables.relationships(novel, in: store) == ["kael→mira:rival@1 wary", "kael→mira:rival@2 trusted"])
      #expect(
        try await ChapterTables.knowledge(novel, in: store) == [LedgerView("heir", "kael", 1, .generated, .committed), LedgerView("tide", "kael", 2, .generated, .committed)])
      try await expectRebuilt(reconciler, store)
    }
  }

  // The winner kept kael's rows without keeping kael as new; only the losing canon created it, after the winner was written
  @Test func shouldDeriveNothingOfAnEntityOnlyTheLosingCanonKeptAsNew() async throws {
    let (replicas, reconciler) = try await devices()
    try await replicas.write(0) { transaction in
      try CanonWrites.finalize(novel: novel, chapter: 1, review: review([Kept.appearance("kael"), Kept.state("kael", location: "the pier")]), in: &transaction)
    }
    try await replicas.write(1) { transaction in try commit(1, introduced, in: &transaction) }
    try await replicas.settle()
    for index in 0..<2 {
      let store = await replicas.store(index)
      for view in KeptEntityView.allCases { #expect(try await view.rows(in: store).isEmpty, "replica \(index) \(view)") }
      try await expectRebuilt(reconciler, store)
    }
  }

  @Test func shouldDeriveNothingOfAKeptNewEntityStillRemovedAfterSyncing() async throws {
    let (replicas, reconciler) = try await devices()
    for index in 0..<2 { try await replicas.write(index) { transaction in try commit(1, introduced, id: chapterOne, in: &transaction) } }
    try await replicas.write(1) { transaction in try CanonWrites.removeEntity(novel: novel, "kael", in: &transaction) }
    try await replicas.settle()
    for index in 0..<2 {
      let store = await replicas.store(index)
      for view in KeptEntityView.allCases { #expect(try await view.rows(in: store).isEmpty, "replica \(index) \(view)") }
      try await expectRebuilt(reconciler, store)
    }
  }

  // An entity the author created before any canon keeps its earlier clock when a later canon keeps it as new
  @Test func shouldCountAnEntityFromItsCreateWhenThatIsEarlierThanTheCanonKeepingItAsNew() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    _ = try await Projection.write(store) { transaction in
      try seed(&transaction)
      try CanonWrites.entity(novel: novel, "oren", in: &transaction)
    }
    _ = try await Projection.write(store) { transaction in try commit(1, [Kept.appearance("oren")], in: &transaction) }
    _ = try await Projection.write(store) { transaction in try commit(2, [Kept.entity("oren")], in: &transaction) }
    #expect(try await CanonTables.appearances(novel, in: store) == ["oren@1", "oren@2"])
    try await expectRebuilt(reconciler, store)
  }

  // The review keeps the entity as written, in NFD, while the canon stores its frozen learner in NFC (FinalChapterRecord)
  @Test func shouldMatchAFrozenLearnerWrittenInAnotherNormalFormToTheEntityKeptAsNew() async throws {
    let (composed, decomposed) = ("zo\u{EB}", "zoe\u{308}")
    let (replicas, reconciler) = try await devices()
    try await replicas.write(0) { transaction in
      try commit(1, [Kept.entity(decomposed)], id: chapterOne, in: &transaction)
      try CanonWrites.finalize(novel: novel, chapter: 2, review: review([]), knowledge: [KnowledgeReveal(entityKey: decomposed, factKey: "tide")], in: &transaction)
    }
    try await replicas.write(1) { transaction in try commit(1, [Kept.entity(decomposed)], id: chapterOne, in: &transaction) }
    try await replicas.settle()
    for index in 0..<2 {
      let store = await replicas.store(index)
      let rows = try await Projection.fetch(CharacterKnowledgeDerivation.request(for: novel), in: store)
      #expect(rows.map { [$0.fact, $0.entity.jsNormalize(.nfc), "\($0.chapter)", $0.source.rawValue] } == [["tide", composed, "2", FactSource.brief.rawValue]])
      try await expectRebuilt(reconciler, store)
    }
  }

  // Every knowledge input reaches the derivation in NFC today (frozen pairs, manual rows, plan learns), so the helper's own lookup is pinned here
  @Test func shouldFindAKeptNewEntityWhicheverNormalFormTheCallerNamesIt() throws {
    let (record, kept) = (try stamp(9), try stamp(2))
    #expect(CanonBinding.liveSince("zoe\u{308}", record: record, keptAsNew: [JSString("zo\u{EB}"): kept]) == kept)
    #expect(CanonBinding.liveSince("zoe\u{308}", record: nil, keptAsNew: [JSString("zo\u{EB}"): kept]) == nil)
  }

  // Accepted deviation: the reference deletes kael's rows with it (knowledge.ts, entity_id cascades) and a recreated kael starts fresh
  @Test func shouldGiveAKeptNewEntityRemovedAndCreatedAgainItsCanonsRowsBack() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    _ = try await Projection.write(store) { transaction in
      try seed(&transaction)
      try CanonWrites.entity(novel: novel, "oren", in: &transaction)
      try commit(1, introduced + [Kept.appearance("oren")], in: &transaction)
    }
    #expect(try await CanonTables.appearances(novel, in: store) == ["kael@1", "oren@1"])
    _ = try await Projection.write(store) { transaction in
      for key in ["kael", "oren"] { try CanonWrites.removeEntity(novel: novel, key, in: &transaction) }
    }
    for view in KeptEntityView.allCases { #expect(try await view.rows(in: store).isEmpty, "\(view) once removed") }
    _ = try await Projection.write(store) { transaction in
      for key in ["kael", "oren"] { try CanonWrites.entity(novel: novel, key, in: &transaction) }
    }
    for view in KeptEntityView.allCases { #expect(try await view.rows(in: store) == view.introduced, "\(view) once created again") }
    try await expectRebuilt(reconciler, store)
  }

  @Test func shouldDeriveNothingOfAKeptNewEntityThisVersionCannotRead() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    _ = try await Projection.write(store) { transaction in
      try seed(&transaction)
      try commit(1, introduced, in: &transaction)
    }
    let ref = EntityRecord.ref(novel: novel, entity: "kael")
    try await Projection.set(ref, [EntityField.type.rawValue: .int(7)], in: store)
    let reading = try await store.read { transaction in try EntityRecord.read(ref, in: transaction) }
    guard case .unreadable = reading else { throw SchemaFixtureError(description: "kael reads as unreadable, not \(reading)") }
    for view in KeptEntityView.allCases { #expect(try await view.rows(in: store).isEmpty, "\(view)") }
    try await expectRebuilt(reconciler, store)
  }
}
