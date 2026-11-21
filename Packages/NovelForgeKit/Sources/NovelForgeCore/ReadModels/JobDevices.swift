import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSync

/// A replica as the replica directory names it; `name` is nil while its directory entry has not arrived or carries neither a name nor a platform.
public struct JobDevice: Sendable, Hashable {
  public let replica: ReplicaID
  public let name: String?
  public let isHere: Bool

  public init(replica: ReplicaID, name: String?, isHere: Bool) {
    self.replica = replica
    self.name = name
    self.isHere = isHere
  }
}

/// The vault's worker as this replica reads it at one moment, a retired replica followed to its successor. Two replicas may each read themselves as the
/// worker until the later designation reaches both; `AttemptVerdict` stands one of their attempts down.
public enum VaultWorker: Sendable, Hashable {
  /// No worker record yet, or one that names none.
  case none
  case unreadable(String)
  /// The replica the chain of successors ends at retired with no successor, or the chain loops.
  case retired(ReplicaID)
  case named(JobDevice)

  public var device: JobDevice? {
    guard case .named(let device) = self else { return nil }
    return device
  }

  public var isHere: Bool { device?.isHere == true }
}

struct JobDevices {
  let here: ReplicaID
  let directory: ReplicaDirectory

  init(here: ReplicaID, in transaction: ReadTransaction) throws(StoreError) {
    self.here = here
    directory = try ReplicaDirectory.read(in: transaction)
  }

  func device(_ replica: ReplicaID) -> JobDevice {
    let entry = directory.entry(for: replica)
    let name = [entry?.name, entry?.platform].compactMap { $0 }.first { !$0.isEmpty }
    return JobDevice(replica: replica, name: name, isHere: replica == here)
  }

  func worker(in transaction: ReadTransaction) throws(StoreError) -> VaultWorker {
    switch WorkerRecords.reading(try transaction.state(of: WorkerRecords.ref)) {
    case .absent: return .none
    case .unreadable(let reason): return .unreadable(reason)
    case .readable(let record):
      guard let replica = record.replica else { return .none }
      return worker(following: replica)
    }
  }

  func worker(following replica: ReplicaID) -> VaultWorker {
    var current = replica
    var seen: Set = [replica]
    while let entry = directory.entry(for: current), entry.state == .retired {
      guard let successor = entry.successor, seen.insert(successor).inserted else { return .retired(current) }
      current = successor
    }
    return .named(device(current))
  }
}
