import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

/// Who the author names to run the vault's queued jobs.
public enum WorkerChoice: Sendable, Hashable {
  case thisReplica
  case none
}

extension JobEngine {
  /// Naming the replica already named keeps its `since`; `since` is this engine's lease clock, so the trusted clock when the app passes one.
  @concurrent
  @discardableResult
  public func designateWorker(_ choice: WorkerChoice) async throws(JobEngineError) -> VaultWorker {
    let (replica, now) = (store.replica, clock.now())
    _ = try await engineWrite { transaction in try WorkerRecords.designate(choice == .thisReplica ? replica : nil, at: now, in: &transaction) }
    return try await worker()
  }

  @concurrent
  public func worker() async throws(JobEngineError) -> VaultWorker {
    let replica = store.replica
    return try await engineRead { transaction in try JobDevices(here: replica, in: transaction).worker(in: transaction) }
  }

  /// Read again after every commit, local or remote.
  public func observeWorker() -> AsyncThrowingStream<VaultWorker, any Error> {
    let replica = store.replica
    return store.observeReads { transaction in try JobDevices(here: replica, in: transaction).worker(in: transaction) }
  }
}
