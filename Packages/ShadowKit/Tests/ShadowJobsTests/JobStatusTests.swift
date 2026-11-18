import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowJobs

private struct Attempt {
  var seconds: Int64
  var outcome: AttemptOutcome = .running
  var leaseFrom: Int64?
  var byHand = false
  var index = 0
}

private func record(_ attempt: Attempt, job: JobKey) throws -> AttemptRecord {
  let id = try JobFixture.attemptID(attempt.seconds, attempt.index)
  let error = attempt.outcome == .failed ? AttemptFailure(code: "ai.timeout", message: "The call timed out.") : nil
  return AttemptRecord(
    id: id, start: JobFixture.start(job, replica: JobFixture.replica(attempt.index), at: attempt.seconds, byHand: attempt.byHand),
    lease: attempt.leaseFrom.map { .granted(at: JobFixture.instant($0)) }, step: nil, calls: [], outcome: attempt.outcome, error: error)
}

private func fixture(_ attempts: [Attempt], cancel: JobCancel = .none) throws -> (JobSnapshot, [AttemptRecord]) {
  let key = try JobFixture.key()
  let records = try attempts.map { try record($0, job: key) }
  let job = JobRecord(request: JobFixture.request(key, replica: JobFixture.replica(0)), cancel: cancel)
  return (JobSnapshot(job: job, attempts: records.reversed()), records)
}

@Suite("JobStatus")
struct JobStatusTests {
  private static let now = JobFixture.instant(400)

  @Test func shouldQueueAJobWithNoAttempts() throws {
    #expect(JobStatus(try fixture([]).0, at: Self.now) == .queued)
  }

  @Test func shouldRankSucceededAboveCancelledAboveRunningAboveFailed() throws {
    let (all, records) = try fixture(
      [Attempt(seconds: 10, outcome: .failed), Attempt(seconds: 20, leaseFrom: 300, index: 1), Attempt(seconds: 30, outcome: .succeeded, index: 2)], cancel: .requested)
    #expect(JobStatus(all, at: Self.now) == .succeeded(records[2].id))
    let (cancelled, _) = try fixture([Attempt(seconds: 10, outcome: .failed), Attempt(seconds: 20, leaseFrom: 300, index: 1)], cancel: .requested)
    #expect(JobStatus(cancelled, at: Self.now) == .cancelled)
    let (running, runningRecords) = try fixture([Attempt(seconds: 10, outcome: .failed), Attempt(seconds: 20, leaseFrom: 300, index: 1)])
    #expect(JobStatus(running, at: Self.now) == .running(runningRecords[1].id))
    let (failed, failedRecords) = try fixture([Attempt(seconds: 10, outcome: .failed)])
    #expect(JobStatus(failed, at: Self.now) == .failed(failedRecords[0].id, failedRecords[0].error))
    #expect(JobStatus(failed, at: Self.now).phase == .failed)
  }

  @Test func shouldReadAnAttemptThatEndedCancelledAsACancelBeforeTheCancelArrives() throws {
    #expect(JobStatus(try fixture([Attempt(seconds: 10, outcome: .cancelled)]).0, at: Self.now) == .cancelled)
  }

  @Test func shouldQueueAJobWhoseLatestAttemptLapsedEvenAfterAnEarlierFailure() throws {
    let (lapsed, _) = try fixture([Attempt(seconds: 10, outcome: .failed), Attempt(seconds: 20, leaseFrom: 20, index: 1)])
    #expect(JobStatus(lapsed, at: Self.now) == .queued)
  }

  @Test func shouldReportTheFailureOfTheLatestAttemptThatDidNotStandDown() throws {
    let (records, attempts) = try fixture([Attempt(seconds: 10, outcome: .failed), Attempt(seconds: 20, outcome: .stoodDown, index: 1)])
    #expect(JobStatus(records, at: Self.now) == .failed(attempts[0].id, attempts[0].error))
    let (onlyStood, _) = try fixture([Attempt(seconds: 20, outcome: .stoodDown)])
    #expect(JobStatus(onlyStood, at: Self.now) == .queued)
    let (retried, _) = try fixture([Attempt(seconds: 10, outcome: .failed), Attempt(seconds: 20, outcome: .stoodDown, index: 1), Attempt(seconds: 30, leaseFrom: 30, index: 2)])
    #expect(JobStatus(retried, at: Self.now) == .queued)
  }

