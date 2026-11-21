import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore

/// apps/novel-forge-web/src/features/chapters/chapter-status.ts:11-22: a final chapter reads final whatever its review status, any other one by its review
/// status, and a draft with none reads as a draft. Deviations: finalizing (an approved chapter whose read of its Story Bible updates is still open) and the
/// generation's step on the generating chip are this app's own.
nonisolated enum ChapterStatus: Equatable, Sendable {
  case drafting
  case generating(AttemptStep?)
  case needsReview
  case contradiction
  case approved
  case finalizing
  case final
}

/// Where this copy of the app stands on running the vault's jobs.
nonisolated enum JobsHere: Equatable, Sendable {
  case running
  /// Its engine is not up yet: this device's attempts are about to be resumed.
  case starting
  /// Another copy of the app holds the vault's jobs lock.
  case elsewhere
  /// The engine could not start in this copy for another reason.
  case unavailable
}

/// What the job lines read from the runtime: where it stands, the kind of device, whether starts wait for consent, and the jobs whose stopped run here
/// `JobEngine.interruptedRuns()` last listed.
nonisolated struct JobsStanding: Equatable, Sendable {
  let here: JobsHere
  var platform = JobPlatform.current
  var consentNeeded = false
  var resumable: Set<EntityRef> = []

  static let starting = JobsStanding(here: .starting)
}

/// Another device's live run: the holder's name from the replica directory (nil while it has none), its step and when it last renewed its lease.
nonisolated struct JobElsewhere: Equatable, Sendable {
  let device: String?
  let step: AttemptStep?
  let renewed: Date?
}

/// Where a run stopped and when: with `released`, the lease was let go at `at`, so that is when the run stopped; otherwise it is when the run was last heard
/// from before its lease lapsed.
nonisolated struct JobStop: Equatable, Sendable {
  let step: AttemptStep?
  let at: Date?
  let released: Bool

  init(step: AttemptStep?, at: Date?, released: Bool) {
    self.step = step
    self.at = at
    self.released = released
  }

  /// The last attempt of a queued job, when it was left running: its lease lapsed or was released.
  init?(lapsed latest: JobLatestAttempt?) {
    guard let latest, latest.outcome == .running else { return nil }
    self.init(step: latest.step, at: latest.renewal, released: latest.isReleased)
  }
}

/// A queued job: who starts it as this device sees it, when it was asked for, and where its last attempt stopped.
nonisolated struct JobWait: Equatable, Sendable {
  enum Starter: Equatable, Sendable {
    /// This device starts it with nobody asking.
    case here
    /// This device asked for it, and only Run here starts it again.
    case you
    /// The Mac named to run jobs, by its name when the replica directory has one.
    case worker(String?)
    /// No Mac is named to run jobs, the one named retired, or this iPhone or iPad is named, which runs none.
    case noWorker
    /// The device that asked for a plan, which only it starts.
    case requester(String?)
  }

  let starter: Starter
  let requested: Date?
  let stopped: JobStop?
}

