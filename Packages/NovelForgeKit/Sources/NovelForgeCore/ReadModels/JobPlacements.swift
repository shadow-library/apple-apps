import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct JobPlacementQuery: Sendable, Hashable {
  public let jobs: [EntityRef]
  public let replica: ReplicaID
  public let now: LeaseInstant

  public init(jobs: [EntityRef], replica: ReplicaID, now: LeaseInstant) {
    self.jobs = jobs
    self.replica = replica
    self.now = now
  }
}

public struct JobRunning: Sendable, Equatable {
  public let attempt: AttemptID
  public let device: JobDevice
  public let step: AttemptStep?
  public let renewal: Date
  public let expiry: Date
}

public enum JobWaitingFor: Sendable, Equatable {
  /// A plan, or a kind this build does not know: only the device that asked for it starts it.
  case requester(JobDevice)
  case worker(VaultWorker)
}

public struct JobQueued: Sendable, Equatable {
  public let waitingFor: JobWaitingFor
  public let requested: HLCTimestamp
  /// The attempt that started last, nil while none has: the step and renewal of a run whose lease lapsed.
  public let latest: JobLatestAttempt?
}

/// A run of this replica whose lease lapsed or was released with nothing live since; until it resumes, the job is also queued as `queued` says.
public struct JobInterrupted: Sendable, Equatable {
  public let attempt: AttemptID
  public let step: AttemptStep?
  public let renewal: Date
  public let queued: JobQueued
}

/// Where a job stands for this replica at one moment, ranked as `JobStatus` ranks.
public enum JobPlacement: Sendable, Equatable {
  case running(JobRunning)
  case queued(JobQueued)
  case interrupted(JobInterrupted)
  case failed(AttemptID, AttemptFailure?)
  case cancelled
  case succeeded(AttemptID)
}

/// The placement of each job asked for whose request is readable; a job whose request has not arrived is left out. Liveness is read against `now` and
/// never stored, so a screen re-reads at `changesAt`; whether a start may go ahead is still decided by the engine from `JobSnapshot`.
public struct JobPlacements: ReadModel {
  public let placements: Derived<[EntityRef: JobPlacement]>
  public let worker: VaultWorker
  public let changesAt: Date?
  public let faults: [ReadFault]

  private static let tables = [JobEntry.databaseTableName]

  public func placement(of job: EntityRef) -> JobPlacement? { placements.value?[job] }

  public static func load(_ query: JobPlacementQuery, in transaction: ReadTransaction) throws(StoreError) -> JobPlacements {
    let report = try ReadFaults(novel: nil, reading: tables, in: transaction)
    let devices = try JobDevices(here: query.replica, in: transaction)
    let worker = try devices.worker(in: transaction)
    let keys = query.jobs.filter { $0.kind == JobSchema.jobKind }.map(\.key.rawValue)
    var changes: Int64?
    let placements = try report.section(tables) { () throws(StoreError) in
      let entries = try transaction.query { database in try JobEntry.filter(keys.contains(Column("job"))).fetchAll(database) }
      changes = entries.compactMap { $0.standing.changes(after: query.now) }.min()
      return Dictionary(entries.map { ($0.ref, placement(of: $0, devices: devices, worker: worker, at: query.now)) }) { first, _ in first }
    }
    return JobPlacements(
      placements: placements, worker: worker, changesAt: changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }, faults: report.relevant)
  }

  static func placement(of entry: JobEntry, devices: JobDevices, worker: VaultWorker, at now: LeaseInstant) -> JobPlacement {
    switch entry.status(at: now) {
    case .succeeded(let attempt): return .succeeded(attempt)
    case .cancelled: return .cancelled
    case .failed(let attempt, let failure): return .failed(attempt, failure)
    case .running, .queued: break
    }
    if let holder = entry.standing.holder(at: now) {
      return .running(JobRunning(attempt: holder.attempt, device: devices.device(holder.replica), step: holder.step, renewal: holder.renewal, expiry: holder.expiry))
    }
    let queued = queued(entry, devices: devices, worker: worker)
    guard let here = entry.standing.holders.last(where: { $0.replica == devices.here }) else { return .queued(queued) }
    return .interrupted(JobInterrupted(attempt: here.attempt, step: here.step, renewal: here.renewal, queued: queued))
  }

  private static func queued(_ entry: JobEntry, devices: JobDevices, worker: VaultWorker) -> JobQueued {
    let waitingFor: JobWaitingFor =
      switch entry.jobKind {
      case .known(let kind) where kind.queuesForWorker: .worker(worker)
      case .known, .unknown: .requester(devices.device(entry.requester))
      }
    return JobQueued(waitingFor: waitingFor, requested: entry.requested, latest: entry.latest)
  }
}
