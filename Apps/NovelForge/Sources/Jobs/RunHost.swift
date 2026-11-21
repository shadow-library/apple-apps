import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore

/// A run going on this device, handed to the `JobRunHost` once it has started or resumed here.
nonisolated struct HostedJobRun: Sendable {
  let job: EntityRef
  let attempt: AttemptID
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
}

extension JobRunHost {
  func sceneEnteredBackground() {}
  func sceneBecameActive() {}
}

/// Runs go on only while the app is in front; a run the system suspends keeps its lease until it lapses, and the checkpoint stays for Resume.
struct ForegroundRunHost: JobRunHost {
  func host(_ run: HostedJobRun) {}
}
