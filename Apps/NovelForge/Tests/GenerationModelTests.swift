import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

@MainActor
@Suite("Generation model")
struct GenerationModelTests {
  @Test func shouldRequestAGenerateJobAndFollowIt() async throws {
    let world = try await GenerationWorld.make([GenerationScripts.draft(), GenerationScripts.judge()], starter: GenerationStarters.refusing)
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)

    let outcome = await model.start(.generate, options: GenerationOptions(guidance: "Open on the stairs."), runtime: world.runtime)

    #expect(outcome == .started && model.failure == nil)
    #expect(world.power.begun == 1)
    try await world.waitForRun(1)
    try await JobsWait.until("the run's end releases the power assertion") { world.power.ended == 1 }
    let versions = try await world.versions()
    guard case .listed(let entries, _) = versions.versions.state else { throw ChatFixtureError.noBinding }
    #expect(entries.count == 1 && entries[0].version.isCurrent && versions.judged == [entries[0].version.revision])
    let request = try #require(world.provider.requests.first?.messages.last?.text)
    #expect(request.contains("Open on the stairs."))
  }

  @Test func shouldRegenerateADraftedChapterAsALaterRun() async throws {
    let world = try await GenerationWorld.make([GenerationScripts.draft(), GenerationScripts.judge()])
    _ = try await world.handDraft("Hand-written.")
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)

    #expect(await model.start(.regenerate, options: GenerationOptions(), runtime: world.runtime) == .started)
    try await world.waitForRun(1)
  }

  @Test func shouldShowEachRefusalWithItsHeadline() async throws {
    let world = try await GenerationWorld.make(plan: false)
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)

    let outcome = await model.start(.generate, options: GenerationOptions(), runtime: world.runtime)

    #expect(outcome == .refused(PresentedError(headline: String(localized: "This chapter has no plan yet. Plan it before writing it.", table: "Generation"), detail: "BRF_001")))
    #expect(model.failure?.detail == "BRF_001")
  }

  @Test func shouldRefuseToGenerateOverADraftAndShowItsHeadline() async throws {
    let world = try await GenerationWorld.make()
    _ = try await world.handDraft("Hand-written.")
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)

    _ = await model.start(.generate, options: GenerationOptions(), runtime: world.runtime)

    #expect(
      model.failure
        == PresentedError(headline: String(localized: "This chapter already has a draft. Regenerate it from the chapter itself.", table: "Generation"), detail: "DRF_015"))
  }

  @Test func shouldRefuseASecondGenerationWhileOneIsOpen() async throws {
    let world = try await GenerationWorld.make(starter: GenerationStarters.refusing)
    await world.runtime.launch()
    let engine = try #require(world.runtime.engine)
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 3, fingerprint: "open"))
    let model = GenerationModel(novel: world.novel, chapter: 1)

    _ = await model.start(.generate, options: GenerationOptions(), runtime: world.runtime)

    #expect(model.failure?.detail == "DRF_010")
    #expect(model.failure?.headline == JobsErrors.headline(code: "DRF_010"))
  }

  @Test func shouldSayJobsAreNotRunningWhenThereIsNoRuntime() async throws {
    let model = GenerationModel(novel: UUID(), chapter: 1)

    #expect(await model.start(.generate, options: GenerationOptions(), runtime: nil) == .refused(JobsErrors.notRunningHere))
  }

  @Test func shouldKeepGenerateOfferedAfterTheLatestJobFailed() async throws {
    let world = try await GenerationWorld.make([[.failure(.server(status: 500))]])
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)
    #expect(await model.start(.generate, options: GenerationOptions(), runtime: world.runtime) == .started)
    try await JobsWait.until("the generate job has failed") {
      guard let job = try await world.jobs().first(where: { $0.kind == .known(.generate) }), case .failed = job.status else { return false }
      return true
    }

    let status = try await world.status()
    let line = try #require(status.lines.first { $0.kind == .generate })

    #expect(!GenerationModel.isBusy(line))
    #expect(await model.start(.generate, options: GenerationOptions(), runtime: world.runtime) != .refused(JobsErrors.notRunningHere))
  }

  @Test func shouldOnlyRequestAGenerationOrRegenerationOnAPhoneAndLeaveItForTheWorker() async throws {
    let world = try await GenerationWorld.make([GenerationScripts.draft(), GenerationScripts.judge()], platform: .phone)
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)

    #expect(await model.start(.generate, options: GenerationOptions(), runtime: world.runtime) == .queued)

    try await Task.sleep(for: .milliseconds(300))
    let job = try #require(try await world.jobs().first { $0.kind == .known(.generate) })
    #expect(job.status == .queued && job.latest == nil && world.provider.requests.isEmpty && world.power.begun == 0)
    let line = try #require(try await world.status().lines.first { $0.kind == .generate })
    guard case .queued(let wait) = line.state else {
      Issue.record("the generation should wait for the worker")
      return
    }
    #expect(wait.starter == .noWorker && line.actions == [.runHere, .cancel] && model.failure == nil && model.notice == nil)

    _ = try await world.engineCancel(job.job)
    _ = try await world.handDraft("Hand-written.")
    #expect(await model.start(.regenerate, options: GenerationOptions(), runtime: world.runtime) == .queued)
    try await Task.sleep(for: .milliseconds(300))
    let regeneration = try #require(try await world.jobs().last { $0.kind == .known(.generate) })
    #expect(regeneration.status == .queued && regeneration.latest == nil && world.provider.requests.isEmpty)
  }

  @Test func shouldCallARunningOrQueuedGenerationBusy() async throws {
    let world = try await GenerationWorld.make(starter: GenerationStarters.refusing)
    await world.runtime.launch()
    let engine = try #require(world.runtime.engine)
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "queued"))

    let line = try #require(try await world.status().lines.first { $0.kind == .generate })

    #expect(line.isQueued && GenerationModel.isBusy(line))
  }

  @Test func shouldHeadlineEveryRefusalTheGateRaises() {
    let codes = ["DRF_015", "DRF_010", "DRF_003", "BRF_001", "BRF_002", "CHP_008", "AI_024"]
    for code in codes { #expect(GenerationErrors.headline(code: code) != nil, "no headline for \(code)") }
    let positional: [GenerationRequestError] = [.outOfOrder(chapter: 3, blocker: 2), .externalChapter(chapter: 3, blocker: 2), .teacherUnsettled(chapter: 3, teacher: 1)]
    for error in positional { #expect(GenerationErrors.presented(error).headline != String(localized: "Something went wrong.", table: "Generation"), "\(error.code)") }
    #expect(GenerationErrors.presented(.outOfOrder(chapter: 3, blocker: 2)).detail == "DRF_011")
    #expect(GenerationErrors.presented(.externalChapter(chapter: 3, blocker: 2)).detail == "DRF_012")
    #expect(GenerationErrors.presented(.teacherUnsettled(chapter: 3, teacher: 1)).detail == "DRF_016")
  }

  @Test func shouldListTheStepsOfARunWithTheCurrentOneMarked() {
    let rows = GenerationProgress.rows(at: AttemptStep(name: "judge", index: 6))

    #expect(rows.map(\.name) == ["draft", "expand", "title", "save", "checks", "judge", "finish"])
    #expect(rows.map(\.state) == [.done, .done, .done, .done, .done, .current, .pending])
    let repairing = GenerationProgress.rows(at: AttemptStep(name: "repair", index: 7))
    #expect(repairing.map(\.name) == ["draft", "expand", "title", "save", "checks", "judge", "repair", "finish"])
    #expect(repairing.first { $0.state == .current }?.name == "repair")
    #expect(GenerationProgress.rows(at: nil).allSatisfy { $0.state == .pending })
  }
}
