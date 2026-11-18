import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

/// A job as one device sees it at one moment: its status, and the attempt that holds the live lease, or else the one that started last, with its step.
public struct JobProgress: Sendable, Equatable, LeaseTimed {
  /// Nil until the job's request has arrived here.
  public let status: JobStatus?
  public let attempt: AttemptID?
  public let replica: ReplicaID?
  /// The step it runs, or the last one once it ended.
  public let step: AttemptStep?
  public let runningHere: Bool
  /// The next moment `status` changes with no write.
  public let changesAt: Date?

  init(_ snapshot: JobSnapshot?, at now: LeaseInstant, replica: ReplicaID, runningHere running: Set<AttemptID>) {
    guard let snapshot else {
      (status, attempt, self.replica, step, runningHere, changesAt) = (nil, nil, nil, nil, false, nil)
      return
    }
    let shown = snapshot.attempts.first { $0.isLive(at: now) } ?? snapshot.attempts.max { $0.start.started.millis < $1.start.started.millis }
    status = JobStatus(snapshot, at: now)
    attempt = shown?.id
    self.replica = shown?.start.replica
    step = shown?.step
    runningHere = shown.map { $0.start.replica == replica && running.contains($0.id) } ?? false
    let changes = snapshot.attempts.filter { $0.outcome == .running }.compactMap { $0.lease.flatMap { JobLease.change(expires: $0.expires, after: now) } }.min()
    changesAt = changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }
  }
}
