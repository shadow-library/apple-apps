import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowJobs

@Suite("JobsLocal", TestTimeLimit.quick)
struct JobsLocalTests {
  private static func run(_ id: AttemptID, replica: ReplicaID, at seconds: Int64 = 0) throws -> LocalRun {
    LocalRun(attempt: id, job: try JobFixture.key().ref, replica: replica, startedAt: JobFixture.instant(seconds).date, stop: nil)
  }

  private static func checkpoint(_ id: AttemptID, _ index: Int, _ next: String) -> LocalCheckpoint {
    LocalCheckpoint(attempt: id, index: index, next: next, state: ["text": .string("after \(index)")])
  }

  @Test func shouldReadNothingAndWriteNothingBeforeAnyRunCreatedTheTables() async throws {
    let store = try JobFixture.open()
    let id = try JobFixture.attemptID(0)
    let replica = store.replica
    let reads = try await store.read { transaction in
      (
        try JobsLocal.runs(of: replica, in: transaction.database), try JobsLocal.run(id, in: transaction.database),
        try JobsLocal.checkpoint(id, in: transaction.database)
      )
    }
    #expect(reads.0.isEmpty && reads.1 == nil && reads.2 == nil)
    let writes = try await store.write { transaction in
      (
        try JobsLocal.save(Self.checkpoint(id, 1, "expand"), at: Date(), in: transaction.database),
        try JobsLocal.markStopped(id, as: .cancelled, at: Date(), in: transaction.database), try JobsLocal.cleanup(keeping: replica, in: transaction.database)
      )
    }
    #expect(writes == (false, false, 0))
    try await store.write { transaction in try JobsLocal.forget(id, in: transaction.database) }
  }

  @Test func shouldKeepTheLatestCheckpointAndTheFirstStopMarkUntilTheRunIsForgotten() async throws {
    let store = try JobFixture.open()
    let replica = store.replica
    let id = try JobFixture.attemptID(0)
    let run = try Self.run(id, replica: replica)
    try await store.write { transaction in try JobsLocal.begin(run, checkpoint: Self.checkpoint(id, 0, "draft"), at: Date(), in: transaction.database) }
    #expect(try await store.write { transaction in try JobsLocal.save(Self.checkpoint(id, 1, "expand"), at: Date(), in: transaction.database) })
    #expect(try await store.write { transaction in try JobsLocal.markStopped(id, as: .stoodDown, at: Date(), in: transaction.database) })
    #expect(try await store.write { transaction in try JobsLocal.markStopped(id, as: .cancelled, at: Date(), in: transaction.database) })
    let read = try await store.read { transaction in (try JobsLocal.run(id, in: transaction.database), try JobsLocal.checkpoint(id, in: transaction.database)) }
    #expect(read.0?.stop == .stoodDown && read.0?.job == run.job && read.0?.replica == replica)
    #expect(read.1 == Self.checkpoint(id, 1, "expand"))
    try await store.write { transaction in try JobsLocal.forget(id, in: transaction.database) }
    #expect(try await store.read { transaction in try JobsLocal.checkpoint(id, in: transaction.database) } == nil)
    #expect(try await JobFixture.localRuns(in: store).isEmpty)
    #expect(try await store.write { transaction in try JobsLocal.save(Self.checkpoint(id, 2, "title"), at: Date(), in: transaction.database) } == false)
  }

  @Test func shouldListTheReplicasOwnRunsOldestFirstAndCleanUpTheRest() async throws {
    let store = try JobFixture.open()
    let replica = store.replica
    let ids = try (0..<3).map { try JobFixture.attemptID(Int64($0), $0) }
    let runs = [try Self.run(ids[0], replica: replica, at: 5), try Self.run(ids[1], replica: JobFixture.replica(7), at: 1), try Self.run(ids[2], replica: replica, at: 2)]
    try await store.write { transaction in
      for run in runs { try JobsLocal.begin(run, checkpoint: Self.checkpoint(run.attempt, 0, "draft"), at: Date(), in: transaction.database) }
    }
    #expect(try await JobFixture.localRuns(in: store).map(\.attempt) == [ids[2], ids[0]])
    #expect(try await store.write { transaction in try JobsLocal.cleanup(keeping: replica, in: transaction.database) } == 1)
    #expect(try await store.read { transaction in try JobsLocal.checkpoint(ids[1], in: transaction.database) } == nil)
    #expect(try await store.read { transaction in try JobsLocal.checkpoint(ids[0], in: transaction.database) } != nil)
  }

  @Test func shouldRefuseToBeginARunTwice() async throws {
    let store = try JobFixture.open()
    let id = try JobFixture.attemptID(0)
    let run = try Self.run(id, replica: store.replica)
    try await store.write { transaction in try JobsLocal.begin(run, checkpoint: Self.checkpoint(id, 0, "draft"), at: Date(), in: transaction.database) }
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try JobsLocal.begin(run, checkpoint: Self.checkpoint(id, 0, "draft"), at: Date(), in: transaction.database) }
    }
  }
}
