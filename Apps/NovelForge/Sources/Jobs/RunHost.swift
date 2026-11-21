import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore

/// Whether a person's action started the run here: a tap, or the drain starting a job asked for since this runtime launched or once consent was given.
/// Apple lets only such a run carry on in the background through continued processing.
nonisolated enum JobRunOrigin: Sendable, Equatable {
  case person
  /// Started with no one asking just now, such as a job queued before launch or a run resumed at launch.
  case automatic
}

/// A run going on this device, handed to the `JobRunHost` once it has started or resumed here.
nonisolated struct HostedJobRun: Sendable {
  let job: EntityRef
  let attempt: AttemptID
  /// The job's kind, novel and chapter as its record names them; nil when the record cannot be read.
  let target: NovelJobTarget?
  let origin: JobRunOrigin
  /// From the run's current progress until it ends (`JobEngine.observeRun`).
  let progress: AsyncStream<JobRunProgress>
  /// Ends the run here as a crash would and releases its lease, so another device may take it over at once; the checkpoint stays for Resume.
  let interrupt: @Sendable () async throws(JobEngineError) -> JobInterruption
  /// Once the run has ended, how it ended.
  let finished: @Sendable () async -> AttemptResult
}

/// Where a run started here goes on once the app leaves the screen: continued processing on iPhone and iPad, the foreground otherwise. The runtime hands the
/// host every run it follows and tells it when the scene goes to the background and comes back. A system task's expiration handler awaits
/// `HostedJobRun.interrupt` with a deadline inside its grace period, then completes the task whether or not the interrupt returned.
@MainActor
protocol JobRunHost {
  func host(_ run: HostedJobRun)
  func sceneEnteredBackground()
  func sceneBecameActive()
  /// True while a run of the job goes on here only as long as the app stays open, because the system gave it no background time.
  func needsAppOpen(for job: EntityRef) -> Bool
}

extension JobRunHost {
  func sceneEnteredBackground() {}
  func sceneBecameActive() {}
  func needsAppOpen(for job: EntityRef) -> Bool { false }
}

/// Runs go on only while the app is in front; a run the system suspends keeps its lease until it lapses, and the checkpoint stays for Resume.
struct ForegroundRunHost: JobRunHost {
  func host(_ run: HostedJobRun) {}
}
