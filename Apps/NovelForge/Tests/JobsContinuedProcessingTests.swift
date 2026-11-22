import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import Synchronization
import Testing

@testable import NovelForge

@MainActor
private final class FakeTask: ContinuedProcessingTask {
  let identifier: String
  private(set) var expiration: (@MainActor () -> Void)?
  private(set) var reports: [ContinuedProcessingUnits] = []
  private(set) var titles: [String] = []
  private(set) var subtitles: [String] = []
  private(set) var completions: [Bool] = []

  init(identifier: String) {
    self.identifier = identifier
  }

  func onExpiration(_ handler: @escaping @MainActor () -> Void) { expiration = handler }
  func report(_ units: ContinuedProcessingUnits) { reports.append(units) }
  func complete(success: Bool) { completions.append(success) }

  func update(title: String, subtitle: String) {
    titles.append(title)
    subtitles.append(subtitle)
  }

  func expire() { expiration?() }
}

@MainActor
private final class FakeScheduler: ContinuedProcessingScheduler {
  var refusal: ContinuedProcessingRefusal?
  /// Starts the task before the submission returns, as the system may.
  var launchesWhileSubmitting = false
  /// Holds every submission until `releaseSubmissions()`.
  var holdsSubmissions = false
  private(set) var wildcards: [String] = []
  private(set) var requests: [ContinuedProcessingRequest] = []
  private(set) var started: [FakeTask] = []
  private var launch: (@MainActor (any ContinuedProcessingTask) -> Void)?
  private var held: [CheckedContinuation<Void, Never>] = []

  func register(_ wildcard: String, launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void) {
    wildcards.append(wildcard)
    self.launch = launch
  }

  func submit(_ request: ContinuedProcessingRequest) async throws(ContinuedProcessingRefusal) {
    requests.append(request)
    if holdsSubmissions { await withCheckedContinuation { held.append($0) } }
    if let refusal { throw refusal }
    if launchesWhileSubmitting { start(request.identifier) }
  }

  func releaseSubmissions() {
    for continuation in held { continuation.resume() }
    held = []
  }

  @discardableResult
  func start(_ identifier: String) -> FakeTask {
    let task = FakeTask(identifier: identifier)
    started.append(task)
    launch?(task)
    return task
  }
}

/// A run whose progress, end and interrupt the test drives; `hangsOnInterrupt` keeps the interrupt from returning until `release()`.
nonisolated private final class ScriptedRun: Sendable {
  let job: EntityRef
  let attempt: AttemptID
  let target: NovelJobTarget?
  let origin: JobRunOrigin
  private let progress = AsyncStream<JobRunProgress>.makeStream(bufferingPolicy: .unbounded)
  private let ending = AsyncStream<AttemptResult>.makeStream(bufferingPolicy: .unbounded)
  private let hang = AsyncStream<Void>.makeStream()
  private let hangs: Bool
  let interrupts = Mutex(0)

  init(target: NovelJobTarget? = nil, origin: JobRunOrigin = .person, hangsOnInterrupt: Bool = false, attempt: AttemptID? = nil) throws {
    job = EntityRef(kind: JobSchema.jobKind, key: EntityKey(uuid: UUID.v7()))
    self.attempt = try attempt ?? AttemptID(UUID.v7())
    self.target = target
    self.origin = origin
    hangs = hangsOnInterrupt
  }

  var hosted: HostedJobRun {
    let (ending, hang, hangs, attempt) = (ending.stream, hang.stream, hangs, attempt)
    return HostedJobRun(
      job: job, attempt: attempt, target: target, origin: origin, progress: progress.stream,
      interrupt: { [self] () async throws(JobEngineError) -> JobInterruption in
        interrupts.withLock { $0 += 1 }
        if hangs { for await _ in hang {} }
        end(.interrupted)
        return .interrupted(attempt)
      },
      finished: {
        for await result in ending { return result }
        return .interrupted
      })
  }

  func report(step: AttemptStep? = nil, received: Int, expected: Int) {
    progress.continuation.yield(
      JobRunProgress(attempt: attempt, step: step, stepsDone: step?.index ?? 0, stepsTotal: 3, tokensReceived: received, tokensExpected: expected))
  }

  func end(_ result: AttemptResult) {
    progress.continuation.finish()
    ending.continuation.yield(result)
  }

  func release() { hang.continuation.finish() }
}

