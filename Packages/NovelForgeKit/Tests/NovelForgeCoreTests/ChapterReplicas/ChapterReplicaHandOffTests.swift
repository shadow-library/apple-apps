import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A device interrupts its run mid-call, as the phone does when its background time ends: with the lease released the other device's automatic run starts
/// at once and writes the result; with the lease kept, the other device stands back until it lapses.
@Suite("Chapter replicas: interrupted and handed over", TestTimeLimit.standard)
struct ChapterReplicaHandOffTests {
  @Test(arguments: [false, true])
  func shouldLetTheOtherDeviceRunTheJobOnlyOnceTheLeaseIsReleased(releasingLease: Bool) async throws {
    let pair = try await ChapterReplicas.make(seed: 0x4A01 + (releasingLease ? 1 : 0))
    try await pair.prepare(for: .plan)
    let (phone, mac) = (pair[0], pair[1])
    let hold = phone.model.holdNextCall()
    let first = try #require(try await ChapterStage.plan.start(on: phone, calls: ChapterStage.plan.calls()).handle)
    try await phone.waitUntilReached(hold)
    #expect(try await phone.engine.interrupt(job: first.job, releasingLease: releasingLease) == .interrupted(first.attempt))
    #expect(await first.result == .interrupted)
    try await pair.deliver(from: 0, to: 1)

    mac.model.queue(ChapterStage.plan.calls(variant: 1))
    let taken: JobRunHandle
    do {
      taken = try await mac.engine.run(job: first.job)
    } catch {
      #expect(!releasingLease, "a released lease is not live elsewhere")
      guard case JobEngineError.runningElsewhere(let leader, let replica) = error else { throw error }
      #expect(leader == first.attempt && replica == phone.replica)
      return
    }
    #expect(releasingLease, "a lease still live keeps the other device back")
    #expect(await taken.result == .settled(.succeeded))
    #expect(try await mac.status(first.job) == .succeeded(taken.attempt))
    #expect(try await mac.snapshot(first.job).attempts.first { $0.id == taken.attempt }?.start.byHand == false)
    #expect(try await phone.engine.interruptedRuns().map(\.attempt) == [first.attempt])
    try await pair.expectConverged()
  }
}
