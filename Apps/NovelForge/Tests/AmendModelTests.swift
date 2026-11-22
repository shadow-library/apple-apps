import Foundation
import NovelForgeCore
import ShadowAppShell
import Testing

@testable import NovelForge

@MainActor
@Suite("AmendModel")
struct AmendModelTests {
  private func model(_ world: AmendWorld, chapter: Int = 1) async throws -> AmendModel {
    guard case .final(let final) = try await world.content(chapter).body else {
      Issue.record("chapter \(chapter) is not final")
      throw CancellationError()
    }
    return AmendModel(context: world.context, chapter: chapter, final: final)
  }

  @Test("should replace a final chapter's prose through the core and keep it final")
  func amendsTheProse() async throws {
    let world = try await AmendWorld.make()
    try await world.final()
    let model = try await model(world)
    model.body = "Mara climbed the stairs at dawn."

    await model.amend()

    #expect(model.phase == .amended)
    guard case .final(let final) = try await world.content().body else { throw CancellationError() }
    #expect(final.body == "Mara climbed the stairs at dawn." && final.title == "Done" && final.amended)
  }

  @Test("should send a changed title and note and keep the stored ones when they are blank")
  func sendsTitleAndNote() async throws {
    let world = try await AmendWorld.make()
    try await world.final()
    let model = try await model(world)
    model.title = "  Ash  "
    model.note = " Thanks for reading "

    #expect(model.amendment == ChapterAmendment(content: AmendWorld.prose, title: "Ash", note: "Thanks for reading"))
    model.title = " "
    model.note = ""
    #expect(model.amendment == ChapterAmendment(content: AmendWorld.prose, title: nil, note: nil))
  }

  @Test("should not amend blank prose")
  func refusesBlankProse() async throws {
    let world = try await AmendWorld.make()
    try await world.final()
    let model = try await model(world)
    model.body = " \n "

    await model.amend()

    #expect(!model.canAmend && model.phase == .editing)
  }

  @Test("should refuse a chapter that is only a draft with CHP_006 and its headline")
  func refusesADraft() async throws {
    let world = try await AmendWorld.make()
    try await world.draft()
    let model = AmendModel(context: world.context, chapter: 1, final: ChapterContent.Final(title: nil, body: "x", note: nil, amended: false))

    await model.amend()

    guard case .failed(let error) = model.phase else { throw CancellationError() }
    #expect(error.detail == "CHP_006" && error.headline == AmendErrors.headline(code: "CHP_006"))
    model.dismissFailure()
    #expect(model.phase == .editing)
  }

  @Test("should refuse a chapter that does not exist with CHP_001")
  func refusesAMissingChapter() async throws {
    let world = try await AmendWorld.make()
    let model = AmendModel(context: world.context, chapter: 4, final: ChapterContent.Final(title: nil, body: "x", note: nil, amended: false))

    await model.amend()

    guard case .failed(let error) = model.phase else { throw CancellationError() }
    #expect(error.detail == "CHP_001" && error.headline == AmendErrors.headline(code: "CHP_001"))
  }

  @Test("should give every refusal a headline of its own")
  func headlinesEveryRefusal() {
    let codes = ["CHP_001", "CHP_006", "CHP_007", "DRF_001", "DRF_013", "DRF_019", "PRJ_001", "domain.empty", "routing.consent_required"]
    for code in codes { #expect(AmendErrors.headline(code: code) != nil, "no headline for \(code)") }
    for code in ["EXP_001", "PRJ_001", "export.unreadable_chapters", "export.archive_too_many_entries", "export.archive_entry_too_large", "export.archive_too_large"] {
      #expect(ExportErrors.headline(code: code) != nil, "no export headline for \(code)")
    }
    #expect(AmendErrors.headline(code: "CHP_999") == nil)
  }
}
