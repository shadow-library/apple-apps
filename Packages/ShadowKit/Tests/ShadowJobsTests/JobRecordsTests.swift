import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowJobs

@Suite("JobRecords", .timeLimit(.minutes(1)))
struct JobRecordsTests {
  private static func requested(_ store: VaultStore, _ key: JobKey) async throws -> JobRequestOutcome {
    let request = JobFixture.request(key, replica: store.replica)
    return try await store.write { transaction in try JobRecords.request(request, in: &transaction) }
  }

  private static func started(_ store: VaultStore, _ key: JobKey, at seconds: Int64 = 0, byHand: Bool = false) async throws -> AttemptID {
    let id = try JobFixture.attemptID(seconds)
    let start = JobFixture.start(key, replica: store.replica, at: seconds, byHand: byHand)
    _ = try await store.write { transaction in try AttemptRecords.start(id, start, step: AttemptStep(name: "draft", index: 0), in: &transaction) }
    return id
  }

  private static func update(_ store: VaultStore, _ id: AttemptID, _ update: AttemptUpdate, by writer: ReplicaID? = nil) async throws(JobRecordError) -> Bool {
    let writer = writer ?? store.replica
    do {
      return try await store.write { transaction in try AttemptRecords.update(id, update, by: writer, in: &transaction) }
    } catch {
      guard case .aborted(let inner as JobRecordError) = error else { throw .store(error) }
      throw inner
    }
  }

