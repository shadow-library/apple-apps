import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

nonisolated enum JobPlatform: Sendable, Hashable {
  /// iPhone and iPad: the system suspends a run soon after the app leaves the screen.
  case phone
  case mac

  static var current: JobPlatform {
    #if os(macOS)
      .mac
    #else
      .phone
    #endif
  }
}

/// Who starts a job with nobody asking (phase 8 decision 1). A plan runs on the device that asked for it. The other kinds queue for the vault's worker, which
/// only a Mac can be and which drains `WorkerBacklog`; a Mac that is not the worker runs its own requests; an iPhone or iPad starts none of them, even when
/// the worker record names it, and offers Run here.
nonisolated struct JobPlacementPolicy: Sendable, Hashable {
  let platform: JobPlatform
  let worker: VaultWorker
  let here: ReplicaID

  var drainsWorkerBacklog: Bool { platform == .mac && worker.isHere }

  /// Whether a job of `kind` this device asks for starts here as it is asked for, or is only requested and left to the device that runs it: a Mac, worker or
  /// not, starts every kind; an iPhone or iPad starts only a plan.
  static func startsWhenAsked(_ kind: NovelJobKind, on platform: JobPlatform) -> Bool {
    !kind.queuesForWorker || platform == .mac
  }

  /// Whether this device starts its own request of `kind` from `JobBacklog`; the worker takes its own requests of worker kinds from `WorkerBacklog`.
  func startsOwnRequest(of kind: NovelJobKind) -> Bool {
    guard kind.queuesForWorker else { return true }
    return platform == .mac && !drainsWorkerBacklog
  }

  /// `started` is whether any attempt of the job began: `JobBacklog` holds only jobs no attempt started, `WorkerBacklog` also those whose lease lapsed.
  func startsAutomatically(_ kind: NovelJobKind, requester: ReplicaID, started: Bool) -> Bool {
    if kind.queuesForWorker, drainsWorkerBacklog { return true }
    return requester == here && !started && startsOwnRequest(of: kind)
  }

  /// Who a queued job waits for, as this device should say it.
  func waiting(for kind: NovelJobKind, requester: ReplicaID, started: Bool, on waitingFor: JobWaitingFor) -> JobWait.Starter {
    if startsAutomatically(kind, requester: requester, started: started) { return .here }
    switch waitingFor {
    case .requester(let device): return device.isHere ? .you : .requester(device.name)
    case .worker(.named(let device)): return device.isHere ? .noWorker : .worker(device.name)
    case .worker(.none), .worker(.retired): return .noWorker
    case .worker(.unreadable): return .worker(nil)
    }
  }
}

/// What the runtime drains: the jobs this device starts on its own, in order, with the consent it waits for and the next moment a lapsing lease changes the
/// list with no write.
nonisolated struct JobQueue: Equatable, Sendable {
  let jobs: [EntityRef]
  let worker: VaultWorker
  /// Whether the consent the runtime waits for has been given since; nil while it waits for none.
  let consented: Bool?
  let changesAt: Date?

  init(replica: ReplicaID, platform: JobPlatform, now: LeaseInstant, waiting: AIConsentRequest?, in transaction: ReadTransaction) throws {
    let backlog = try WorkerBacklog.load(WorkerBacklogQuery(replica: replica, now: now), in: transaction)
    let policy = JobPlacementPolicy(platform: platform, worker: backlog.worker, here: replica)
    let own = try (JobBacklog.load(replica, in: transaction).jobs.value ?? []).filter { job in
      guard let kind = try Self.kind(of: job, in: transaction) else { return false }
      return policy.startsOwnRequest(of: kind)
    }
    let vault = policy.drainsWorkerBacklog ? (backlog.jobs.value ?? []).map(\.job).filter { !own.contains($0) } : []
    jobs = own + vault
    worker = backlog.worker
    changesAt = policy.drainsWorkerBacklog ? backlog.changesAt : nil
    consented = try waiting.map { try AIConsent.isGranted(provider: $0.host, dataClass: $0.dataClass, currentSummary: $0.disclosure, in: transaction) }
  }

  private static func kind(of job: EntityRef, in transaction: ReadTransaction) throws(JobRecordError) -> NovelJobKind? {
    try JobRecords.read(job, in: transaction).record.flatMap { NovelJobKind(rawValue: $0.request.key.kind) }
  }
}
