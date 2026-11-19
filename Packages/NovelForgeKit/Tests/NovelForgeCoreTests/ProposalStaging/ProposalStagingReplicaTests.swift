import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = StagingWorld

private let novel = SchemaFixture.novel
private let maraEdit = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","notes":"Left-handed."}"#
private let kael = #"{"op":"entity.upsert","entityKey":"kael","type":"character","name":"Kael","motivation":"He wants the lamp."}"#

private func makeReplicas(seed: UInt64) async throws -> (NovelForgeReconciler, CausalReplicas) {
  let reconciler = try Projection.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  _ = try await replicas.write(0) { transaction in
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
  }
  try await replicas.settle()
  return (reconciler, replicas)
}

private func expectConverged(_ reconciler: NovelForgeReconciler, _ replicas: CausalReplicas) async throws {
  let first = try await Projection.derived(reconciler, in: await replicas.store(0))
  for index in 0..<replicas.count {
    let store = await replicas.store(index)
    #expect(try await Projection.derived(reconciler, in: store) == first)
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
    #expect(try await Projection.faults(reconciler, in: store).isEmpty)
  }
}

private func stage(_ op: String, on index: Int, in replicas: CausalReplicas) async throws -> StagedProposal {
  let input = World.input(try World.changeSet(op), novel: novel)
  return try await replicas.write(index) { transaction in try ProposalStager.stage(input, in: &transaction) }
}

private func decision(_ id: UUID, on index: Int, in replicas: CausalReplicas) async throws -> StoredEnum<ProposalDecision>? {
  try await replicas.store(index).read { try ProposalRecord.read(id: id, in: $0).entry?.record.decision }
}

private func card(_ id: UUID, on index: Int, in replicas: CausalReplicas) async throws -> ProposalCard? {
  try await replicas.store(index).read { try ProposalRecord.read(id: id, in: $0).entry?.record.card }
}

// Concurrent staging, discard and apply across devices settle on the monotone decision (pending < superseded < discarded < applied)
@Suite("Proposal staging replicas", TestTimeLimit.standard)
struct ProposalStagingReplicaTests {
  @Test func shouldSupersedeTheSameCardFromTwoDevicesAndConvergeWithBothNewCardsPending() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF15A)
    let older = try await stage(maraEdit, on: 0, in: replicas)
    try await replicas.settle()
    let left = try await stage(maraEdit, on: 0, in: replicas)
    let right = try await stage(maraEdit, on: 1, in: replicas)
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)
    for index in 0..<replicas.count {
      #expect(try await decision(older.proposal.id, on: index, in: replicas) == .known(.superseded))
      #expect(try await decision(left.proposal.id, on: index, in: replicas) == .known(.pending))
      #expect(try await decision(right.proposal.id, on: index, in: replicas) == .known(.pending))
      #expect(try await card(left.proposal.id, on: index, in: replicas)?.supersedes == [older.proposal.id])
      #expect(try await card(right.proposal.id, on: index, in: replicas)?.supersedes == [older.proposal.id])
    }
    let newest = try await stage(maraEdit, on: 2, in: replicas)
    #expect(Set(newest.superseded) == [left.proposal.id, right.proposal.id])
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)
  }

  @Test func shouldKeepADiscardOrAnApplyThatRacedASupersession() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF15B)
    let discarded = try await stage(maraEdit, on: 0, in: replicas)
    try await replicas.settle()
    _ = try await replicas.write(0) { transaction in try ProposalDiscard.discard(discarded.proposal.id, novel: novel, in: &transaction) }
    let replacing = try await stage(maraEdit, on: 1, in: replicas)
    #expect(replacing.superseded == [discarded.proposal.id])
    try await replicas.settle()

    let applied = try await stage(kael, on: 0, in: replicas)
    try await replicas.settle()
    _ = try await replicas.write(0) { transaction in
      try transaction.set(applied.proposal.ref, [ProposalField.decision.rawValue: StoredEnum.known(ProposalDecision.applied).json])
    }
    _ = try await stage(kael, on: 1, in: replicas)
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)
    for index in 0..<replicas.count {
      #expect(try await decision(discarded.proposal.id, on: index, in: replicas) == .known(.discarded))
      #expect(try await decision(applied.proposal.id, on: index, in: replicas) == .known(.applied))
      #expect(try await card(replacing.proposal.id, on: index, in: replicas)?.supersedes == [discarded.proposal.id])
    }
  }

  // RULES F10: a superseded or applied card is never discarded, on any device
  @Test func shouldRefuseToDiscardACardAnotherDeviceSupersededOrApplied() async throws {
    let (_, replicas) = try await makeReplicas(seed: 0xF15C)
    let older = try await stage(maraEdit, on: 0, in: replicas)
    try await replicas.settle()
    _ = try await stage(maraEdit, on: 1, in: replicas)
    try await replicas.settle()
    do {
      _ = try await replicas.write(2) { transaction in try ProposalDiscard.discard(older.proposal.id, novel: novel, in: &transaction) }
      Issue.record("a superseded card was discarded")
    } catch {
      guard case .aborted(let cause)? = error as? StoreError else { throw error }
      #expect(cause as? ProposalDecisionError == .notPending(.known(.superseded)))
    }
    #expect(try await decision(older.proposal.id, on: 2, in: replicas) == .known(.superseded))
  }

  // Two devices each turning one idea down leave two active rejections (the unique index holds per device); the next rejection settles both
  @Test func shouldCollapseConcurrentRejectionsOfOneIdeaAtTheNextRejection() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF15D)
    let proposal = try await stage(kael, on: 0, in: replicas).proposal
    try await replicas.settle()
    let left = try await replicas.write(0) { transaction in
      try NotebookIdeaRejections.reject(proposal: proposal.id, opIndex: 0, scope: .never, novel: novel, in: &transaction)
    }
    let right = try await replicas.write(1) { transaction in
      try NotebookIdeaRejections.reject(proposal: proposal.id, opIndex: 0, scope: .never, novel: novel, in: &transaction)
    }
    try await replicas.settle()
    let topic = NotebookTopics.idea(try #require(left.idea))
    let active = { (index: Int) async throws -> [NotebookEntry] in
      try await replicas.store(index).read { try NotebookLedger.load(novel: novel, in: $0) }.active(matching: NotebookFilter(topics: [topic]))
    }
    #expect(Set(try await active(2).map(\.id)) == [left.id, right.id])
    let latest = try #require(try await active(2).last)
    let next = try await replicas.write(2) { transaction in
      try NotebookIdeaRejections.reject(proposal: proposal.id, opIndex: 0, scope: .notNow, novel: novel, in: &transaction)
    }
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)
    for index in 0..<replicas.count {
      #expect(try await active(index).map(\.id) == [next.id])
      let ledger = try await replicas.store(index).read { try NotebookLedger.load(novel: novel, in: $0) }
      #expect(next.supersedes == latest.id)
      let earlier = latest.id == left.id ? right.id : left.id
      #expect(ledger.entry(earlier)?.status == .withdrawn)
    }
  }
}
