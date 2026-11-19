import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = CompactionWorld

private func makeReplicas(seed: UInt64) async throws -> (NovelForgeReconciler, CausalReplicas) {
  let reconciler = try ChatWorld.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  return (reconciler, replicas)
}

/// Compacts on one device, then hands what it wrote, the ledger and consent included, to the replicas' delivery streams.
private func compact(on index: Int, summary: String, in replicas: CausalReplicas) async throws -> ChatCompactionResult {
  let provider = ScriptedModelProvider(calls: [World.reply(summary)])
  let result = try await World.compact(store: await replicas.store(index), provider: provider)
  _ = try await replicas.write(index) { _ in }
  return result
}

private func expectEveryMessageAccountedFor(_ replicas: CausalReplicas, messages: [UUID]) async throws -> ChatConversationWindow {
  var windows = [ChatConversationWindow]()
  for index in 0..<replicas.count {
    let store = await replicas.store(index)
    let window = try await World.window(in: store)
    let covered = Set(window.summary?.record.covered ?? [])
    let windowed = Set(window.messages.map(\.record.id))
    #expect(messages.allSatisfy { covered.contains($0) || windowed.contains($0) }, "replica \(index)")
    #expect(covered.isDisjoint(with: windowed), "replica \(index)")
    windows.append(window)
  }
  #expect(windows.allSatisfy { $0.summary == windows.first?.summary })
  return windows[0]
}

@Suite("Chat compaction replicas", TestTimeLimit.standard)
struct ChatCompactionReplicaTests {
  @Test func shouldKeepTheWiderOfTwoConcurrentFoldsAndLeaveTheOtherDevicesMessagesInTheWindow() async throws {
    let (reconciler, replicas) = try await makeReplicas(seed: 0xF21A1)
    let prior = try ChatWorld.summary(covering: [World.id(90), World.id(91)])
    let turns = try World.turns(13)
    _ = try await replicas.write(0) { transaction in
      _ = try ChatSessionRecord(id: ChatWorld.session, novel: ChatWorld.novel).create(in: &transaction)
      for message in turns { _ = try message.append(in: &transaction) }
      _ = try prior.append(in: &transaction)
    }
    try await replicas.settle()
    let late = try World.turns(1, from: 14)
    _ = try await replicas.write(1) { transaction in _ = try late[0].append(in: &transaction) }

    let first = try await compact(on: 0, summary: "Device zero folded seven.", in: replicas)
    let second = try await compact(on: 1, summary: "Device one folded eight.", in: replicas)
    guard case .folded(let narrow, _, _) = first.outcome, case .folded(let wide, _, _) = second.outcome else {
      Issue.record("expected two folds, got \(first.outcome) and \(second.outcome)")
      return
    }
    try await replicas.settle()

    let window = try await expectEveryMessageAccountedFor(replicas, messages: (turns + late).map(\.id))
    #expect(window.summary?.record.id == wide)
    #expect(window.summary?.record.covered == [World.id(90), World.id(91)] + (1...8).map(World.id))
    #expect(window.messages.map(\.record.id) == (9...14).map(World.id))
    let both = try await World.summaries(in: await replicas.store(2))
    #expect(Set(both.map(\.id)) == [prior.id, narrow, wide])
    #expect(both.allSatisfy { Set($0.covered).isSuperset(of: prior.covered) })
    for index in 0..<replicas.count {
      let comparison = try await Projection.compare(reconciler, in: await replicas.store(index))
      #expect(comparison.incremental == comparison.rebuilt)
    }
  }

  @Test func shouldStandOnOneOfTwoEqualFoldsOnEveryDevice() async throws {
    let (_, replicas) = try await makeReplicas(seed: 0xF21A2)
    let turns = try World.turns(13)
    _ = try await replicas.write(0) { transaction in
      _ = try ChatSessionRecord(id: ChatWorld.session, novel: ChatWorld.novel).create(in: &transaction)
      for message in turns { _ = try message.append(in: &transaction) }
    }
    try await replicas.settle()
    _ = try await compact(on: 0, summary: "Zero.", in: replicas)
    _ = try await compact(on: 1, summary: "One.", in: replicas)
    try await replicas.settle()
    let window = try await expectEveryMessageAccountedFor(replicas, messages: turns.map(\.id))
    #expect(window.summary?.record.covered == (1...7).map(World.id))
    #expect(window.messages.map(\.record.id) == (8...13).map(World.id))
  }

  @Test func shouldNeverCoverLessThanTheSummaryAFoldBuiltOn() async throws {
    let (_, replicas) = try await makeReplicas(seed: 0xF21A3)
    let turns = try World.turns(13)
    _ = try await replicas.write(0) { transaction in
      _ = try ChatSessionRecord(id: ChatWorld.session, novel: ChatWorld.novel).create(in: &transaction)
      for message in turns { _ = try message.append(in: &transaction) }
    }
    try await replicas.settle()
    _ = try await compact(on: 0, summary: "First fold.", in: replicas)
    try await replicas.settle()
    let more = try World.turns(7, from: 14)
    _ = try await replicas.write(1) { transaction in for message in more { _ = try message.append(in: &transaction) } }
    let second = try await compact(on: 1, summary: "Second fold.", in: replicas)
    try await replicas.settle()
    let window = try await expectEveryMessageAccountedFor(replicas, messages: (turns + more).map(\.id))
    guard case .folded(let id, _, _) = second.outcome else {
      Issue.record("expected a second fold, got \(second.outcome)")
      return
    }
    #expect(window.summary?.record.id == id)
    #expect(window.summary?.record.covered == (1...14).map(World.id))
    #expect(window.summary.map { $0.record.text } == "Second fold.")
  }
}
