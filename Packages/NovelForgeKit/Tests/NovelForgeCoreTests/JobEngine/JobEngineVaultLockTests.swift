import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Job engine vault lock and runtime reads", TestTimeLimit.standard)
struct JobEngineVaultLockTests {
  @Test func shouldRunNothingWhileAnotherProcessHoldsTheVaultsJobsLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "JobEngineVaultLockTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try Projection.store(try Projection.reconciler(), at: .file(directory.appending(path: "vault.sqlite")))
    let world = try await JobEngineWorld(store: store)
    let otherProcess = try #require(try store.acquireProcessLock(.jobs))
    let refused = #expect(throws: JobEngineError.self) { _ = try world.engine() }
    #expect(refused?.code == "job_engine.held_by_another_process")
    otherProcess.release()
    let engine = try world.engine()
    #expect(try store.acquireProcessLock(.jobs) == nil)
    engine.relinquish()
    #expect(try store.acquireProcessLock(.jobs) != nil)
  }

  @Test func shouldListTheUnstartedJobsThisDeviceAskedForAndTheChaptersLatestJob() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine()
    defer { engine.relinquish() }
    let first = try await world.request(engine, chapter: 1)
    let second = try await world.request(engine, chapter: 2)
    let replica = world.store.replica
    #expect(try await world.store.load(JobBacklog.self, replica).jobs == .available([first.ref, second.ref]))
    #expect(try await world.store.load(JobBacklog.self, ReplicaID(UUID.v7())).jobs == .available([]))

    #expect(await (try await engine.run(job: first.ref)).result == .settled(.succeeded))
    #expect(try await world.store.load(JobBacklog.self, replica).jobs == .available([second.ref]))
    let jobs = try await world.store.load(ChapterJobs.self, ChapterJobsQuery(novel: world.novel, chapter: 1, now: world.clock.instant))
    let latest = try #require(jobs.latest(.generate))
    #expect(latest.job == first.ref && latest.requester == replica && latest.runner == nil && latest.status.phase == .succeeded && jobs.changesAt == nil)

    let rerun = try await world.request(engine, chapter: 1, rerun: true)
    let after = try await world.store.load(ChapterJobs.self, ChapterJobsQuery(novel: world.novel, chapter: 1, now: world.clock.instant))
    #expect(after.latest(.generate)?.job == rerun.ref && after.latest(.generate)?.status == .queued && after.jobs.value?.count == 1)
    _ = try await engine.cancel(job: second.ref)
    #expect(try await world.store.load(JobBacklog.self, replica).jobs == .available([rerun.ref]))
  }
}
