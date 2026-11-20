import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let context = ProposalRevertContext(novel: novel, now: now)

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

private func stage(_ ops: String..., in replicas: CausalReplicas) async throws -> UUID {
  let changeSet = try ValidatedChangeSet(
    try OrderedJSON(parsing: "[\(ops.joined(separator: ","))]"), options: ChangeSetValidationOptions(entityMaterialization: false))
  let input = StagingWorld.input(changeSet, novel: novel, session: nil, kind: .chat)
  return try await replicas.write(0) { transaction in try ProposalStager.stage(input, in: &transaction) }.proposal.id
}

private func applyTurn(_ id: UUID, _ selection: ApplySelection, sources: [OpSource], on index: Int, in replicas: CausalReplicas) async throws {
  let apply = ProposalApplyContext(novel: novel, now: now, automatic: true, sources: sources, unrestrictedAvailable: UnrestrictedWriting.isAvailable)
  _ = try await replicas.write(index) { transaction in try ProposalApply.apply(proposal: id, selection: selection, context: apply, in: &transaction) }
}

private func undo(_ id: UUID, _ index: Int, on replica: Int, in replicas: CausalReplicas) async throws -> ProposalChangeToggle {
  try await replicas.write(replica) { transaction in try ProposalRevert.undo(proposal: id, index: index, context: context, in: &transaction) }
}

private func redo(_ id: UUID, _ index: Int, on replica: Int, in replicas: CausalReplicas) async throws -> ProposalChangeToggle {
  try await replicas.write(replica) { transaction in try ProposalRevert.redo(proposal: id, index: index, context: context, in: &transaction) }
}

private func refusal(_ id: UUID, _ index: Int, on replica: Int, in replicas: CausalReplicas, redoing: Bool = false) async -> ProposalRevertError? {
  do {
    _ = try await redoing ? redo(id, index, on: replica, in: replicas) : undo(id, index, on: replica, in: replicas)
    return nil
  } catch {
    guard case .aborted(let cause) = error as? StoreError else { return nil }
    return cause as? ProposalRevertError
  }
}

private func entries(_ id: UUID, on replica: Int, in replicas: CausalReplicas) async throws -> [ProposalChangeEntry] {
  try await replicas.store(replica).read { transaction in
    let proposal = try #require(try ProposalRecord.read(id: id, in: transaction).entry?.record)
    return try ProposalChangeRecord.changes(of: proposal, in: transaction)
  }
}

private func states(_ refs: [String], on replica: Int, in replicas: CausalReplicas) async throws -> [JSString: ArtifactState] {
  try await replicas.store(replica).read { try ArtifactStateLoader.states(refs: refs, novel: novel, in: $0) }
}

private func milestoneExists(_ key: String, on replica: Int, in replicas: CausalReplicas) async throws -> Bool {
  try await replicas.store(replica).read { try MilestoneRecord.listing(novel: novel, in: $0).live.contains { $0.milestone == key } }
}

@Suite("Proposal revert replicas", TestTimeLimit.standard)
struct ProposalRevertReplicaTests {
  // Two devices undoing, then redoing, one change at once converge on the same content and status; the later `undone_state` wins, and both equal the prior
  @Test func shouldConvergeWhenTwoDevicesUndoAndRedoAChangeConcurrently() async throws {
    for seed in [UInt64(0xF17A), 0xF17B] {
      let (reconciler, replicas) = try await makeReplicas(seed: seed)
      let id = try await stage(RevertWorld.kael, RevertWorld.maraNotes, in: replicas)
      try await replicas.settle()
      let refs = ["entity:kael", "entity:mara"]
      let before = try await states(refs, on: 0, in: replicas)
      try await applyTurn(id, .whole, sources: [.quoted, .quoted], on: 0, in: replicas)
      try await replicas.settle()
      let after = try await states(refs, on: 1, in: replicas)

      #expect(try await undo(id, 1, on: 0, in: replicas).changed)
      #expect(try await undo(id, 1, on: 1, in: replicas).changed)
      try await replicas.settle()
      try await expectConverged(reconciler, replicas)
      for replica in 0..<replicas.count {
        #expect(try await states(["entity:mara"], on: replica, in: replicas) == before.filter { $0.key == JSString("entity:mara") })
        guard case .recorded(let change) = try await entries(id, on: replica, in: replicas)[1] else { throw RevertTestError.unexpected }
        #expect(change.status == .known(.reverted))
        #expect(change.undoneState?["entity:mara"] == before[JSString("entity:mara")])
      }

      #expect(try await redo(id, 1, on: 1, in: replicas).changed)
      #expect(try await redo(id, 1, on: 2, in: replicas).changed)
      try await replicas.settle()
      try await expectConverged(reconciler, replicas)
      #expect(try await states(refs, on: 0, in: replicas) == after)

      #expect(try await undo(id, 1, on: 2, in: replicas).changed)
      #expect(try await undo(id, 0, on: 2, in: replicas).changed)
      try await replicas.settle()
      try await expectConverged(reconciler, replicas)
      #expect(try await states(refs, on: 1, in: replicas) == before)
    }
  }

