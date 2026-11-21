import Foundation
import NovelForgeCore
import OSLog
import Observation
import ShadowJobs
import ShadowStore
import Synchronization

/// Hands every run a person started here to a continued-processing task, so it goes on after the app leaves the screen. The request is submitted as soon as
/// the run is hosted, right after the tap that started it: Apple requires the submission to come from the foreground as a result of a person's action, so
/// leaving the screen submits nothing and an automatic run is never submitted. An automatic run, or one whose request was refused, goes on while the app is
/// open, and its line asks the person to keep the app open. When the
/// task expires (the system's expiry or the person's cancel in the system UI, which the app cannot tell apart) the run is interrupted, which releases its
/// lease and keeps its checkpoint for Resume, and the task completes once the interrupt returns or the deadline passes.
@MainActor
@Observable
final class ContinuedProcessingHost: JobRunHost {
  static let identifierPrefix = "com.shadow.apps.novelforge.job."
  static let wildcard = identifierPrefix + "*"

  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "jobs")

  /// The jobs whose run here has no background time and goes on only while the app is open.
  private(set) var appOpenJobs: Set<EntityRef> = []
  @ObservationIgnored private let scheduler: any ContinuedProcessingScheduler
  @ObservationIgnored private let interruptDeadline: Duration
  @ObservationIgnored private var runs: [String: Hosted] = [:]

  init(scheduler: any ContinuedProcessingScheduler, interruptDeadline: Duration = .seconds(5)) {
    self.scheduler = scheduler
    self.interruptDeadline = interruptDeadline
    scheduler.register(Self.wildcard) { [weak self] task in
      guard let self else {
        task.onExpiration {}
        task.complete(success: false)
        return
      }
      self.launched(task)
    }
  }

  static func identifier(of attempt: AttemptID) -> String {
    identifierPrefix + attempt.uuid.uuidString.lowercased()
  }

  /// A run resumed under the same attempt takes the identifier over; the task of the run before it still completes through its own record.
  func host(_ run: HostedJobRun) {
    let hosted = Hosted(run: run, identifier: Self.identifier(of: run.attempt))
    runs[hosted.identifier] = hosted
    Task { [weak self] in
      let result = await run.finished()
      self?.finished(hosted, result)
    }
    guard run.origin == .person else {
      hosted.phase = .appOpen
      return refreshAppOpenJobs()
    }
    Task { [weak self] in
      for await progress in run.progress { self?.progressed(hosted, progress) }
    }
    Task { [weak self] in await self?.submit(hosted) }
  }

  func needsAppOpen(for job: EntityRef) -> Bool {
    appOpenJobs.contains(job)
  }

  /// The attempt's run as hosted here; nil once its task completed or, with no task, once it ended.
  func state(of attempt: AttemptID) -> HostedRunState? {
    runs[Self.identifier(of: attempt)].map { HostedRunState(phase: $0.phase.name, ended: $0.result != nil) }
  }

  private func submit(_ hosted: Hosted) async {
    guard hosted.result == nil else { return forget(hosted) }
    let (target, step) = (hosted.run.target, hosted.latest?.step)
    let request = ContinuedProcessingRequest(
      identifier: hosted.identifier, title: ContinuedProcessingText.title(target), subtitle: ContinuedProcessingText.subtitle(target, step: step))
    do throws(ContinuedProcessingRefusal) {
      try await scheduler.submit(request)
      if case .submitting = hosted.phase { hosted.phase = .awaitingLaunch }
    } catch {
      Self.logger.notice("A job run here was refused background time reason=\(String(describing: error), privacy: .public)")
      guard case .submitting = hosted.phase else { return }
      hosted.phase = .appOpen
      if hosted.result != nil { forget(hosted) }
      refreshAppOpenJobs()
    }
  }

  /// A launch can arrive before the submission returns. One for no run hosted here, or for a run whose task already started, completes at once.
  private func launched(_ task: any ContinuedProcessingTask) {
    guard let hosted = runs[task.identifier], hosted.awaitsLaunch else {
      task.onExpiration {}
      task.complete(success: false)
      return
    }
    hosted.phase = .running(task)
    task.onExpiration { [weak self] in self?.expired(hosted) }
    report(hosted, to: task)
    if let result = hosted.result { complete(hosted, success: result.succeeded) }
  }

  private func progressed(_ hosted: Hosted, _ progress: JobRunProgress) {
    hosted.latest = progress
    if case .running(let task) = hosted.phase { report(hosted, to: task) }
  }

  private func report(_ hosted: Hosted, to task: any ContinuedProcessingTask) {
    if let latest = hosted.latest { hosted.units = hosted.units.advanced(by: latest) }
    task.report(hosted.units)
    let shown = Shown(title: ContinuedProcessingText.title(hosted.run.target), subtitle: ContinuedProcessingText.subtitle(hosted.run.target, step: hosted.latest?.step))
    guard shown != hosted.shown else { return }
    hosted.shown = shown
    task.update(title: shown.title, subtitle: shown.subtitle)
  }

  /// A run that ends before its task starts is completed when the task starts.
  private func finished(_ hosted: Hosted, _ result: AttemptResult) {
    hosted.result = result
    switch hosted.phase {
    case .running: complete(hosted, success: result.succeeded)
    case .appOpen, .completed: forget(hosted)
    case .submitting, .awaitingLaunch: return
    }
  }

  private func expired(_ hosted: Hosted) {
    guard case .running = hosted.phase else { return }
    Self.logger.notice("A job run's background time ended")
    let (run, deadline) = (hosted.run, interruptDeadline)
    Task {
      await Self.interrupt(run, within: deadline)
      complete(hosted, success: false)
    }
  }

  private func complete(_ hosted: Hosted, success: Bool) {
    guard case .running(let task) = hosted.phase else { return }
    if success { task.report(hosted.units.finished) }
    task.complete(success: success)
    hosted.phase = .completed
    forget(hosted)
  }

  private func forget(_ hosted: Hosted) {
    if runs[hosted.identifier] === hosted { runs[hosted.identifier] = nil }
    refreshAppOpenJobs()
  }

  private func refreshAppOpenJobs() {
    let jobs = Set(runs.values.filter { $0.phase.isAppOpen && $0.result == nil }.map(\.run.job))
    if jobs != appOpenJobs { appOpenJobs = jobs }
  }

  /// Returns when the interrupt does or when the deadline passes, whichever is first, since a step that ignores cancellation holds the interrupt.
  nonisolated private static func interrupt(_ run: HostedJobRun, within deadline: Duration) async {
    let gate = DeadlineGate()
    await withCheckedContinuation { continuation in
      gate.arm(continuation)
      Task {
        do throws(JobEngineError) {
          _ = try await run.interrupt()
        } catch {
          logger.error("A job run could not be interrupted code=\(error.code, privacy: .public)")
        }
        gate.open()
      }
      Task {
        try? await Task.sleep(for: deadline)
        gate.open()
      }
    }
  }
}

