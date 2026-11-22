import ShadowAppShell

#if os(macOS)
  import Foundation
  import NovelForgeCore
  import ShadowCore
  import ShadowJobs
  import ShadowStore
  import ShadowTestSupport
  import Synchronization
  import Testing

  @testable import NovelForge

  @MainActor
  private final class FakeLoginItem: LoginItem {
    var status = LoginItemStatus.notRegistered
    /// What the system answers once registered: enabled, or waiting for the user's approval.
    var registeredStatus = LoginItemStatus.enabled
    var refusal: LoginItemError?
    private(set) var registrations = 0
    private(set) var unregistrations = 0
    private(set) var settingsOpened = 0

    func register() throws(LoginItemError) {
      registrations += 1
      if let refusal { throw refusal }
      status = registeredStatus
    }

    func unregister() throws(LoginItemError) {
      unregistrations += 1
      status = .notRegistered
    }

    func openSystemSettingsLoginItems() {
      settingsOpened += 1
    }
  }

  /// A vault's worker record held in memory: writes and `emit` publish to every observer, `replace` changes it without telling them, as a write whose
  /// read has not been published yet.
  private final class FakeWorkerAccess: WorkerRecordAccess {
    private struct State {
      var worker: VaultWorker
      var designations: [WorkerChoice] = []
      var reads = 0
      var refusal: JobEngineError?
      var observers: [AsyncThrowingStream<VaultWorker, any Error>.Continuation] = []
    }

    let replica: ReplicaID
    private let state: Mutex<State>

    init(replica: ReplicaID = ReplicaID(UUID()), worker: VaultWorker = .none) {
      self.replica = replica
      state = Mutex(State(worker: worker))
    }

    var identity: ObjectIdentifier { ObjectIdentifier(self) }
    var designations: [WorkerChoice] { state.withLock(\.designations) }
    var reads: Int { state.withLock(\.reads) }
    var here: VaultWorker { .named(JobDevice(replica: replica, name: "This Mac", isHere: true)) }

    func refuse(_ error: JobEngineError?) {
      state.withLock { $0.refusal = error }
    }

    func replace(_ worker: VaultWorker) {
      state.withLock { $0.worker = worker }
    }

    /// Publishes `worker`, or the current record again, without changing what a fresh read answers when `worker` is given with `replacing: false`.
    func emit(_ worker: VaultWorker? = nil, replacing: Bool = true) {
      let (observers, published) = state.withLock { state -> ([AsyncThrowingStream<VaultWorker, any Error>.Continuation], VaultWorker) in
        if let worker, replacing { state.worker = worker }
        return (state.observers, worker ?? state.worker)
      }
      for observer in observers { observer.yield(published) }
    }

    func takeOver(by name: String?) {
      emit(.named(JobDevice(replica: ReplicaID(UUID()), name: name, isHere: false)))
    }

    func designate(_ choice: WorkerChoice) async throws(JobEngineError) -> VaultWorker {
      let refusal = state.withLock { state -> JobEngineError? in
        if let refusal = state.refusal { return refusal }
        state.designations.append(choice)
        return nil
      }
      if let refusal { throw refusal }
      emit(choice == .thisReplica ? here : VaultWorker.none)
      return state.withLock(\.worker)
    }

    func worker() async throws(JobEngineError) -> VaultWorker {
      state.withLock { state in
        state.reads += 1
        return state.worker
      }
    }

    func observeWorker() -> AsyncThrowingStream<VaultWorker, any Error> {
      let (stream, continuation) = AsyncThrowingStream<VaultWorker, any Error>.makeStream()
      let current = state.withLock { state -> VaultWorker in
        state.observers.append(continuation)
        return state.worker
      }
      continuation.yield(current)
      return stream
    }
  }

  @MainActor
  private final class WorkerWorld {
    let defaults: UserDefaults
    let login = FakeLoginItem()
    private(set) var syncInFront: [Bool] = []
    private(set) var presenceBegun = 0
    private(set) var presenceEnded = 0
    private let suite = "com.shadow.apps.novelforge.tests.worker.\(UUID().uuidString)"

    init(preference replica: ReplicaID? = nil) throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      WorkerPreference(defaults: defaults).save(replica)
    }

    var preference: ReplicaID? { WorkerPreference(defaults: defaults).replica }

    func model() -> WorkerModel {
      let presence = JobPowerAssertion(
        activity: JobPowerAssertion.Activity(
          begin: { [self] in
            presenceBegun += 1
            return NSObject()
          },
          end: { [self] _ in presenceEnded += 1 }))
      let effects = WorkerModel.Effects(keepSyncInFront: { [self] kept in syncInFront.append(kept) }, presence: presence)
      return WorkerModel(preference: WorkerPreference(defaults: defaults), loginItem: login, effects: effects)
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
    }
  }

  @MainActor
  @Suite("Worker model", TestTimeLimit.standard)
  struct WorkerModelTests {
    @Test func shouldNeverRegisterTheLoginItemAtLaunchOrBeforeTheUserTurnsWorkerModeOn() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()

      await model.launched()
      model.attach(access)
      try await WorkerWait.until("the record is read") { model.worker == VaultWorker.none }
      model.refreshLoginItem()

      #expect(!model.isOn && world.login.registrations == 0 && access.designations.isEmpty)
      #expect(world.syncInFront.isEmpty && world.presenceBegun == 0)
    }

    @Test func shouldNotRegisterTheLoginItemWhenRelaunchedInWorkerModeOrWhenTheRecordAlreadyNamesThisMac() async throws {
      let access = FakeWorkerAccess()
      let relaunched = try WorkerWorld(preference: access.replica)
      defer { relaunched.remove() }
      let model = relaunched.model()

      await model.launched()

      #expect(model.isOn && relaunched.syncInFront == [true] && relaunched.presenceBegun == 1)
      #expect(relaunched.login.registrations == 0)

      let forgotten = try WorkerWorld()
      defer { forgotten.remove() }
      let adopting = forgotten.model()
      adopting.attach(FakeWorkerAccess(replica: access.replica, worker: access.here))
      try await WorkerWait.until("worker mode follows the record") { adopting.isOn }

      #expect(forgotten.preference == access.replica && forgotten.syncInFront == [true] && forgotten.login.registrations == 0)
    }

    @Test func shouldDesignateThisMacThenRegisterTheLoginItemAndKeepSyncInFrontWhenTurnedOn() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)

      await model.turnOn()

      #expect(access.designations == [.thisReplica])
      #expect(model.isOn && model.worker == access.here && world.preference == access.replica)
      #expect(world.login.registrations == 1 && model.loginItem == .status(.enabled))
      #expect(world.syncInFront == [true] && world.presenceBegun == 1 && world.presenceEnded == 0)
    }

    @Test func shouldNameNoWorkerAndUnregisterTheLoginItemWhenTurnedOff() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)
      await model.turnOn()

      await model.turnOff()

      #expect(access.designations == [.thisReplica, WorkerChoice.none])
      #expect(!model.isOn && model.worker == VaultWorker.none && world.preference == nil)
      #expect(world.login.unregistrations == 1 && model.loginItem == .status(.notRegistered))
      #expect(world.syncInFront == [true, false] && world.presenceEnded == 1)
    }

    @Test func shouldLeaveTheRecordAloneWhenTurnedOffWhileAnotherMacIsTheWorker() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)
      await model.turnOn()
      let other = VaultWorker.named(JobDevice(replica: ReplicaID(UUID()), name: "Studio Mac", isHere: false))
      access.replace(other)

      await model.turnOff()

      #expect(access.designations == [.thisReplica])
      #expect(!model.isOn && model.worker == other && world.login.unregistrations == 1)
    }

    @Test func shouldTurnOffAndSayWhoTookOverWhenAnotherMacIsNamedLater() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)
      await model.turnOn()

      access.takeOver(by: "Studio Mac")

      try await WorkerWait.until("worker mode turns off") { !model.isOn }
      #expect(model.notice == .takenOver(by: "Studio Mac") && model.worker?.device?.name == "Studio Mac")
      #expect(access.designations == [.thisReplica] && world.preference == nil)
      #expect(world.login.unregistrations == 1 && world.syncInFront == [true, false])
    }

    @Test func shouldTurnOffWhenTheRecordNamesNoMacAnyMore() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)
      await model.turnOn()

      access.emit(VaultWorker.none)

      try await WorkerWait.until("worker mode turns off") { !model.isOn }
      #expect(model.notice == .stoppedElsewhere && access.designations == [.thisReplica])
    }

    @Test func shouldStayOnWhenAnEmissionFromBeforeItsOwnDesignationArrivesLate() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)
      await model.turnOn()

      let reads = access.reads
      access.emit(VaultWorker.none, replacing: false)
      try await WorkerWait.until("the stale emission is read again") { access.reads > reads }
      try await WorkerWait.until("the fresh read shows") { model.worker == access.here }

      #expect(model.isOn && model.notice == nil && world.login.unregistrations == 0)
    }

    @Test func shouldStopAtOnceWithoutAnEngineAndClearTheRecordWhenAVaultIsNextAttached() async throws {
      let access = FakeWorkerAccess()
      let world = try WorkerWorld(preference: access.replica)
      defer { world.remove() }
      let model = world.model()
      await model.launched()

      await model.turnOff()

      #expect(!model.isOn && world.preference == nil && world.login.unregistrations == 1)
      #expect(world.syncInFront == [true, false] && world.presenceEnded == 1)
      #expect(WorkerPreference(defaults: world.defaults).clearPending == access.replica)

      access.replace(access.here)
      model.attach(access)

      try await WorkerWait.until("the record is cleared") { WorkerPreference(defaults: world.defaults).clearPending == nil }
      #expect(access.designations == [WorkerChoice.none] && model.worker == VaultWorker.none)
      #expect(!model.isOn && world.syncInFront == [true, false] && world.login.registrations == 0)
    }

    @Test func shouldKeepWorkerModeOffAndTheMarkerWhileThePendingClearCannotBeWritten() async throws {
      let access = FakeWorkerAccess(worker: .none)
      let world = try WorkerWorld(preference: access.replica)
      defer { world.remove() }
      let model = world.model()
      await model.turnOff()
      access.replace(access.here)
      access.refuse(.store(.sequenceExhausted))

      model.attach(access)
      try await WorkerWait.until("the clear is tried") { access.reads > 0 }
      try await Task.sleep(for: .milliseconds(50))

      #expect(!model.isOn && WorkerPreference(defaults: world.defaults).clearPending == access.replica)
      access.refuse(nil)
      access.emit()
      try await WorkerWait.until("the record is cleared") { WorkerPreference(defaults: world.defaults).clearPending == nil }
      #expect(access.designations == [WorkerChoice.none] && !model.isOn)
    }

    @Test func shouldDropThePendingClearWhenTheRecordNoLongerNamesThisMac() async throws {
      let access = FakeWorkerAccess()
      let world = try WorkerWorld(preference: access.replica)
      defer { world.remove() }
      let model = world.model()
      await model.turnOff()

      model.attach(access)

      try await WorkerWait.until("the marker is dropped") { WorkerPreference(defaults: world.defaults).clearPending == nil }
      #expect(access.designations.isEmpty && !model.isOn)
    }

    @Test func shouldStayOnWhileTheRecordCannotBeRead() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      model.attach(access)
      await model.turnOn()

      access.emit(.unreadable("it is not a record"))
      try await WorkerWait.until("the unreadable record shows") { model.worker == .unreadable("it is not a record") }

      #expect(model.isOn && model.notice == nil)
    }

    @Test func shouldTurnOffRatherThanNameThisMacWhenAnotherLibraryOpens() async throws {
      let world = try WorkerWorld(preference: ReplicaID(UUID()))
      defer { world.remove() }
      let model = world.model()
      await model.launched()

      model.attach(FakeWorkerAccess())

      try await WorkerWait.until("worker mode turns off") { !model.isOn }
      #expect(model.notice == .libraryChanged && world.preference == nil && world.login.unregistrations == 1)
    }

    @Test func shouldKeepWorkerModeOffAndSayWhyWhenTheRecordCannotBeWritten() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      let access = FakeWorkerAccess()
      access.refuse(.store(.sequenceExhausted))
      model.attach(access)

      await model.turnOn()

      #expect(!model.isOn && model.failure?.detail == JobEngineError.store(.sequenceExhausted).code)
      #expect(world.login.registrations == 0 && world.syncInFront.isEmpty && world.preference == nil)
    }

    @Test func shouldDoNothingWithoutAnOpenVault() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()

      await model.turnOn()

      #expect(!model.isOn && !model.canDesignate && world.login.registrations == 0)
    }

    @Test func shouldOfferSystemSettingsWhenTheLoginItemAwaitsApproval() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      world.login.registeredStatus = .requiresApproval
      let model = world.model()
      model.attach(FakeWorkerAccess())

      await model.turnOn()

      #expect(model.isOn && model.loginItem == .status(.requiresApproval))
      model.openLoginItemsSettings()
      #expect(world.login.settingsOpened == 1)
      world.login.status = .enabled
      model.refreshLoginItem()
      #expect(model.loginItem == .status(.enabled))
    }

    @Test func shouldKeepWorkerModeOnAndShowTheRefusalWhenTheBuildCannotRegister() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      world.login.refusal = LoginItemError(reason: .invalidSignature)
      let model = world.model()
      model.attach(FakeWorkerAccess())

      await model.turnOn()

      #expect(model.isOn && model.loginItem == .refused(LoginItemError(reason: .invalidSignature)))
      model.refreshLoginItem()
      #expect(model.loginItem == .refused(LoginItemError(reason: .invalidSignature)))
      #expect(world.syncInFront == [true])
    }

    @Test func shouldRegisterAgainOnlyWhenAskedAfterTheItemWasTakenAway() async throws {
      let world = try WorkerWorld()
      defer { world.remove() }
      let model = world.model()
      model.attach(FakeWorkerAccess())
      await model.turnOn()
      world.login.status = .notRegistered

      model.refreshLoginItem()

      #expect(model.loginItem == .status(.notRegistered) && world.login.registrations == 1)
      model.registerLoginItem()
      #expect(model.loginItem == .status(.enabled) && world.login.registrations == 2)
    }
  }

  @MainActor
  @Suite("Worker menu status", TestTimeLimit.standard)
  struct WorkerMenuStatusTests {
    private static func run() throws -> JobRunHere {
      JobRunHere(job: EntityRef(kind: JobSchema.jobKind, key: EntityKey(uuid: UUID())), attempt: try AttemptID(UUID.v7()))
    }

    @Test func shouldWaitWhileNoRuntimeRunsTheLibrarysJobsHere() {
      #expect(WorkerMenuStatus(mode: nil, consentNeeded: false, runs: 0, run: nil, worker: nil) == .waiting(.libraryClosed))
      #expect(WorkerMenuStatus(mode: .starting, consentNeeded: false, runs: 0, run: nil, worker: nil) == .waiting(.starting))
      #expect(WorkerMenuStatus(mode: .elsewhere, consentNeeded: false, runs: 0, run: nil, worker: nil) == .waiting(.anotherCopy))
      let failure = PresentedError(headline: "Broken", detail: nil)
      #expect(WorkerMenuStatus(mode: .unavailable(failure), consentNeeded: false, runs: 0, run: nil, worker: nil) == .waiting(.unavailable))
    }

    @Test func shouldShowTheRunGoingHereWithItsStepEvenWhileTheQueueWaitsForConsent() throws {
      let (here, step) = (try Self.run(), AttemptStep(name: "draft", index: 1))
      let progress = JobRunProgress(attempt: here.attempt, step: step, stepsDone: 1, stepsTotal: 6, tokensReceived: 0, tokensExpected: 0)
      let run = WorkerRun(run: here, kind: .generate, progress: progress)

      let status = WorkerMenuStatus(mode: .running, consentNeeded: true, runs: 2, run: run, worker: nil)

      #expect(status == .running(kind: .generate, step: step, others: 1) && status.isRunning)
      #expect(status.detail != nil)
      #expect(WorkerMenuStatus(mode: .running, consentNeeded: false, runs: 1, run: nil, worker: nil) == .running(kind: nil, step: nil, others: 0))
    }

    @Test func shouldWaitForConsentOrAnUnreadableRecordAndOtherwiseBeIdle() {
      #expect(WorkerMenuStatus(mode: .running, consentNeeded: true, runs: 0, run: nil, worker: nil) == .waiting(.consent))
      #expect(WorkerMenuStatus(mode: .running, consentNeeded: false, runs: 0, run: nil, worker: .unreadable("x")) == .waiting(.workerUnreadable))
      let idle = WorkerMenuStatus(mode: .running, consentNeeded: false, runs: 0, run: nil, worker: VaultWorker.none)
      #expect(idle == .idle && !idle.isRunning && idle.detail == nil)
    }
  }

  @MainActor
  enum WorkerWait {
    static func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
      for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      Issue.record("timed out waiting: \(what)")
    }
  }
#endif