  // A concurrent author's apply of a chapter's rewrites, beside an automatic first applier, toggles per change: undoing the first rewrite takes back the
  // revision both landed in, and redoing it brings both back
  @Test func shouldRedoEveryRewriteTheFirstRewritesRevisionCarried() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF17D)
    _ = try await replicas.write(0) { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: StagingText.body, summary: "It turns."), base: nil, at: now, in: &transaction)
    }
    try await replicas.settle()
    let wrist = StagingText.rewrite(StagingText.wrist, StagingText.wristRewrite, chapter: 1)
    let id = try await stage(RevertWorld.kael, wrist, StagingText.rewrite(StagingText.fear, StagingText.fearRewrite, chapter: 1), in: replicas)
    try await replicas.settle()
    let before = try await states(["draft:1"], on: 0, in: replicas)
    try await applyTurn(id, .indexes([0]), sources: [.quoted, .quoted, .quoted], on: 0, in: replicas)
    await replicas.advanceClock(of: 1, by: .seconds(60))
    let author = ProposalApplyContext(novel: novel, now: now)
    _ = try await replicas.write(1) { transaction in try ProposalApply.apply(proposal: id, selection: .indexes([1, 2]), context: author, in: &transaction) }
    try await replicas.settle()
    let after = try await states(["draft:1"], on: 2, in: replicas)

    #expect(try await undo(id, 1, on: 2, in: replicas).changed)
    #expect(try await states(["draft:1"], on: 2, in: replicas) == before)
    #expect(try await redo(id, 1, on: 2, in: replicas).changed)
    #expect(try await states(["draft:1"], on: 2, in: replicas) == after)
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)
    let body = try await replicas.store(0).read { try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record.content.body }
    #expect(body?.contains(StagingText.wristRewrite) == true && body?.contains(StagingText.fearRewrite) == true)
  }

  // F10 rule: a concurrent applier's change reads declined on a third device until its record arrives; while its content stands there, an undo it would
  // strand is refused as a changed declined index, and once the record arrives the undo is refused as relied on (RFN_015)
  @Test func shouldNotComputeDependentsFromAnIncompleteSync() async throws {
    let (_, replicas) = try await makeReplicas(seed: 0xF17C)
    let id = try await stage(RevertWorld.kael, RevertWorld.kaelEscapes, in: replicas)
    try await replicas.settle()
    try await applyTurn(id, .indexes([0]), sources: [.quoted, .quoted], on: 0, in: replicas)
    await replicas.advanceClock(of: 1, by: .seconds(60))
    try await applyTurn(id, .whole, sources: [.quoted, .quoted], on: 1, in: replicas)

    try await replicas.deliver(from: 0, to: 2)
    var partial = false
    while try await replicas.deliver(from: 1, to: 2, atMost: 1) > 0 {
      guard try await milestoneExists("kael-escapes", on: 2, in: replicas) else { continue }
      partial = try await entries(id, on: 2, in: replicas)[1] == .declined
      break
    }
    #expect(partial)
    #expect(await refusal(id, 0, on: 2, in: replicas) == .declinedChanged([1]))

    try await replicas.settle()
    #expect(try await entries(id, on: 2, in: replicas).allSatisfy { if case .recorded = $0 { true } else { false } })
    #expect(await refusal(id, 0, on: 2, in: replicas) == .dependents(index: 0, [1]))
  }

  // The redo twin: a change that relies on a concurrent applier's change, whose content but not record has arrived, is not redone over it; once the record
  // arrives the change it relies on reads applied and the redo goes ahead
  @Test func shouldNotComputePrerequisitesFromAnIncompleteSync() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF17E)
    let cast = #"{"op":"bible_document.upsert","section":"project","slug":"cast","body":"Kael carries the story."}"#
    let id = try await stage(RevertWorld.kael, cast, in: replicas)
    try await replicas.settle()
    try await applyTurn(id, .indexes([1]), sources: [.quoted, .quoted], on: 0, in: replicas)
    await replicas.advanceClock(of: 1, by: .seconds(60))
    let author = ProposalApplyContext(novel: novel, now: now)
    _ = try await replicas.write(1) { transaction in try ProposalApply.apply(proposal: id, selection: .indexes([0]), context: author, in: &transaction) }

    try await replicas.deliver(from: 0, to: 2)
    #expect(try await undo(id, 1, on: 2, in: replicas).changed)
    var partial = false
    while try await replicas.deliver(from: 1, to: 2, atMost: 1) > 0 {
      guard try await states(["entity:kael"], on: 2, in: replicas)[JSString("entity:kael")]?.exists == true else { continue }
      partial = try await entries(id, on: 2, in: replicas)[0] == .declined
      break
    }
    #expect(partial)
    #expect(await refusal(id, 1, on: 2, in: replicas, redoing: true) == .declinedChanged([0]))

    try await replicas.settle()
    #expect(try await redo(id, 1, on: 2, in: replicas).changed)
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)
  }

  // A redo of a change on one device while another undoes what it relies on: each guard passes on its own device, so the merge keeps the redone change
  // over a removed prerequisite (the stranded outcome the reference's row lock prevents); every replica converges on it without a projection fault
  @Test func shouldConvergeWhenARedoRacesAnUndoOfItsPrerequisite() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF17F)
    let id = try await stage(RevertWorld.kael, RevertWorld.kaelEscapes, in: replicas)
    try await replicas.settle()
    try await applyTurn(id, .whole, sources: [.quoted, .quoted], on: 0, in: replicas)
    try await replicas.settle()
    #expect(try await undo(id, 1, on: 0, in: replicas).changed)
    try await replicas.settle()

    #expect(try await redo(id, 1, on: 0, in: replicas).changed)
    #expect(try await undo(id, 0, on: 1, in: replicas).changed)
    try await replicas.settle()
    try await expectConverged(reconciler, replicas)

    for replica in 0..<replicas.count {
      let statuses = try await entries(id, on: replica, in: replicas).map { entry -> ProposalChangeStatus? in
        guard case .recorded(let change) = entry else { return nil }
        return change.status.known
      }
      #expect(statuses == [.reverted, .applied])
      #expect(try await states(["entity:kael"], on: replica, in: replicas)[JSString("entity:kael")]?.exists == false)
      #expect(try await milestoneExists("kael-escapes", on: replica, in: replicas))
    }
    #expect(await refusal(id, 1, on: 2, in: replicas) == nil)
  }
}
