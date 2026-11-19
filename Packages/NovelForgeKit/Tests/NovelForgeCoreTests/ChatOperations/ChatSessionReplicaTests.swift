import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

private func makeReplicas(seed: UInt64) async throws -> CausalReplicas {
  let reconciler = try ChatWorld.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  _ = try await replicas.write(0) { transaction in
    try Library.create(NewNovel(title: "The Heir"), id: World.novel, in: &transaction)
    return try ChatSessionOperations.create(novel: World.novel, id: ChatWorld.session, in: &transaction)
  }
  try await replicas.settle()
  return replicas
}

private func on(_ index: Int, after milliseconds: Int, _ replicas: CausalReplicas, _ body: @Sendable @escaping (inout WriteTransaction) throws -> Void) async throws {
  await replicas.advanceClock(of: index, by: .milliseconds(milliseconds))
  try await replicas.write(index, body)
}

/// Every replica reads the same session record, as the third one, which wrote nothing, reads it.
private func converged(_ replicas: CausalReplicas) async throws -> RecordReading<ChatSessionRecord> {
  try await replicas.settle()
  let third = try await World.session(ChatWorld.session, in: await replicas.store(2))
  for index in 0..<2 { #expect(try await World.session(ChatWorld.session, in: await replicas.store(index)) == third) }
  return third
}

@Suite("Chat session operations across devices", TestTimeLimit.standard)
struct ChatSessionReplicaTests {
  private let session = ChatWorld.session
  private let novel = World.novel

  @Test func shouldKeepTheLaterRenameWhenTwoDevicesRenameAtOnce() async throws {
    for (first, second) in [(0, 1), (1, 0)] {
      let replicas = try await makeReplicas(seed: 0xF23B1)
      let (session, novel) = (session, novel)
      try await on(first, after: 5, replicas) { transaction in try ChatSessionOperations.rename(session, novel: novel, title: "Earlier", in: &transaction) }
      try await on(second, after: 50, replicas) { transaction in try ChatSessionOperations.rename(session, novel: novel, title: "Later", in: &transaction) }
      #expect(try await converged(replicas).entry?.record.title == "Later")
    }
  }

  @Test func shouldKeepAnArchiveAndAModeSwitchMadeOnTwoDevices() async throws {
    let replicas = try await makeReplicas(seed: 0xF23B2)
    let (session, novel) = (session, novel)
    try await on(0, after: 5, replicas) { transaction in try ChatSessionOperations.setStatus(session, novel: novel, status: .archived, in: &transaction) }
    try await on(1, after: 5, replicas) { transaction in try ChatSessionOperations.setMode(session, novel: novel, mode: .manual, in: &transaction) }
    try await on(1, after: 10, replicas) { transaction in try ChatSessionOperations.rename(session, novel: novel, title: "Heir", in: &transaction) }
    let record = try #require(try await converged(replicas).entry?.record)
    #expect(record.status == .known(.archived) && record.mode == .known(.manual) && record.title == "Heir")
  }

  @Test func shouldKeepADeletionWhateverAnotherDeviceChangedMeanwhile() async throws {
    for (deleter, editor, delay) in [(0, 1, 50), (1, 0, 50), (0, 1, 0)] {
      let replicas = try await makeReplicas(seed: 0xF23B3)
      let (session, novel) = (session, novel)
      try await on(deleter, after: 5, replicas) { transaction in try ChatSessionOperations.delete(session, novel: novel, in: &transaction) }
      try await on(editor, after: delay, replicas) { transaction in
        try ChatSessionOperations.rename(session, novel: novel, title: "Renamed", in: &transaction)
        try ChatSessionOperations.setStatus(session, novel: novel, status: .archived, in: &transaction)
      }
      let reading = try await converged(replicas)
      #expect(reading.entry?.isRemoved == true)
      #expect(try await ChatWorld.state(in: await replicas.store(2))?.record == .removed)
      #expect(try await replicas.store(2).load(ChatSessionList.self, ChatSessionListQuery(novel: novel, filter: .all)).sessions == .available([]))
    }
  }

  @Test func shouldKeepTheFirstAutomaticNameAndLetTheAuthorsTitleWinOverIt() async throws {
    let replicas = try await makeReplicas(seed: 0xF23B4)
    let (session, novel) = (session, novel)
    try await on(1, after: 5, replicas) { transaction in _ = try ChatAutoTitle.nameIfUntitled(session, novel: novel, title: "First name", in: &transaction) }
    try await on(0, after: 60, replicas) { transaction in _ = try ChatAutoTitle.nameIfUntitled(session, novel: novel, title: "Second name", in: &transaction) }
    #expect(try await converged(replicas).entry?.record.autoTitle == "First name")
    try await on(0, after: 5, replicas) { transaction in try ChatSessionOperations.rename(session, novel: novel, title: "Mine", in: &transaction) }
    #expect(try await converged(replicas).entry?.record.displayTitle == "Mine")
  }
}
