import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatWorld

private func makeReplicas(seed: UInt64) async throws -> (NovelForgeReconciler, CausalReplicas) {
  let reconciler = try World.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
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

private func append(_ message: ChatMessageRecord, on index: Int, in replicas: CausalReplicas) async throws {
  _ = try await replicas.write(index) { transaction in try message.append(in: &transaction) }
}

private func stage(on index: Int, in replicas: CausalReplicas) async throws -> ProposalRecord {
  let proposal = try ProposalFixture.proposal()
  _ = try await replicas.write(index) { transaction in try proposal.create(in: &transaction) }
  try await replicas.settle()
  return proposal
}

private func entries(_ proposal: ProposalRecord, on index: Int, in replicas: CausalReplicas) async throws -> [ProposalChangeEntryState] {
  try await World.entries(proposal.id, in: await replicas.store(index))
}

@Suite("Chat replicas", .timeLimit(.minutes(3)))
struct ChatReplicaTests {
  @Test func shouldConvergeOnOneTranscriptWhenTwoDevicesAppendToOneSessionConcurrently() async throws {
    try await forAll(iterations: 6, seed: 0xF23A3) { generator in
      let (reconciler, replicas) = try await makeReplicas(seed: generator.next())
      _ = try await replicas.write(0) { transaction in try ChatSessionRecord(id: World.session, novel: World.novel).create(in: &transaction) }
      try await replicas.settle()
      var written = [(writer: Int, message: ChatMessageRecord)]()
      for turn in 0..<8 {
        let writer = generator.int(in: 0...1)
        await replicas.advanceClock(of: writer, by: .milliseconds(generator.int(in: 0...20)))
        let message = try World.message(role: turn.isMultiple(of: 2) ? .user : .assistant, content: "Turn \(turn)")
        try await append(message, on: writer, in: replicas)
        written.append((writer, message))
        if generator.chance(0.4) { _ = try await replicas.step(using: &generator) }
      }
      try await replicas.settle()
      try await expectConverged(reconciler, replicas)
      let store = await replicas.store(2)
      let expected = try await store.read { transaction in
        try ChatMessageRecord.listing(session: World.session, novel: World.novel, in: transaction).entries.map(\.record.ref.key)
      }
      #expect(Set(expected) == Set(written.map(\.message.ref.key)))
      #expect(try await World.transcript(in: store).map(\.message) == expected)
      #expect(try await World.transcript(in: store).map(\.position) == Array(1...8))
      for writer in 0...1 {
        let own = written.filter { $0.writer == writer }.map(\.message.ref.key)
        #expect(expected.filter(own.contains) == own)
      }
    }
  }

  @Test func shouldKeepEveryDeviceLockedOnceAnUnrestrictedReplyReachesIt() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF23A4)
    try await append(try World.message(), on: 0, in: replicas)
    try await replicas.settle()
    let unrestricted = try World.message(role: .assistant, mode: .unrestricted)
    try await append(unrestricted, on: 1, in: replicas)
    #expect(try await World.state(in: await replicas.store(0))?.isLocked == false)
    #expect(try await World.state(in: await replicas.store(1))?.lock?.item == unrestricted.ref)
    _ = try await replicas.deliver(from: 1, to: 0)
    for turn in 0..<3 {
      try await append(try World.message(content: "Standard \(turn)", mode: .standard), on: turn % 3, in: replicas)
      try await replicas.settle()
      for index in 0..<3 { #expect(try await World.state(in: await replicas.store(index))?.lock?.item == unrestricted.ref) }
    }
    try await expectConverged(reconciler, replicas)
  }

  @Test func shouldLetAnApplyOutrankAConcurrentDiscardOnEveryDevice() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF23A5)
    let proposal = try await stage(on: 0, in: replicas)
    try await replicas.write(1, try World.applyWrite(proposal, selected: [0, 2]))
    _ = try await replicas.write(2) { transaction in try ProposalRecord.dismiss(proposal.ref, as: .discarded, in: &transaction) }
    #expect(try await World.proposalState(proposal.id, in: await replicas.store(2))?.decision == .known(.discarded))
    try await replicas.settle()
    for index in 0..<3 {
      let state = try await World.proposalState(proposal.id, in: await replicas.store(index))
      #expect(state?.decision == .known(.applied) && state?.rank == 3)
      #expect(try await entries(proposal, on: index, in: replicas) == [.applied, .declined, .applied, .declined])
    }
    try await expectConverged(reconciler, replicas)
  }

  @Test func shouldSettleConcurrentDismissalsOnTheOneWithMoreConsequence() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF23A6)
    let proposal = try await stage(on: 0, in: replicas)
    _ = try await replicas.write(1) { transaction in try ProposalRecord.dismiss(proposal.ref, as: .discarded, in: &transaction) }
    await replicas.advanceClock(of: 2, by: .seconds(30))
    _ = try await replicas.write(2) { transaction in try ProposalRecord.dismiss(proposal.ref, as: .superseded, in: &transaction) }
    try await replicas.settle()
    for index in 0..<3 {
      #expect(try await World.proposalState(proposal.id, in: await replicas.store(index))?.decision == .known(.discarded))
      #expect(try await store(index, replicas).load(ChatPendingProposals.self, World.novel).count == .available(0))
    }
    try await expectConverged(reconciler, replicas)
  }

  @Test func shouldRecordTheUnionOfConcurrentAppliesAndReadTheOtherIndexesByTheFirstSelection() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF23A7)
    let proposal = try await stage(on: 0, in: replicas)
    try await replicas.write(0, try World.applyWrite(proposal, selected: [0]))
    await replicas.advanceClock(of: 1, by: .seconds(30))
    try await replicas.write(1, try World.applyWrite(proposal, selected: [1, 3]))
    _ = try await replicas.deliver(from: 0, to: 2)
    #expect(try await entries(proposal, on: 2, in: replicas) == [.applied, .declined, .declined, .declined])
    try await replicas.settle()
    for index in 0..<3 { #expect(try await entries(proposal, on: index, in: replicas) == [.applied, .applied, .declined, .pending]) }
    try await expectConverged(reconciler, replicas)
  }

  @Test func shouldReadAwaitingUntilTheSelectedChangesArrive() async throws {
    let reconciler = try World.reconciler()
    let (writer, reader) = (try Projection.store(reconciler), try Projection.store(reconciler))
    let proposal = try ProposalFixture.proposal()
    try await World.stage(proposal, in: writer)
    try await World.apply(proposal, selected: [0, 1], in: writer)
    let lines = try await Projection.lines(of: writer)
    #expect(lines.count == 4)
    try await Projection.apply([lines[0], lines[3]], to: reader)
    #expect(try await World.entries(proposal.id, in: reader) == [.awaiting, .awaiting, .declined, .declined])
    try await Projection.apply(lines, to: reader)
    #expect(try await World.entries(proposal.id, in: reader) == [.applied, .applied, .declined, .declined])
    #expect(try await Projection.derived(reconciler, in: reader) == (try await Projection.derived(reconciler, in: writer)))
  }
}

private func store(_ index: Int, _ replicas: CausalReplicas) async -> VaultStore {
  await replicas.store(index)
}