nonisolated struct ChapterJobLine: Equatable, Sendable, Identifiable {
  enum State: Equatable, Sendable {
    case runningHere(AttemptStep?)
    case resumingHere(AttemptStep?)
    case runningOnAnotherDevice(JobElsewhere)
    /// The lease is this device's, held by the other copy of the app that runs the vault's jobs.
    case runningInAnotherCopy(AttemptStep?)
    /// The lease is this device's, but no engine runs in this copy to say whose run it is.
    case startedOnThisDevice(AttemptStep?)
    case queued(JobWait)
    /// This device's run stopped with its checkpoint kept, which Resume continues.
    case interrupted(JobStop)
    case waitingForConsent
    case failed(AttemptFailure?)
  }

  enum Action: Hashable, Sendable {
    case cancel
    case runHere
    case resume
    case allow
    case tryAgain
    case retryRead
  }

  let job: EntityRef
  let kind: NovelJobKind
  let state: State
  let actions: [Action]
  var reviewKind: ChapterReviewKind?

  var id: EntityRef { job }

  var isRunning: Bool {
    switch state {
    case .runningHere, .resumingHere, .runningOnAnotherDevice, .runningInAnotherCopy, .startedOnThisDevice: true
    case .queued, .interrupted, .waitingForConsent, .failed: false
    }
  }

  /// Waiting for a device to start or resume it.
  var isQueued: Bool {
    switch state {
    case .queued, .interrupted: true
    case .runningHere, .resumingHere, .runningOnAnotherDevice, .runningInAnotherCopy, .startedOnThisDevice, .waitingForConsent, .failed: false
    }
  }

  var step: AttemptStep? {
    switch state {
    case .runningHere(let step), .resumingHere(let step), .runningInAnotherCopy(let step), .startedOnThisDevice(let step): step
    case .runningOnAnotherDevice(let elsewhere): elsewhere.step
    case .queued, .interrupted, .waitingForConsent, .failed: nil
    }
  }
}