nonisolated struct HostedRunState: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case submitting
    case awaitingLaunch
    case running
    case appOpen
    case completed
  }

  let phase: Phase
  let ended: Bool
}

private struct Shown: Equatable {
  let title: String
  let subtitle: String
}

@MainActor
private final class Hosted {
  enum Phase {
    case submitting
    case awaitingLaunch
    case running(any ContinuedProcessingTask)
    /// Automatic or refused: the run goes on only while the app is open.
    case appOpen
    case completed

    var isAppOpen: Bool { name == .appOpen }

    var name: HostedRunState.Phase {
      switch self {
      case .submitting: .submitting
      case .awaitingLaunch: .awaitingLaunch
      case .running: .running
      case .appOpen: .appOpen
      case .completed: .completed
      }
    }
  }

  let run: HostedJobRun
  let identifier: String
  var phase = Phase.submitting
  var latest: JobRunProgress?
  var units = ContinuedProcessingUnits()
  var shown: Shown?
  var result: AttemptResult?

  init(run: HostedJobRun, identifier: String) {
    self.run = run
    self.identifier = identifier
  }

  var awaitsLaunch: Bool {
    switch phase {
    case .submitting, .awaitingLaunch: true
    case .running, .appOpen, .completed: false
    }
  }
}

nonisolated private final class DeadlineGate: Sendable {
  private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

  func arm(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation.withLock { $0 = continuation }
  }

  func open() {
    continuation.withLock { $0.take() }?.resume()
  }
}

extension AttemptResult {
  fileprivate var succeeded: Bool {
    self == .settled(.succeeded)
  }
}
