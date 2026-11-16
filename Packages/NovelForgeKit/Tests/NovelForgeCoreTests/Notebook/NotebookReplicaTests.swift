import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

private func makeReplicas(_ reconciler: NovelForgeReconciler, seed: UInt64) async throws -> CausalReplicas {
  try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
}

private func states(_ index: Int, in replicas: CausalReplicas) async throws -> [UUID: NotebookEntryState] {
  let rows = try await Projection.fetch(NotebookEntryStateDerivation.request(for: Fixture.novel), in: await replicas.store(index))
  return Dictionary(uniqueKeysWithValues: rows.map { ($0.entry, $0.state) })
}

private func expectAgreement(on expected: [UUID: NotebookEntryState], in replicas: CausalReplicas) async throws {
  for index in 0..<replicas.count { #expect(try await states(index, in: replicas) == expected) }
}

private struct Scene {
  let replicas: CausalReplicas
  let old: NotebookEntryRecord

  init(seed: UInt64) async throws {
    let replicas = try await makeReplicas(try Projection.reconciler(), seed: seed)
    let old = NotebookEntryRecord(novel: Fixture.novel, entryKind: .known(.decision), topic: "premise", statement: "Old")
    _ = try await replicas.write(0) { transaction in try NovelRecord(id: Fixture.novel, name: "Ember").create(in: &transaction) }
    _ = try await replicas.write(0) { transaction in try old.append(in: &transaction) }
    try await replicas.settle()
    self.replicas = replicas
    self.old = old
  }

  func supersede(on index: Int, _ statement: String) async throws -> NotebookEntryRecord {
    let old = old
    return try await replicas.write(index) { transaction in
      let entry = NotebookEntryRecord(novel: Fixture.novel, entryKind: .known(.decision), topic: old.topic, statement: statement, supersedes: old.id)
      _ = try entry.append(in: &transaction)
      return entry
    }
  }

  func withdraw(on index: Int) async throws -> NotebookWithdrawalRecord {
    let old = old
    return try await replicas.write(index) { transaction in
      let withdrawal = NotebookWithdrawalRecord(novel: Fixture.novel, entry: old.id, reason: "Dropped")
      _ = try withdrawal.append(in: &transaction)
      return withdrawal
    }
  }
}

@Suite("Notebook replicas", .timeLimit(.minutes(2)))
struct NotebookReplicaTests {
  @Test func shouldMakeTheLaterClockTheSuccessorWhenTwoDevicesSupersedeTheSameEntry() async throws {
    try await forAll(iterations: 6, seed: 0xD17A) { generator in
      let scene = try await Scene(seed: generator.next())
      let (early, late) = (generator.int(in: 0...2), generator.int(in: 0...2))
      let first = try await scene.supersede(on: early, "From \(early)")
      await scene.replicas.advanceClock(of: late, by: .seconds(30))
      let second = try await scene.supersede(on: late, "From \(late)")
      try await scene.replicas.settle()
      try await expectAgreement(
        on: [scene.old.id: NotebookEntryState(successor: second.id, withdrawal: nil), first.id: NotebookEntryState(successor: second.id, withdrawal: nil), second.id: .active],
        in: scene.replicas)
    }
  }

  @Test func shouldKeepTheLatestOfThreeConcurrentSupersedesActive() async throws {
    let scene = try await Scene(seed: 0xD17B)
    var written = [NotebookEntryRecord]()
    for index in 0..<3 {
      await scene.replicas.advanceClock(of: index, by: .seconds(Int64(10 * (index + 1))))
      written.append(try await scene.supersede(on: index, "From \(index)"))
    }
    try await scene.replicas.settle()
    let successor = NotebookEntryState(successor: written[2].id, withdrawal: nil)
    try await expectAgreement(on: [scene.old.id: successor, written[0].id: successor, written[1].id: successor, written[2].id: .active], in: scene.replicas)
  }

  @Test func shouldLabelAnEntryWithdrawnOnOneDeviceAndSupersededOnAnotherAsWithdrawnAndKeepTheRewriteActive() async throws {
    let scene = try await Scene(seed: 0xD17C)
    let rewrite = try await scene.supersede(on: 1, "Reworded")
    await scene.replicas.advanceClock(of: 2, by: .seconds(5))
    let withdrawal = try await scene.withdraw(on: 2)
    try await scene.replicas.settle()
    try await expectAgreement(on: [scene.old.id: NotebookEntryState(successor: rewrite.id, withdrawal: withdrawal.id), rewrite.id: .active], in: scene.replicas)
  }

  @Test func shouldAgreeOnTheEarliestOfTwoWithdrawalsOfTheSameEntry() async throws {
    let scene = try await Scene(seed: 0xD17D)
    let first = try await scene.withdraw(on: 1)
    await scene.replicas.advanceClock(of: 2, by: .seconds(5))
    _ = try await scene.withdraw(on: 2)
    try await scene.replicas.settle()
    try await expectAgreement(on: [scene.old.id: NotebookEntryState(successor: nil, withdrawal: first.id)], in: scene.replicas)
  }

  @Test func shouldSupersedeAWithdrawnEntryWithoutBringingItBack() async throws {
    let scene = try await Scene(seed: 0xD17E)
    let withdrawal = try await scene.withdraw(on: 0)
    try await scene.replicas.settle()
    let rewrite = try await scene.supersede(on: 1, "Late rewrite")
    try await scene.replicas.settle()
    try await expectAgreement(on: [scene.old.id: NotebookEntryState(successor: rewrite.id, withdrawal: withdrawal.id), rewrite.id: .active], in: scene.replicas)
  }
}
