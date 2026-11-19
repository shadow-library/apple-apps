import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let now = Date(timeIntervalSince1970: 1_700_000_000)

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

private func apply(_ id: UUID, _ selection: [Int], sources: [OpSource], on index: Int, in replicas: CausalReplicas) async throws -> ProposalApplyOutcome {
  let context = ProposalApplyContext(novel: novel, now: now, automatic: true, sources: sources, unrestrictedAvailable: UnrestrictedWriting.isAvailable)
  return try await replicas.write(index) { transaction in try ProposalApply.apply(proposal: id, selection: .indexes(selection), context: context, in: &transaction) }
}

// Concurrent applies of one card on two devices keep every change either recorded, and the first applier's provenance
@Suite("Proposal apply replicas", TestTimeLimit.standard)
struct ProposalApplyReplicaTests {
  @Test func shouldConvergeOnTheUnionOfTwoDevicesSelectionsAndTheFirstAppliersSources() async throws {
    for seed in [UInt64(0xF16A), 0xF16B] {
      let (reconciler, replicas) = try await makeReplicas(seed: seed)
      let input = StagingWorld.input(try StagingWorld.changeSet(ApplyWorld.maraMotive, ApplyWorld.kael), novel: novel, session: nil)
      let id = try await replicas.write(0) { transaction in try ProposalStager.stage(input, in: &transaction) }.proposal.id
      try await replicas.settle()

      let left = try await apply(id, [0], sources: [.quoted, .idea], on: 0, in: replicas)
      let right = try await apply(id, [1], sources: [.idea, .quoted], on: 1, in: replicas)
      guard case .applied = left, case .applied = right else {
        Issue.record("a concurrent apply did not apply")
        return
      }
      try await replicas.settle()
      try await expectConverged(reconciler, replicas)

      for index in 0..<replicas.count {
        let store = await replicas.store(index)
        let proposal = try await store.read { try #require(try ProposalRecord.read(id: id, in: $0).entry?.record) }
        #expect(proposal.decision == .known(.applied))
        let application = try #require(proposal.application)
        let sources: [StoredEnum<OpSource>] = application.selected == [0] ? [.known(.quoted), .known(.idea)] : [.known(.idea), .known(.quoted)]
        #expect(application.selected == [0] || application.selected == [1])
        #expect(application.sources == sources)
        let changes = try await store.read { try ProposalChangeRecord.changes(of: proposal, in: $0) }
        #expect(changes.map(\.isAppliedRecord) == [true, true])
        let mara = try await store.read { try EntityRecord.read(novel: novel, entity: "mara", in: $0).entry?.record }
        #expect(mara?.motivation == "She wants the lamp.")
        #expect(try await store.read { try EntityRecord.read(novel: novel, entity: "kael", in: $0).entry } != nil)
      }
      let late = await replicas.store(2)
      do {
        _ = try await late.applyProposal(id, selection: .whole, context: ProposalApplyContext(novel: novel, now: now))
        Issue.record("an applied card applied again")
      } catch {
        #expect(error == .notPending(.known(.applied)))
      }
    }
  }
}

extension ProposalChangeEntry {
  fileprivate var isAppliedRecord: Bool {
    guard case .recorded(let change) = self else { return false }
    return change.status == .known(.applied) && change.undo != nil
  }
}