  @Test func shouldKeepOnlyTheJobsOwnAttemptsInRankOrder() throws {
    let key = try JobFixture.key()
    let other = try record(Attempt(seconds: 5), job: try JobFixture.key(run: 2))
    let late = try record(Attempt(seconds: 9, index: 1), job: key)
    let tieHigh = try record(Attempt(seconds: 3, index: 7), job: key)
    let tieLow = try record(Attempt(seconds: 3, index: 2), job: key)
    let job = JobRecord(request: JobFixture.request(key, replica: JobFixture.replica(0)), cancel: .none)
    let ordered = JobSnapshot(job: job, attempts: [late, other, tieHigh, tieLow]).attempts
    let tie = [tieHigh, tieLow].sorted { $0.id.uuid.lowercasedString < $1.id.uuid.lowercasedString }
    #expect(ordered == tie + [late])
  }
}

@Suite("Lease")
struct LeaseTests {
  @Test func shouldGrantSixMinutesFromTheInstantWithItsClockSource() {
    let lease = AttemptLease.granted(at: JobFixture.instant(100, .device))
    #expect(lease == AttemptLease(expires: JobFixture.instant(460).millis, renewed: JobFixture.instant(100).millis, clock: .device))
    #expect(LeaseTerms.heartbeat * 3 == LeaseTerms.duration)
  }

  @Test func shouldHoldALeaseLiveUntilTheMillisecondItRunsOut() {
    let lease = AttemptLease.granted(at: JobFixture.instant(0))
    #expect(lease.isLive(at: JobFixture.instant(0)))
    #expect(lease.isLive(at: LeaseInstant(millis: lease.expires - 1, source: .trusted)))
    #expect(!lease.isLive(at: LeaseInstant(millis: lease.expires, source: .trusted)))
  }

  @Test func shouldTreatALeaseStampedTooFarAheadAsLapsed() {
    #expect(AttemptLease.granted(at: JobFixture.instant(300)).isLive(at: JobFixture.instant(0)))
    #expect(!AttemptLease.granted(at: JobFixture.instant(301)).isLive(at: JobFixture.instant(0)))
  }

  @Test func shouldTakeTrustedTimeWhenThereIsAnEstimateAndTheDeviceClockOtherwise() {
    let device = Date(timeIntervalSince1970: 1_700_000_000)
    let server = device.addingTimeInterval(-90)
    let trusted = TrustedClock(wallClock: { device })
    #expect(LeaseClock(trusted: trusted, device: { device }).now() == LeaseInstant(date: device, source: .device))
    #expect(LeaseClock(trusted: nil, device: { device }).now() == LeaseInstant(date: device, source: .device))
    trusted.record(serverDate: server)
    let estimate = LeaseClock(trusted: trusted, device: { device }).now()
    #expect(estimate.source == .trusted)
    #expect(abs(estimate.millis - LeaseInstant(date: server, source: .trusted).millis) < 1000)
  }

  @Test func shouldLiftADeviceClockThatReadsBeforeTheRestoredLowerBound() {
    let device = Date(timeIntervalSince1970: 1_700_000_000)
    let bound = device.addingTimeInterval(600)
    let restored = TrustedClock(wallClock: { device }, restored: TrustedClockSnapshot(serverDate: bound))
    #expect(LeaseClock(trusted: restored, device: { device }).now() == LeaseInstant(date: bound, source: .device))
    let behind = TrustedClock(wallClock: { device }, restored: TrustedClockSnapshot(serverDate: device.addingTimeInterval(-600)))
    #expect(LeaseClock(trusted: behind, device: { device }).now() == LeaseInstant(date: device, source: .device))
  }
}

@Suite("AttemptVerdict")
struct AttemptVerdictTests {
  private static let now = JobFixture.instant(100)

  @Test func shouldProceedAlone() throws {
    let (snapshot, records) = try fixture([Attempt(seconds: 10, leaseFrom: 90)])
    #expect(AttemptVerdict(for: records[0], in: snapshot, at: Self.now) == .proceed)
  }

  @Test func shouldStandDownOnceAnotherAttemptSucceededEvenOnACancelledJobOrByHand() throws {
    let (snapshot, records) = try fixture([Attempt(seconds: 10, outcome: .succeeded), Attempt(seconds: 20, leaseFrom: 90, byHand: true, index: 1)], cancel: .requested)
    #expect(AttemptVerdict(for: records[1], in: snapshot, at: Self.now) == .standDown(.succeeded(records[0].id)))
  }

