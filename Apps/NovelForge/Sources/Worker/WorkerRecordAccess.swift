#if os(macOS)
  import Foundation
  import NovelForgeCore
  import ShadowCore

  /// The open vault's worker record as this Mac reads and writes it: its `JobEngine`, or a fake in tests.
  nonisolated protocol WorkerRecordAccess: Sendable {
    /// Which vault, and which copy of the engine on it, this access writes to.
    var identity: ObjectIdentifier { get }
    var replica: ReplicaID { get }
    func designate(_ choice: WorkerChoice) async throws(JobEngineError) -> VaultWorker
    func worker() async throws(JobEngineError) -> VaultWorker
    func observeWorker() -> AsyncThrowingStream<VaultWorker, any Error>
  }

  nonisolated struct EngineWorkerAccess: WorkerRecordAccess {
    let engine: JobEngine
    let replica: ReplicaID

    var identity: ObjectIdentifier { ObjectIdentifier(engine) }

    func designate(_ choice: WorkerChoice) async throws(JobEngineError) -> VaultWorker {
      try await engine.designateWorker(choice)
    }

    func worker() async throws(JobEngineError) -> VaultWorker {
      try await engine.worker()
    }

    func observeWorker() -> AsyncThrowingStream<VaultWorker, any Error> {
      engine.observeWorker()
    }
  }

  /// Worker mode as this Mac keeps it in the user defaults. `replica` is the replica it was turned on as, none while it is off: a replica, not a flag, so
  /// a library opened in place of the one it was turned on for is never named on its own. `clearPending` is the replica it was turned off as while the
  /// vault's record could not be written, which the next vault attached clears.
  struct WorkerPreference {
    static let replicaKey = "com.shadow.apps.novelforge.worker.replica"
    static let clearPendingKey = "com.shadow.apps.novelforge.worker.clear-pending"

    let defaults: UserDefaults

    var replica: ReplicaID? { read(Self.replicaKey) }
    var clearPending: ReplicaID? { read(Self.clearPendingKey) }

    func save(_ replica: ReplicaID?) {
      write(replica, Self.replicaKey)
    }

    func saveClearPending(_ replica: ReplicaID?) {
      write(replica, Self.clearPendingKey)
    }

    private func read(_ key: String) -> ReplicaID? {
      defaults.string(forKey: key).flatMap(ReplicaID.init)
    }

    private func write(_ replica: ReplicaID?, _ key: String) {
      guard let replica else { return defaults.removeObject(forKey: key) }
      defaults.set(replica.description, forKey: key)
    }
  }
#endif