  @Test func shouldRequestAJobOnceAndAnswerTheStoredJobForASecondRequestOfTheKey() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    let first = try await Self.requested(store, key)
    guard case .requested(let job) = first else { throw FixtureError(description: "the first request wrote nothing") }
    #expect(job.cancel == .none)
    let pending = try await store.pendingChanges(limit: Int.max).count
    let other = JobRequest(key: key, payload: ["chapter": 9], replica: JobFixture.replica(9))
    let second = try await store.write { transaction in try JobRecords.request(other, in: &transaction) }
    #expect(second == .existing(job))
    #expect(try await store.pendingChanges(limit: Int.max).count == pending)
    #expect(try await store.read { transaction in try JobRecords.read(key.ref, in: transaction) } == .readable(job))
  }

  @Test func shouldReadAJobWhoseRequestHasNotArrivedAsUnreadableAndWriteTheRequestBesideItsCancel() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await store.write { transaction in try transaction.set(key.ref, ["cancel": "requested"]) }
    #expect(try await store.read { transaction in try JobRecords.read(key.ref, in: transaction) } == .unreadable("its request has not arrived"))
    #expect(try await store.read { transaction in try JobSnapshot.load(key.ref, in: transaction) } == nil)
    guard case .requested(let job) = try await Self.requested(store, key) else { throw FixtureError(description: "the request was not written") }
    #expect(job.cancel == .requested)
    #expect(try await store.read { transaction in try JobRecords.read(key.ref, in: transaction) }.record?.cancel == .requested)
  }

  @Test func shouldRefuseARequestOverAStoredRequestThatCannotBeRead() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await store.write { transaction in try transaction.set(key.ref, ["request": ["kind": "generate"]]) }
    await #expect(throws: StoreError.self) { try await Self.requested(store, key) }
  }

  @Test func shouldCancelOnceAndLeaveASucceededJobUncancelled() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await Self.requested(store, key)
    #expect(try await store.write { transaction in try JobRecords.cancel(key.ref, in: &transaction) } == .requested)
    #expect(try await store.write { transaction in try JobRecords.cancel(key.ref, in: &transaction) } == .alreadyRequested)

    let done = try JobFixture.key(run: 2)
    _ = try await Self.requested(store, done)
    let id = try await Self.started(store, done)
    #expect(try await Self.update(store, id, AttemptUpdate(settlement: .succeeded)))
    #expect(try await store.write { transaction in try JobRecords.cancel(done.ref, in: &transaction) } == .alreadySucceeded)
    #expect(try await store.read { transaction in try JobRecords.read(done.ref, in: transaction) }.record?.cancel == JobCancel.none)
    await #expect(throws: StoreError.self) { try await store.write { transaction in try JobRecords.cancel(try JobFixture.key(run: 3).ref, in: &transaction) } }
  }

  @Test func shouldStartAnAttemptWithItsLeaseStepAndRunningOutcomeInOneChange() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await Self.requested(store, key)
    let before = try await store.pendingChanges(limit: Int.max).count
    let id = try await Self.started(store, key, at: 10, byHand: true)
    #expect(try await store.pendingChanges(limit: Int.max).count == before + 1)
    let record = try await JobFixture.attempt(id, in: store)
    #expect(record.start == JobFixture.start(key, replica: store.replica, at: 10, byHand: true))
    #expect(record.lease == AttemptLease(expires: JobFixture.instant(370).millis, renewed: JobFixture.instant(10).millis, clock: .trusted))
    #expect(record.step == AttemptStep(name: "draft", index: 0))
    #expect(record.outcome == .running)
    #expect(record.calls.isEmpty && record.error == nil)
  }

  @Test func shouldRefuseToStartAnAttemptTwiceOrForAJobThatIsNotHere() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    await #expect(throws: StoreError.self) { try await Self.started(store, key) }
    _ = try await Self.requested(store, key)
    let id = try await Self.started(store, key)
    let start = JobFixture.start(key, replica: store.replica, at: 0)
    do {
      _ = try await store.write { transaction in try AttemptRecords.start(id, start, step: nil, in: &transaction) }
      Issue.record("a second start was written")
    } catch {
      guard case .aborted(JobRecordError.attemptExists(let ref)) = error else { throw error }
      #expect(ref == id.ref)
    }
  }

  @Test func shouldLetOnlyTheStartReplicaWriteTheAttempt() async throws {
    let first = try JobFixture.open()
    let second = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await Self.requested(first, key)
    let id = try await Self.started(first, key)
    try await JobFixture.exchange([first, second])
    let writes: [AttemptUpdate] = [
      AttemptUpdate(lease: .granted(at: JobFixture.instant(60))), AttemptUpdate(step: AttemptStep(name: "expand", index: 1)), AttemptUpdate(call: UUID.v7()),
      AttemptUpdate(settlement: .succeeded), AttemptUpdate(settlement: .failed(AttemptFailure(code: "x", message: "y"))),
    ]
    for update in writes {
      do {
        _ = try await Self.update(second, id, update)
        Issue.record("another replica wrote the attempt")
      } catch .notWriter(let ref, let owner, let writer) {
        #expect(ref == id.ref && owner == first.replica && writer == second.replica)
      }
    }
    #expect(try await JobFixture.attempt(id, in: second).outcome == .running)
  }

  @Test func shouldKeepCallsCumulativeAndWriteNothingForACallAlreadyRecorded() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await Self.requested(store, key)
    let id = try await Self.started(store, key)
    let calls = (0..<3).map { _ in UUID.v7() }
    let replica = store.replica
    for call in calls {
      #expect(try await store.write { transaction in try AttemptRecords.recordCall(call, attempt: id, by: replica, in: &transaction) })
    }
    #expect(try await store.write { transaction in try AttemptRecords.recordCall(calls[1], attempt: id, by: replica, in: &transaction) } == false)
    #expect(try await JobFixture.attempt(id, in: store).calls == calls)
  }

  @Test func shouldWriteAnErrorOnlyWithAFailedOutcomeAndRefuseWritesOnceSettled() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await Self.requested(store, key)
    let stood = try await Self.started(store, key, at: 0)
    #expect(try await Self.update(store, stood, AttemptUpdate(settlement: .stoodDown)))
    #expect(try await JobFixture.attempt(stood, in: store).error == nil)
    let failed = try await Self.started(store, key, at: 1)
    let failure = AttemptFailure(code: "ai.timeout", message: String(repeating: "x", count: 2500))
    #expect(failure.message.count == 2000)
    #expect(try await Self.update(store, failed, AttemptUpdate(settlement: .failed(failure))))
    let record = try await JobFixture.attempt(failed, in: store)
    #expect(record.outcome == .failed && record.error == failure)
    for update in [AttemptUpdate(settlement: .cancelled), AttemptUpdate(lease: .granted(at: JobFixture.instant(90))), AttemptUpdate(call: UUID.v7())] {
      do {
        _ = try await Self.update(store, failed, update)
        Issue.record("a settled attempt took a write")
      } catch .attemptSettled(let ref, let outcome) {
        #expect(ref == failed.ref && outcome == .failed)
      }
    }
  }

  @Test func shouldWriteALeaseThatRunsOutAtAnotherTimeEvenEarlierAndSkipAnUnchangedOne() async throws {
    let store = try JobFixture.open()
    let key = try JobFixture.key()
    _ = try await Self.requested(store, key)
    let id = try await Self.started(store, key, at: 100)
    #expect(try await Self.update(store, id, AttemptUpdate(lease: .granted(at: JobFixture.instant(100)))) == false)
    #expect(try await Self.update(store, id, AttemptUpdate(step: AttemptStep(name: "draft", index: 0))) == false)
    #expect(try await Self.update(store, id, AttemptUpdate(lease: .granted(at: JobFixture.instant(50)))))
    #expect(try await JobFixture.attempt(id, in: store).lease?.renewed == JobFixture.instant(50).millis)
    #expect(try await Self.update(store, id, AttemptUpdate(lease: .granted(at: JobFixture.instant(220)))))
    #expect(try await JobFixture.attempt(id, in: store).lease?.renewed == JobFixture.instant(220).millis)
  }

  @Test func shouldCapAnErrorMessageAtTwoThousandUTF16UnitsLikeTheReference() {
    #expect(AttemptFailure(code: "x", message: String(repeating: "\u{1F600}", count: 1500)).message == String(repeating: "\u{1F600}", count: 1000))
    #expect(AttemptFailure(code: "x", message: "a" + String(repeating: "\u{1F600}", count: 1500)).message == "a" + String(repeating: "\u{1F600}", count: 999))
    #expect(AttemptFailure(code: "x", message: "short").message == "short")
  }

  @Test func shouldReadAnAttemptWithoutItsStartOrWithAMalformedMemberAsUnreadable() async throws {
    let store = try JobFixture.open()
    let id = try JobFixture.attemptID(0)
    _ = try await store.write { transaction in try transaction.set(id.ref, ["lease": ["expires": 1]]) }
    #expect(try await store.read { transaction in try AttemptRecords.read(id, in: transaction) } == .unreadable("its start has not arrived"))
    let other = try JobFixture.attemptID(1)
    let start = JobFixture.start(try JobFixture.key(), replica: store.replica, at: 1)
    _ = try await store.write { transaction in try transaction.set(other.ref, ["start": start.json, "calls": ["not-a-uuid"]]) }
    #expect(try await store.read { transaction in try AttemptRecords.read(other, in: transaction) } == .unreadable("calls holds an entry that is not a UUID"))
  }

  @Test func shouldAgreeOnOneJobWhenThreeReplicasRequestItConcurrently() async throws {
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 3, registry: JobFixture.registry))
    let key = try JobFixture.key()
    for index in 0..<3 {
      let request = JobRequest(key: key, payload: ["by": .int(Int64(index))], replica: await replicas.store(index).replica)
      _ = try await replicas.write(index) { transaction in try JobRecords.request(request, in: &transaction) }
    }
    try await replicas.settle()
    let jobs = try await Array(0..<3).mapInOrder { index in try await replicas.store(index).read { transaction in try JobRecords.read(key.ref, in: transaction) } }
    #expect(Set(jobs).count == 1)
    #expect(jobs[0].record?.request.key == key)
  }

  @Test(arguments: [UInt64(1), 2, 3, 4, 5])
  func shouldDeliverAnAttemptsCumulativeCallsAsAGrowingListInAnyDeliveryOrder(_ seed: UInt64) async throws {
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 3, registry: JobFixture.registry, seed: seed))
    let key = try JobFixture.key()
    let writer = await replicas.store(0).replica
    _ = try await replicas.write(0) { transaction in try JobRecords.request(JobFixture.request(key, replica: writer), in: &transaction) }
    let id = try JobFixture.attemptID(0)
    _ = try await replicas.write(0) { transaction in try AttemptRecords.start(id, JobFixture.start(key, replica: writer, at: 0), step: nil, in: &transaction) }
    let calls = (0..<4).map { _ in UUID.v7() }
    var generator = SeededGenerator(seed: seed)
    for call in calls {
      _ = try await replicas.write(0) { transaction in try AttemptRecords.recordCall(call, attempt: id, by: writer, in: &transaction) }
      for _ in 0..<generator.int(in: 0...3) { _ = try await replicas.step(using: &generator) }
      for index in 1..<3 {
        let seen = try await replicas.store(index).read { transaction in try AttemptRecords.read(id, in: transaction) }.record?.calls ?? []
        #expect(Array(calls.prefix(seen.count)) == seen)
      }
    }
    _ = try await replicas.write(0) { transaction in try AttemptRecords.update(id, AttemptUpdate(settlement: .succeeded), by: writer, in: &transaction) }
    try await replicas.settle()
    for index in 0..<3 {
      let record = try #require(try await replicas.store(index).read { transaction in try AttemptRecords.read(id, in: transaction) }.record)
      #expect(record.calls == calls && record.outcome == .succeeded)
    }
  }

  @Test func shouldSettleASucceededAttemptAboveAConcurrentCancelOnEveryReplica() async throws {
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 3, registry: JobFixture.registry))
    let key = try JobFixture.key()
    let writer = await replicas.store(0).replica
    _ = try await replicas.write(0) { transaction in try JobRecords.request(JobFixture.request(key, replica: writer), in: &transaction) }
    let id = try JobFixture.attemptID(0)
    _ = try await replicas.write(0) { transaction in try AttemptRecords.start(id, JobFixture.start(key, replica: writer, at: 0), step: nil, in: &transaction) }
    try await replicas.settle()
    _ = try await replicas.write(1) { transaction in try JobRecords.cancel(key.ref, in: &transaction) }
    _ = try await replicas.write(0) { transaction in try AttemptRecords.update(id, AttemptUpdate(settlement: .succeeded), by: writer, in: &transaction) }
    _ = try await replicas.deliver(from: 1, to: 2)
    let partial = try await JobFixture.snapshot(key.ref, in: await replicas.store(2))
    #expect(JobStatus(partial, at: JobFixture.instant(1)) == .cancelled)
    try await replicas.settle()
    for index in 0..<3 {
      let snapshot = try await JobFixture.snapshot(key.ref, in: await replicas.store(index))
      #expect(JobStatus(snapshot, at: JobFixture.instant(1)) == .succeeded(id))
      #expect(snapshot.job.cancel == .requested)
    }
  }
}