  @Test func shouldCancelOnACancelRequestOrAnotherAttemptCancelledByHandOrNot() throws {
    for byHand in [false, true] {
      let (requested, records) = try fixture([Attempt(seconds: 10, leaseFrom: 90, byHand: byHand)], cancel: .requested)
      #expect(AttemptVerdict(for: records[0], in: requested, at: Self.now) == .cancel)
      let (seen, others) = try fixture([Attempt(seconds: 5, outcome: .cancelled), Attempt(seconds: 10, leaseFrom: 90, byHand: byHand, index: 1)])
      #expect(AttemptVerdict(for: others[1], in: seen, at: Self.now) == .cancel)
    }
  }

  @Test func shouldStandDownForAnEarlierLiveAttemptUnlessStartedByHand() throws {
    let (snapshot, records) = try fixture([Attempt(seconds: 10, leaseFrom: 90), Attempt(seconds: 20, leaseFrom: 90, index: 1)])
    #expect(AttemptVerdict(for: records[1], in: snapshot, at: Self.now) == .standDown(.outranked(records[0].id)))
    #expect(AttemptVerdict(for: records[0], in: snapshot, at: Self.now) == .proceed)
    let (manual, manualRecords) = try fixture([Attempt(seconds: 10, leaseFrom: 90), Attempt(seconds: 20, leaseFrom: 90, byHand: true, index: 1)])
    #expect(AttemptVerdict(for: manualRecords[1], in: manual, at: Self.now) == .proceed)
    #expect(AttemptVerdict(for: manualRecords[0], in: manual, at: Self.now) == .proceed)
  }

  @Test func shouldIgnoreAnEarlierAttemptWhoseLeaseLapsedOrThatEnded() throws {
    let (snapshot, records) = try fixture(
      [
        Attempt(seconds: 1, leaseFrom: -300), Attempt(seconds: 2, outcome: .failed, index: 1), Attempt(seconds: 3, outcome: .stoodDown, index: 2),
        Attempt(seconds: 20, leaseFrom: 90, index: 3),
      ])
    #expect(AttemptVerdict(for: records[3], in: snapshot, at: Self.now) == .proceed)
  }

  @Test func shouldBreakAStartTieByTheLowerIDSoExactlyOneOfTwoLiveAttemptsGoesOn() throws {
    let (snapshot, records) = try fixture([Attempt(seconds: 10, leaseFrom: 90, index: 1), Attempt(seconds: 10, leaseFrom: 90, index: 2)])
    let verdicts = records.map { AttemptVerdict(for: $0, in: snapshot, at: Self.now) }
    #expect(verdicts.filter { $0 == .proceed }.count == 1)
    let leader = snapshot.attempts[0]
    #expect(verdicts.contains(.standDown(.outranked(leader.id))))
  }

  @Test func shouldAgreeOnTheAttemptThatGoesOnAcrossReplicasOnceBothAttemptsArrive() async throws {
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 3, registry: JobFixture.registry))
    let key = try JobFixture.key()
    let writer = await replicas.store(0).replica
    _ = try await replicas.write(0) { transaction in try JobRecords.request(JobFixture.request(key, replica: writer), in: &transaction) }
    try await replicas.settle()
    var ids: [AttemptID] = []
    for (index, seconds) in [(1, Int64(40)), (2, Int64(30))] {
      let store = await replicas.store(index)
      let id = try JobFixture.attemptID(seconds, index)
      let start = JobFixture.start(key, replica: store.replica, at: seconds)
      _ = try await replicas.write(index) { transaction in try AttemptRecords.start(id, start, step: nil, in: &transaction) }
      ids.append(id)
    }
    try await replicas.settle()
    for index in 0..<3 {
      let snapshot = try await JobFixture.snapshot(key.ref, in: await replicas.store(index))
      let verdicts = snapshot.attempts.map { AttemptVerdict(for: $0, in: snapshot, at: JobFixture.instant(60)) }
      #expect(snapshot.attempts.map(\.id) == [ids[1], ids[0]])
      #expect(verdicts == [.proceed, .standDown(.outranked(ids[1]))])
      #expect(JobStatus(snapshot, at: JobFixture.instant(60)) == .running(ids[1]))
    }
  }
}
