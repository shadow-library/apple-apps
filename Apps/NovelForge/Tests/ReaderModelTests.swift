import Foundation
import NovelForgeCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("ReaderModel")
struct ReaderModelTests {
  private struct Fixture {
    let store: VaultStore
    let novel: UUID
    let context: NovelContext
  }

  private func makeFixture() async throws -> Fixture {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    return Fixture(store: store, novel: novel, context: NovelContext(store: store, novel: novel))
  }

  private func finalize(_ chapter: Int, body: String, in fixture: Fixture) async throws {
    let novel = fixture.novel
    try await fixture.store.write { transaction in
      let record = try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(title: "Done", body: body))
      _ = try record.create(in: &transaction)
    }
  }

  private func content(_ chapter: Int, in fixture: Fixture) async throws -> ChapterContent {
    try await fixture.store.load(ChapterContent.self, ChapterLocator(novel: fixture.novel, chapter: chapter))
  }

  private func draft(_ chapter: Int, in fixture: Fixture) async throws -> ChapterContent.Draft {
    guard case .draft(let draft) = try await content(chapter, in: fixture).body else {
      Issue.record("chapter \(chapter) is not a draft")
      throw CancellationError()
    }
    return draft
  }

  @Test("should list a final chapter and a started draft with their stages")
  func listsStages() async throws {
    let fixture = try await makeFixture()
    try await finalize(1, body: "Final prose.", in: fixture)
    let model = ReaderModel(context: fixture.context)

    let started = await model.startNext()
    let outline = try await fixture.store.load(ChapterOutline.self, fixture.novel)

    #expect(started == 2)
    #expect(outline.rows.value?.map(\.chapter) == [1, 2])
    #expect(outline.rows.value?.map(\.stage) == [.final, .drafted])
    #expect(outline.nextWritable == 3)
    #expect(outline.groups.map(\.chapters) == [[1, 2]])
  }

  @Test("should head and group the list from the amended final chapter and the plans' volumes")
  func headsAndGroups() async throws {
    let fixture = try await makeFixture()
    let novel = fixture.novel
    try await fixture.store.writeDomain { transaction throws(DomainError) in
      try Volumes.create(novel: novel, volume: "ashes", title: "Ashes", in: &transaction)
      try Volumes.create(novel: novel, volume: "embers", title: "Embers", in: &transaction)
    }
    try await fixture.store.write { transaction in
      _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: ChapterPlanContent(title: "Plan one", body: "Plan.", volume: "embers")).create(in: &transaction)
      _ = try ChapterPlanRecord(novel: novel, chapter: 2, content: ChapterPlanContent(title: "The Pass", body: "Plan.", volume: "embers")).create(in: &transaction)
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(title: "Burned", body: "Ash.", volume: "ashes")).create(in: &transaction)
      _ = try FinalChapterRecord.amend(try FinalChapterRecord.ref(novel: novel, chapter: 1), FinalChapterText(title: "The Burned City", body: "Ash."), in: &transaction)
    }

    let outline = try await fixture.store.load(ChapterOutline.self, novel)

    #expect(outline.headings == .available([1: "The Burned City", 2: "The Pass"]))
    #expect(outline.volumes.value?.map(\.key) == ["ashes", "embers"])
    #expect(outline.volumes.value?.map(\.planFirst) == [1, 2])
    #expect(outline.volumes.value?.map(\.planLast) == [1, 2])
    #expect(outline.groups.map(\.chapters) == [[1], [2]])
  }

  @Test("should read a final chapter as its canon")
  func readsFinal() async throws {
    let fixture = try await makeFixture()
    try await finalize(1, body: "Final prose.", in: fixture)

    let loaded = try await content(1, in: fixture)

    guard case .final(let final) = loaded.body else {
      Issue.record("expected a final chapter")
      return
    }
    #expect(final.body == "Final prose.")
    #expect(final.title == "Done")
    #expect(final.amended == false)
    #expect(loaded.row?.stage == .final)
  }

  @Test("should read the current draft head of a started chapter")
  func readsDraft() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)
    _ = await model.startNext()

    let head = try await draft(1, in: fixture)

    #expect(head.body.isEmpty)
    #expect(head.working == nil)
    #expect(head.source == .handEdited)
  }

  @Test("should show a missing chapter as not found")
  func missingChapter() async throws {
    let fixture = try await makeFixture()

    let loaded = try await content(99, in: fixture)

    #expect(loaded.body == .missing)
    #expect(loaded.row == nil)
  }

  @Test("should save an edit through the working copy and keep the text readable")
  func savesEdit() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)
    _ = await model.startNext()
    let editor = model.editor(for: 1, draft: try await draft(1, in: fixture))

    editor.text.body = "The tide turned."
    #expect(editor.isDirty)
    let saved = await editor.save()
    let afterSave = try await draft(1, in: fixture)

    #expect(saved)
    #expect(!editor.isDirty)
    #expect(afterSave.editable.body == "The tide turned.")

    let committed = await editor.finish()
    let afterCommit = try await draft(1, in: fixture)

    #expect(committed)
    #expect(afterCommit.body == "The tide turned.")
    #expect(afterCommit.working == nil)
  }

  @Test("should lock the editor when the chapter turned final under it")
  func lockedSave() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)
    _ = await model.startNext()
    let editor = model.editor(for: 1, draft: try await draft(1, in: fixture))
    try await finalize(1, body: "Canon.", in: fixture)

    editor.text.body = "Too late."
    let saved = await editor.save()

    #expect(!saved)
    #expect(editor.status == .locked)
    #expect(editor.needsAttention)
  }

  @Test("should show a localized headline when a write is refused")
  func refusedWrite() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)

    let restored = await model.restore(revision: "r1", in: 9, current: "r0")

    #expect(!restored)
    #expect(model.failure?.error.headline == String(localized: "This chapter has no draft to change. It may have been removed on another device.", table: "Reader"))
    #expect(model.failure?.error.detail == "DRF_001")
  }

  @Test("should refuse to import into a chapter that is not the next one")
  func refusedImport() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)

    let imported = await model.importProse("Prose.", into: 5)

    #expect(!imported)
    #expect(model.failure?.error.headline.contains("chapter 1") == true)
  }

  @Test("should import a draft, list its versions and restore the first one")
  func importsAndRestores() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)
    _ = await model.startNext()

    #expect(await model.importProse("First import.", into: 1))
    #expect(await model.importProse("Second import.", into: 1))
    let versions = try await fixture.store.load(ChapterVersions.self, ChapterLocator(novel: fixture.novel, chapter: 1))
    guard case .listed(let entries, _) = versions.state else {
      Issue.record("expected versions")
      return
    }
    let first = try #require(entries.first { $0.excerpt == "First import." })
    let current = try #require(entries.first { $0.version.isCurrent })

    #expect(entries.count >= 3)
    #expect(current.excerpt == "Second import.")
    #expect(await model.restore(revision: first.version.revision, in: 1, current: current.version.revision))

    let restored = try await draft(1, in: fixture)
    #expect(restored.body == "First import.")
    #expect(restored.source == .restored)
    #expect(model.failure == nil)
  }

  @Test("should report no versions for a final chapter")
  func finalHasNoVersions() async throws {
    let fixture = try await makeFixture()
    try await finalize(1, body: "Canon.", in: fixture)

    let versions = try await fixture.store.load(ChapterVersions.self, ChapterLocator(novel: fixture.novel, chapter: 1))

    #expect(versions.state == .final)
  }

  @Test("should report a missing novel")
  func missingNovel() async throws {
    let fixture = try await makeFixture()

    let outline = try await fixture.store.load(ChapterOutline.self, UUID())

    #expect(!outline.presence.isPresent)
  }

  @Test("should tell an unstarted next chapter from a removed one and from one awaiting its draft")
  func missingChapterKinds() async throws {
    let fixture = try await makeFixture()
    try await finalize(1, body: "Final prose.", in: fixture)
    let list = try await fixture.store.load(ChapterList.self, fixture.novel)
    let rows = try #require(list.rows.value)
    let next = ChapterOutline.nextWritable(in: rows)
    let ready = ChapterListing.ready(nextWritable: next)

    #expect(next == 2)
    #expect(MissingChapter(row: nil, chapter: 2, listing: ready) == .unstarted)
    #expect(MissingChapter(row: nil, chapter: 7, listing: ready) == .removed)
    #expect(MissingChapter(row: nil, chapter: 2, listing: .pending) == .pending)
    #expect(MissingChapter(row: nil, chapter: 2, listing: .unavailable) == .undetermined)
    #expect(MissingChapter(row: rows.first, chapter: 1, listing: ready) == .awaitingDraft)
    #expect(MissingChapter(row: rows.first, chapter: 1, listing: .pending) == .awaitingDraft)
  }

  @Test("should start the unstarted chapter the missing page offers")
  func startsTheUnstartedChapter() async throws {
    let fixture = try await makeFixture()
    let model = ReaderModel(context: fixture.context)
    let loaded = try await content(1, in: fixture)
    guard case .missing = loaded.body else {
      Issue.record("expected a missing chapter")
      return
    }

    let started = await model.startNext()

    #expect(started == 1)
    _ = try await draft(1, in: fixture)
  }
}

extension NovelPresence {
  fileprivate var isPresent: Bool {
    if case .present = self { true } else { false }
  }
}