/// The chip and the job lines of one chapter's strip (phase 8 decision 8). Run here is offered for a queued job only, which is when no attempt holds a live
/// lease and neither a success nor a cancel ended the job: what `AttemptVerdict` lets a by-hand attempt proceed on, with the engine's refusal of another
/// device's live lease. Resume is offered only for a run `JobPlacements` reads as interrupted here that the engine also lists as resumable; otherwise the
/// job reads as the queued job it also is. A lease of this device's that still reads live while the engine lists its run (an iPhone relaunched within the
/// lease, which resumes nothing) is a stopped run too, since the engine never lists a run going in this process.
nonisolated struct ChapterWorkspaceStatus: Equatable, Sendable {
  let status: ChapterStatus
  let lines: [ChapterJobLine]
  let jobsUnavailable: Bool

  init(row: ChapterRow?, board: ChapterJobBoard?, replica: ReplicaID, standing: JobsStanding) {
    self.init(row: row, jobs: board?.jobs, placements: board?.placements, replica: replica, standing: standing)
  }

  /// Without `placements` the lines name no device and give no requested time.
  init(row: ChapterRow?, jobs: Derived<[ChapterJob]>?, placements: JobPlacements?, replica: ReplicaID, standing: JobsStanding) {
    let policy = JobPlacementPolicy(platform: standing.platform, worker: placements?.worker ?? .unreadable("not read"), here: replica)
    let readable = jobs?.value ?? []
    lines = readable.compactMap { job in
      var line = Self.line(job, placement: placements?.placement(of: job.job), row: row, policy: policy, standing: standing)
      line?.reviewKind = job.reviewKind
      return line
    }
    jobsUnavailable = jobs?.isUnavailable ?? false
    status = Self.status(row: row, lines: lines)
  }

  private static func status(row: ChapterRow?, lines: [ChapterJobLine]) -> ChapterStatus {
    guard let row else { return .drafting }
    if row.stage == .final { return .final }
    switch row.review {
    case .generating?: return .generating(lines.first { $0.kind == .generate }.flatMap(\.step))
    case .needsReview?: return .needsReview
    case .contradiction?: return .contradiction
    case .approved?: return lines.contains { $0.kind == .finalizeReview && ($0.isRunning || $0.isQueued) } ? .finalizing : .approved
    case .final?: return .final
    case nil: return .drafting
    }
  }

  private static func line(_ job: ChapterJob, placement: JobPlacement?, row: ChapterRow?, policy: JobPlacementPolicy, standing: JobsStanding) -> ChapterJobLine? {
    guard case .known(let kind) = job.kind else { return nil }
    let runs = standing.here == .running
    let state: ChapterJobLine.State
    let actions: [ChapterJobLine.Action]
    switch job.status {
    case .running:
      let step = job.runner?.step
      guard job.runner?.replica == policy.here else {
        let elsewhere = JobElsewhere(device: placement?.running?.device.name, step: step, renewed: job.runner?.renewal)
        return ChapterJobLine(job: job.job, kind: kind, state: .runningOnAnotherDevice(elsewhere), actions: runs ? [.cancel] : [])
      }
      switch standing.here {
      case .running where standing.resumable.contains(job.job):
        (state, actions) = (.interrupted(JobStop(step: step, at: job.runner?.renewal, released: false)), [.resume, .cancel])
      case .running: (state, actions) = (.runningHere(step), [.cancel])
      case .starting: (state, actions) = (.resumingHere(step), [])
      case .elsewhere: (state, actions) = (.runningInAnotherCopy(step), [])
      case .unavailable: (state, actions) = (.startedOnThisDevice(step), [])
      }
    case .queued:
      if runs, let stop = resumable(job, placement: placement, standing: standing) {
        (state, actions) = (.interrupted(stop), [.resume, .cancel])
      } else {
        let wait = wait(job, kind: kind, queued: placement?.queued, policy: policy)
        if !runs {
          (state, actions) = (.queued(wait), [])
        } else if standing.consentNeeded, wait.starter == .here {
          (state, actions) = (.waitingForConsent, [.allow, .cancel])
        } else {
          (state, actions) = (.queued(wait), [.runHere, .cancel])
        }
      }
    case .failed(_, let failure):
      guard kind == .finalizeReview else { return ChapterJobLine(job: job.job, kind: kind, state: .failed(failure), actions: runs ? [.tryAgain] : []) }
      guard row?.stage != .final, row?.review == .approved else { return nil }
      (state, actions) = (.failed(failure), runs ? [.retryRead] : [])
    case .succeeded, .cancelled:
      return nil
    }
    return ChapterJobLine(job: job.job, kind: kind, state: state, actions: actions)
  }

  /// Both sides must agree: the placement reads it interrupted here and the engine lists its run; with no placement read, the engine's list decides.
  private static func resumable(_ job: ChapterJob, placement: JobPlacement?, standing: JobsStanding) -> JobStop? {
    guard standing.resumable.contains(job.job) else { return nil }
    guard let placement else { return JobStop(lapsed: job.latest) ?? JobStop(step: nil, at: nil, released: false) }
    guard case .interrupted(let interrupted) = placement else { return nil }
    let released = job.latest.map { $0.attempt == interrupted.attempt && $0.isReleased } ?? false
    return JobStop(step: interrupted.step, at: interrupted.renewal, released: released)
  }

  private static func wait(_ job: ChapterJob, kind: NovelJobKind, queued: JobQueued?, policy: JobPlacementPolicy) -> JobWait {
    let waitingFor =
      queued?.waitingFor
      ?? (kind.queuesForWorker
        ? .worker(policy.worker) : .requester(JobDevice(replica: job.requester, name: nil, isHere: job.requester == policy.here)))
    let starter = policy.waiting(for: kind, requester: job.requester, started: job.latest != nil, on: waitingFor)
    let requested = queued.map { Date(timeIntervalSince1970: Double($0.requested.wallMillis) / 1000) }
    return JobWait(starter: starter, requested: requested, stopped: JobStop(lapsed: job.latest))
  }
}

extension JobPlacement {
  nonisolated fileprivate var running: JobRunning? {
    guard case .running(let running) = self else { return nil }
    return running
  }

  nonisolated fileprivate var queued: JobQueued? {
    switch self {
    case .queued(let queued): queued
    case .interrupted(let interrupted): interrupted.queued
    case .running, .failed, .cancelled, .succeeded: nil
    }
  }
}

extension JobLatestAttempt {
  /// A released lease is written expiring at the moment it was renewed.
  nonisolated fileprivate var isReleased: Bool { leaseExpires != nil && leaseExpires == leaseRenewed }
}
