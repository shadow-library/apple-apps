import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowTestSupport
import Testing

@testable import NovelForge

@MainActor
@Suite("SummarizeModel")
struct AmendSummarizeTests {
  @Test("should save the model's summary on the draft and show it as saved")
  func savesOnADraft() async throws {
    let world = try await AmendWorld.make(calls: [AmendWorld.reply])
    try await world.draft()
    let model = world.summaryModel()
    await model.load()

    await model.summarize()

    #expect(model.failure == nil && model.summary == "Mara finds the torn logbook." && model.notice == .savedByModel && model.phase == .ready)
    #expect(try await world.source()?.summary == "Mara finds the torn logbook.")
    #expect(!model.hasChanges)
  }

  @Test("should save the model's summary on a final chapter without touching its prose")
  func savesOnAFinalChapter() async throws {
    let world = try await AmendWorld.make(calls: [AmendWorld.reply])
    try await world.final()
    let model = world.summaryModel()
    await model.load()

    await model.summarize()

    let source = try #require(try await world.source())
    #expect(source.isFinal && source.summary == "Mara finds the torn logbook." && source.body == AmendWorld.prose)
  }

  @Test("should show the attempted summary and a conflict notice when the prose changed during the call")
  func showsTheConflict() async throws {
    let world = try await AmendWorld.make()
    try await world.draft()
    let model = world.summaryModel { _, chapter throws(ReviewRequestError) in throw .summary(.conflict(chapter: chapter, attempted: "Attempted summary.")) }
    await model.load()

    await model.summarize()

    #expect(model.notice == .conflict && model.summary == "Attempted summary." && model.failure == nil && model.hasChanges && model.canSave)
    #expect(AmendErrors.headline(code: ChapterSummaryError.conflict(chapter: 1, attempted: "").code) != nil)
  }

  @Test("should refuse an isolated draft's summary and save nothing while this device cannot write unrestricted text", .enabled(if: !UnrestrictedWriting.isAvailable))
  func refusesAnIsolatedSummaryWhileUnavailable() async throws {
    let world = try await AmendWorld.make(calls: [AmendWorld.reply])
    try await world.draft(isolated: true)
    let model = world.summaryModel()
    await model.load()

    await model.summarize()

    #expect(model.failure != nil && model.notice == nil)
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.source()?.summary == "")
  }

  @Test("should save a hand-written summary on a draft and on a final chapter")
  func savesAHandWrittenSummary() async throws {
    let world = try await AmendWorld.make()
    try await world.draft()
    try await world.final(2)
    let draft = world.summaryModel()
    await draft.load()
    draft.summary = "  Mara climbs.  "
    await draft.save()

    let final = SummarizeModel(context: world.context, chapter: 2, summarizer: nil)
    await final.load()
    final.summary = "Mara descends."
    await final.save()

    #expect(draft.phase == .saved && final.phase == .saved)
    #expect(try await world.source(1)?.summary == "Mara climbs.")
    #expect(try await world.source(2)?.summary == "Mara descends.")
  }

  @Test("should refuse a chapter with no prose with CHP_007 before any model call")
  func refusesNoProse() async throws {
    let world = try await AmendWorld.make()
    try await world.draft(" ")
    let model = world.summaryModel()
    await model.load()

    #expect(!model.canSummarize)
    await model.summarize()
    #expect(model.phase == .ready && world.provider.requests.isEmpty)
    do {
      _ = try await world.engine.summarize(novel: world.novel, chapter: 1)
      Issue.record("a blank chapter was summarized")
    } catch {
      #expect(error.code == "CHP_007")
    }
    #expect(AmendErrors.headline(code: "CHP_007") != nil)
  }

  @Test("should say jobs are not running when there is no engine")
  func refusesWithoutAnEngine() async throws {
    let world = try await AmendWorld.make()
    try await world.draft()
    let model = SummarizeModel(context: world.context, chapter: 1, summarizer: nil)
    await model.load()

    await model.summarize()

    #expect(model.failure == JobsErrors.notRunningHere)
  }
}