@MainActor
@Suite("Continued processing", TestTimeLimit.standard)
struct JobsContinuedProcessingTests {
  @Test func shouldRegisterTheWildcardOnceAndSubmitAFailFastRequestNamedForTheAttemptKindAndChapter() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let run = try ScriptedRun(target: NovelJobTarget(novel: UUID(), chapter: 4, kind: .generate))
    host.host(run.hosted)
    try await JobsWait.until("the request is submitted") { !scheduler.requests.isEmpty }

    #expect(scheduler.wildcards == ["com.shadow.apps.novelforge.job.*"])
    let request = try #require(scheduler.requests.first)
    #expect(request.identifier == "com.shadow.apps.novelforge.job.\(run.attempt.uuid.uuidString.lowercased())")
    #expect(request.title == "Writing chapter 4" && request.subtitle == "Starting")
    run.end(.settled(.succeeded))
  }

  @Test func shouldReportTokensAsMonotoneClampedProgressAndTheStepAsSubtitle() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let run = try ScriptedRun(target: NovelJobTarget(novel: UUID(), chapter: 2, kind: .generate))
    host.host(run.hosted)
    try await JobsWait.until("the request is submitted") { !scheduler.requests.isEmpty }
    let task = scheduler.start(ContinuedProcessingHost.identifier(of: run.attempt))
    #expect(task.reports == [ContinuedProcessingUnits(completed: 0, total: 1)])

    run.report(step: AttemptStep(name: "draft", index: 1), received: 100, expected: 4000)
    run.report(step: AttemptStep(name: "draft", index: 1), received: 900, expected: 600)
    run.report(step: AttemptStep(name: "expand", index: 2), received: 50, expected: 0)
    try await JobsWait.until("every value is reported") { task.reports.count == 4 }

    #expect(
      Array(task.reports.dropFirst()) == [
        ContinuedProcessingUnits(completed: 100, total: 4000), ContinuedProcessingUnits(completed: 900, total: 900),
        ContinuedProcessingUnits(completed: 900, total: 900),
      ])
    #expect(zip(task.reports, task.reports.dropFirst()).allSatisfy { $0.completed <= $1.completed })
    #expect(task.reports.allSatisfy { $0.completed <= $0.total && $0.total >= 1 })
    #expect(task.titles.allSatisfy { $0 == "Writing chapter 2" })
    #expect(task.subtitles == ["Starting", "Step 2 · Drafting", "Step 3 · Expanding"])
    run.end(.settled(.succeeded))
    try await JobsWait.until("the task completes") { !task.completions.isEmpty }
  }

  @Test func shouldCompleteTheTaskWithTheRunsOutcome() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let (succeeding, failing) = (try ScriptedRun(), try ScriptedRun())
    host.host(succeeding.hosted)
    host.host(failing.hosted)
    try await JobsWait.until("both requests are submitted") { scheduler.requests.count == 2 }
    let first = scheduler.start(ContinuedProcessingHost.identifier(of: succeeding.attempt))
    let second = scheduler.start(ContinuedProcessingHost.identifier(of: failing.attempt))

    succeeding.report(received: 40, expected: 300)
    succeeding.end(.settled(.succeeded))
    failing.end(.settled(.failed(AttemptFailure(code: "server", message: "500"))))
    try await JobsWait.until("both tasks complete") { !first.completions.isEmpty && !second.completions.isEmpty }

    #expect(first.completions == [true] && second.completions == [false])
    #expect(first.reports.last == ContinuedProcessingUnits(completed: 300, total: 300))
    #expect(first.expiration != nil && second.expiration != nil)
  }

  @Test func shouldCompleteATaskThatStartsAfterItsRunEnded() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let run = try ScriptedRun()
    host.host(run.hosted)
    try await JobsWait.until("the request is submitted") { !scheduler.requests.isEmpty }
    run.end(.settled(.succeeded))
    try await JobsWait.until("the ended run waits for its task") { host.state(of: run.attempt) == HostedRunState(phase: .awaitingLaunch, ended: true) }

    let task = scheduler.start(ContinuedProcessingHost.identifier(of: run.attempt))
    #expect(task.completions == [true] && task.expiration != nil)
  }

  @Test func shouldInterruptOnExpiryAndCompleteOnceWhenTheInterruptReturns() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler, interruptDeadline: .seconds(30))
    let run = try ScriptedRun()
    host.host(run.hosted)
    try await JobsWait.until("the request is submitted") { !scheduler.requests.isEmpty }
    let task = scheduler.start(ContinuedProcessingHost.identifier(of: run.attempt))

    task.expire()
    try await JobsWait.until("the task completes") { !task.completions.isEmpty }
    try await Task.sleep(for: .milliseconds(50))

    #expect(run.interrupts.withLock { $0 } == 1 && task.completions == [false])
  }

  @Test func shouldCompleteAnExpiredTaskAtTheDeadlineWhenTheInterruptHangs() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler, interruptDeadline: .milliseconds(200))
    let run = try ScriptedRun(hangsOnInterrupt: true)
    host.host(run.hosted)
    try await JobsWait.until("the request is submitted") { !scheduler.requests.isEmpty }
    let task = scheduler.start(ContinuedProcessingHost.identifier(of: run.attempt))
    let expired = ContinuousClock.now

    task.expire()
    try await JobsWait.until("the interrupt is under way") { run.interrupts.withLock { $0 } == 1 }
    #expect(task.completions.isEmpty)
    try await JobsWait.until("the task completes") { !task.completions.isEmpty }

    #expect(ContinuousClock.now - expired >= .milliseconds(200))
    #expect(task.completions == [false])
    run.release()
    try await Task.sleep(for: .milliseconds(50))
    #expect(task.completions == [false])
  }

  @Test(arguments: [ContinuedProcessingRefusal.ineligible, .unavailable])
  func shouldKeepARefusedRunGoingWhileTheAppIsOpenWithANotice(_ refusal: ContinuedProcessingRefusal) async throws {
    let scheduler = FakeScheduler()
    scheduler.refusal = refusal
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let (run, other) = (try ScriptedRun(), try ScriptedRun())
    host.host(run.hosted)
    try await JobsWait.until("the run needs the app open") { host.needsAppOpen(for: run.job) }

    #expect(!host.needsAppOpen(for: other.job) && run.interrupts.withLock { $0 } == 0)
    run.end(.settled(.succeeded))
    try await JobsWait.until("the notice goes once the run ends") { !host.needsAppOpen(for: run.job) }
  }

  @Test func shouldRunATaskThatStartsBeforeItsSubmissionReturns() async throws {
    let scheduler = FakeScheduler()
    scheduler.launchesWhileSubmitting = true
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let run = try ScriptedRun()
    host.host(run.hosted)
    try await JobsWait.until("the task starts") { host.state(of: run.attempt)?.phase == .running }

    let task = try #require(scheduler.started.first)
    run.report(received: 10, expected: 100)
    try await JobsWait.until("the progress is reported") { task.reports.contains(ContinuedProcessingUnits(completed: 10, total: 100)) }
    run.end(.settled(.succeeded))
    try await JobsWait.until("the task completes") { !task.completions.isEmpty }
    #expect(task.completions == [true])
    #expect(host.state(of: run.attempt) == nil && !host.needsAppOpen(for: run.job))
  }

  @Test func shouldForgetARunWhoseRequestIsRefusedAfterItEnded() async throws {
    let scheduler = FakeScheduler()
    (scheduler.holdsSubmissions, scheduler.refusal) = (true, .ineligible)
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let run = try ScriptedRun()
    host.host(run.hosted)
    try await JobsWait.until("the request is under way") { !scheduler.requests.isEmpty }
    run.end(.settled(.succeeded))
    try await JobsWait.until("the run's end is seen") { host.state(of: run.attempt)?.ended == true }

    scheduler.releaseSubmissions()
    try await JobsWait.until("the run is forgotten") { host.state(of: run.attempt) == nil }
    #expect(!host.needsAppOpen(for: run.job) && host.appOpenJobs.isEmpty)
  }

  @Test func shouldRunAnAutomaticRunWhileTheAppIsOpenWithoutSubmittingIt() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let (automatic, person) = (try ScriptedRun(origin: .automatic), try ScriptedRun())
    host.host(automatic.hosted)
    host.host(person.hosted)
    #expect(host.needsAppOpen(for: automatic.job) && !host.needsAppOpen(for: person.job))
    try await JobsWait.until("the person's run is submitted") { !scheduler.requests.isEmpty }

    #expect(scheduler.requests.map(\.identifier) == [ContinuedProcessingHost.identifier(of: person.attempt)])
    automatic.end(.settled(.succeeded))
    try await JobsWait.until("the notice goes once the run ends") { !host.needsAppOpen(for: automatic.job) }
    #expect(scheduler.requests.count == 1 && automatic.interrupts.withLock { $0 } == 0)
    person.end(.settled(.succeeded))
  }

  @Test func shouldCompleteALaunchOnceTheHostIsGone() {
    let scheduler = FakeScheduler()
    weak var gone: ContinuedProcessingHost?
    do {
      let host = ContinuedProcessingHost(scheduler: scheduler)
      gone = host
    }
    #expect(gone == nil)
    let task = scheduler.start("com.shadow.apps.novelforge.job.orphan")
    #expect(task.completions == [false] && task.expiration != nil)
  }

  @Test func shouldCompleteAStrayLaunchAtOnce() {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let task = scheduler.start("com.shadow.apps.novelforge.job.unknown")
    #expect(task.completions == [false] && host.appOpenJobs.isEmpty)
  }

  @Test func shouldHostAResumeOfTheSameAttemptAfterItsTaskExpired() async throws {
    let scheduler = FakeScheduler()
    let host = ContinuedProcessingHost(scheduler: scheduler)
    let first = try ScriptedRun()
    host.host(first.hosted)
    try await JobsWait.until("the request is submitted") { scheduler.requests.count == 1 }
    let expired = scheduler.start(ContinuedProcessingHost.identifier(of: first.attempt))
    expired.expire()
    try await JobsWait.until("the expired task completes") { !expired.completions.isEmpty }

    let resumed = try ScriptedRun(attempt: first.attempt)
    host.host(resumed.hosted)
    try await JobsWait.until("the resume is submitted") { scheduler.requests.count == 2 }
    let task = scheduler.start(ContinuedProcessingHost.identifier(of: resumed.attempt))
    resumed.end(.settled(.succeeded))
    try await JobsWait.until("the resumed task completes") { !task.completions.isEmpty }

    #expect(scheduler.requests.map(\.identifier) == Array(repeating: ContinuedProcessingHost.identifier(of: first.attempt), count: 2))
    #expect(expired.completions == [false] && task.completions == [true])
  }

  @Test func shouldPermitTheIdentifiersInTheBuiltInfoPlistAndKeepTheRemoteNotificationMode() throws {
    let permitted = try #require(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
    #expect(permitted == [ContinuedProcessingHost.wildcard])
    #if os(iOS)
      #expect(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] == ["remote-notification"])
    #endif
  }
}
