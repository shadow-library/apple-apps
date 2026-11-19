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

nonisolated struct ChapterJobLine: Equatable, Sendable, Identifiable {
  enum State: Equatable, Sendable {
    case runningHere(AttemptStep?)
    case resumingHere(AttemptStep?)
    case runningOnAnotherDevice(AttemptStep?)
    /// The lease is this device's, held by the other copy of the app that runs the vault's jobs.
    case runningInAnotherCopy(AttemptStep?)
    /// The lease is this device's, but no engine runs in this copy to say whose run it is.
    case startedOnThisDevice(AttemptStep?)
    case queued
    case waitingForConsent
    case failed(AttemptFailure?)
  }

  enum Action: Hashable, Sendable {
    case cancel
    case runHere
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
    case .queued, .waitingForConsent, .failed: false
    }
  }

  var step: AttemptStep? {
    switch state {
    case .runningHere(let step), .resumingHere(let step), .runningOnAnotherDevice(let step), .runningInAnotherCopy(let step), .startedOnThisDevice(let step): step
    case .queued, .waitingForConsent, .failed: nil
    }
  }
}

/// The chip and the job lines of one chapter's strip. Run here is offered for a queued job only, which is when no attempt holds a live lease and neither a
/// success nor a cancel ended the job: what `AttemptVerdict` lets a by-hand attempt proceed on, with the engine's refusal of another device's live lease.
nonisolated struct ChapterWorkspaceStatus: Equatable, Sendable {
  let status: ChapterStatus
  let lines: [ChapterJobLine]
  let jobsUnavailable: Bool

  init(row: ChapterRow?, jobs: Derived<[ChapterJob]>?, replica: ReplicaID, here: JobsHere, consentNeeded: Bool = false) {
    let readable = jobs?.value ?? []
    lines = readable.compactMap { job in
      var line = Self.line(job, row: row, replica: replica, here: here, consentNeeded: consentNeeded)
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
    case .approved?: return lines.contains { $0.kind == .finalizeReview && ($0.isRunning || $0.state == .queued) } ? .finalizing : .approved
    case .final?: return .final
    case nil: return .drafting
    }
  }

  private static func line(_ job: ChapterJob, row: ChapterRow?, replica: ReplicaID, here: JobsHere, consentNeeded: Bool) -> ChapterJobLine? {
    guard case .known(let kind) = job.kind else { return nil }
    let runs = here == .running
    let state: ChapterJobLine.State
    let actions: [ChapterJobLine.Action]
    switch job.status {
    case .running:
      let step = job.runner?.step
      guard job.runner?.replica == replica else {
        return ChapterJobLine(job: job.job, kind: kind, state: .runningOnAnotherDevice(step), actions: runs ? [.cancel] : [])
      }
      switch here {
      case .running: (state, actions) = (.runningHere(step), [.cancel])
      case .starting: (state, actions) = (.resumingHere(step), [])
      case .elsewhere: (state, actions) = (.runningInAnotherCopy(step), [])
      case .unavailable: (state, actions) = (.startedOnThisDevice(step), [])
      }
    case .queued:
      if !runs {
        (state, actions) = (.queued, [])
      } else if consentNeeded {
        (state, actions) = (.waitingForConsent, [.allow, .cancel])
      } else {
        (state, actions) = (.queued, [.runHere, .cancel])
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
}
