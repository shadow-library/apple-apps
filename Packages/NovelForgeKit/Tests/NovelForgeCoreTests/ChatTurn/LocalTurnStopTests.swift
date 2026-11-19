import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Local turn stop marks", TestTimeLimit.quick)
struct LocalTurnStopTests {
  private static let session = UUID()

  private static func begin(_ store: VaultStore, turn: UUID = UUID()) async throws -> UUID {
    let replica = store.replica
    try await store.write { transaction in
      try LocalTurnStore.begin(turn, novel: UUID(), session: session, userMessage: UUID(), replica: replica, at: Date(), in: transaction.database)
    }
    return turn
  }

  private static func mark(_ turn: UUID, in store: VaultStore) async throws -> Bool {
    try await store.write { transaction in try LocalTurnStore.markStopped(turn, at: Date(), in: transaction.database) }
  }

  private static func marks(in store: VaultStore) async throws -> Int {
    try await store.read { transaction in
      guard try transaction.database.tableExists(LocalTurnStore.stopTable) else { return 0 }
      return try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM \(LocalTurnStore.stopTable)") ?? 0
    }
  }

  @Test func shouldMarkOnlyAPendingTurnAndForgetTheMarkWhenItEnds() async throws {
    let store = try NovelForgeStore.openInMemory()
    #expect(try await Self.mark(UUID(), in: store) == false)
    let turn = try await Self.begin(store)
    #expect(try await store.localTurn(turn)?.stopped == false)
    #expect(try await Self.mark(turn, in: store))
    #expect(try await Self.mark(turn, in: store))
    #expect(try await store.localTurn(turn)?.stopped == true)
    #expect(try await store.pendingLocalTurns().map(\.stopped) == [true])
    #expect(try await Self.marks(in: store) == 1)

    #expect(try await store.endLocalTurn(turn, as: .cancelled))
    #expect(try await store.localTurn(turn)?.stopped == false)
    #expect(try await Self.marks(in: store) == 0)
    #expect(try await Self.mark(turn, in: store) == false)
    #expect(try await store.pendingChanges(limit: 100).isEmpty)
  }

  @Test func shouldForgetTheMarkOfAClearedTurnAndOfOneNoLongerStored() async throws {
    let store = try NovelForgeStore.openInMemory()
    let turn = try await Self.begin(store)
    #expect(try await Self.mark(turn, in: store))
    try await store.clearLocalTurn(turn)
    #expect(try await Self.marks(in: store) == 0)

    let orphan = UUID()
    try await store.write { transaction in
      try transaction.database.execute(sql: "INSERT INTO \(LocalTurnStore.stopTable) (turn, stopped_at) VALUES (?, 0)", arguments: [orphan])
      try ChatTurnRecords.forgetOrphans(in: transaction.database)
    }
    #expect(try await Self.marks(in: store) == 0)
  }

  @Test func shouldBeginATurnTriedAgainWithoutTheMarkItEndedWith() async throws {
    let store = try NovelForgeStore.openInMemory()
    let turn = try await Self.begin(store)
    #expect(try await store.endLocalTurn(turn, as: .cancelled))
    try await store.write { transaction in
      try transaction.database.execute(sql: "INSERT INTO \(LocalTurnStore.stopTable) (turn, stopped_at) VALUES (?, 0)", arguments: [turn])
    }
    _ = try await Self.begin(store, turn: turn)
    #expect(try await store.localTurn(turn)?.stopped == false)
    #expect(try await Self.marks(in: store) == 0)
  }

  @Test func shouldReadTurnsStoredBeforeTheStopTableExisted() async throws {
    let store = try NovelForgeStore.openInMemory()
    let turn = try await Self.begin(store)
    try await store.write { transaction in try transaction.database.execute(sql: "DROP TABLE \(LocalTurnStore.stopTable)") }
    #expect(try await store.pendingLocalTurns().map(\.id) == [turn])
    #expect(try await store.localTurn(turn)?.stopped == false)
    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: nil).pending?.stopped == false)
    #expect(try await Self.mark(turn, in: store))
    #expect(try await store.localTurn(turn)?.stopped == true)
  }
}
