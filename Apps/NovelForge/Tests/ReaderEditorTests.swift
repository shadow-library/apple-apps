import Foundation
import NovelForgeCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Reader editor persistence")
struct ReaderEditorTests {
  private struct Fixture {
    let store: VaultStore
    let novel: UUID
    let model: ReaderModel
    let work: UnsavedWork
  }

  private func makeFixture() async throws -> Fixture {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    let work = UnsavedWork()
    return Fixture(store: store, novel: novel, model: ReaderModel(context: NovelContext(store: store, novel: novel), unsavedWork: work), work: work)
  }

  private func draft(_ chapter: Int, in fixture: Fixture) async throws -> ChapterContent.Draft {
    let content = try await fixture.store.load(ChapterContent.self, ChapterLocator(novel: fixture.novel, chapter: chapter))
    guard case .draft(let draft) = content.body else {
      Issue.record("chapter \(chapter) is not a draft")
      throw CancellationError()
    }
    return draft
  }

  private func heldText(_ chapter: Int, in fixture: Fixture) async throws -> String? {
    let novel = fixture.novel
    return try await fixture.store.read { transaction in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database)?.content.body }
  }

  private func started(_ fixture: Fixture, delay: Duration = .seconds(3600)) async throws -> ChapterEditorModel {
    _ = await fixture.model.startNext()
    let current = try await draft(1, in: fixture)
    return ChapterEditorModel(chapter: 1, draft: current, service: fixture.model.service, autosaveDelay: delay, maximumWait: delay)
  }

  @Test("should keep the text of a conflict as a version once the chapter is written again")
  func conflictSurvives() async throws {
    let fixture = try await makeFixture()
    let editor = try await started(fixture)
    _ = try await fixture.model.service.importDraft(chapter: 1, prose: "Theirs.", base: nil)

    editor.text.body = "Mine, over a moved head."
    let saved = await editor.save()
    let finished = await editor.finish()

    #expect(!saved && !finished)
    #expect(editor.status == .conflict)
    #expect(try await heldText(1, in: fixture) == "Mine, over a moved head.")
    let head = try await draft(1, in: fixture).revision
    _ = try await fixture.model.service.save(chapter: 1, title: nil, body: "Later.", base: head)
    let versions = try await fixture.store.load(ChapterVersions.self, ChapterLocator(novel: fixture.novel, chapter: 1))
    guard case .listed(let entries, _) = versions.state else {
      Issue.record("expected versions")
      return
    }
    #expect(entries.contains { $0.excerpt == "Mine, over a moved head." })
  }

  @Test("should keep the text typed over a chapter that turned final")
  func lockedSurvives() async throws {
    let fixture = try await makeFixture()
    let editor = try await started(fixture)
    let novel = fixture.novel
    try await fixture.store.write { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: "Canon.")).create(in: &transaction)
    }

    editor.text.body = "Typed too late."
    _ = await editor.finish()

    #expect(editor.status == .locked)
    #expect(editor.needsAttention)
    #expect(try await heldText(1, in: fixture) == "Typed too late.")
  }

  @Test("should keep the text typed over a draft that was removed")
  func deletedSurvives() async throws {
    let fixture = try await makeFixture()
    let editor = try await started(fixture)
    let novel = fixture.novel
    try await fixture.store.write { transaction in
      _ = try DraftRecord.remove(try DraftRecord.ref(novel: novel, chapter: 1), in: &transaction)
    }

    editor.text.body = "Typed after removal."
    _ = await editor.finish()

    #expect(editor.status == .deleted)
    #expect(try await heldText(1, in: fixture) == "Typed after removal.")
  }

  @Test("should keep the text in the editor when a save fails")
  func failedStaysInTheEditor() async throws {
    let fixture = try await makeFixture()
    _ = await fixture.model.startNext()
    let current = try await draft(1, in: fixture)
    let orphan = ReaderService(store: fixture.store, novel: UUID())
    let editor = ChapterEditorModel(chapter: 1, draft: current, service: orphan, autosaveDelay: .seconds(3600), maximumWait: .seconds(3600))

    editor.text.body = "Unsaved."
    let saved = await editor.save()

    #expect(!saved)
    guard case .failed(let error) = editor.status else {
      Issue.record("expected a failed save")
      return
    }
    #expect(!error.headline.isEmpty)
    #expect(editor.text.body == "Unsaved.")
    #expect(editor.needsAttention)
  }

  @Test("should flush a registered editor through the unsaved-work registry")
  func registryFlushes() async throws {
    let fixture = try await makeFixture()
    _ = await fixture.model.startNext()
    let editor = fixture.model.editor(for: 1, draft: try await draft(1, in: fixture))
    #expect(fixture.work.hasWork)

    editor.text.body = "Typed just before the app closed."
    await fixture.work.flushAll()

    #expect(try await draft(1, in: fixture).editable.body == "Typed just before the app closed.")
    #expect(!editor.isDirty)
    editor.leave()
    fixture.model.release(1)
    #expect(!fixture.work.hasWork)
  }

  @Test("should save during continuous typing once the maximum wait passes")
  func maximumWait() async throws {
    let fixture = try await makeFixture()
    _ = await fixture.model.startNext()
    let typing = ChapterEditorModel(
      chapter: 1, draft: try await draft(1, in: fixture), service: fixture.model.service, autosaveDelay: .milliseconds(200), maximumWait: .milliseconds(400))

    for index in 1...30 {
      typing.text.body = String(repeating: "word ", count: index)
      typing.textChanged()
      try await Task.sleep(for: .milliseconds(40))
    }
    let stored = try await draft(1, in: fixture).editable.body

    #expect(!stored.isEmpty)
    await typing.flush()
  }

  @Test("should drop a clean reader of a removed novel and keep one with unsaved work")
  func prunesOnlyCleanReaders() async throws {
    let fixture = try await makeFixture()
    let readers = NovelReaders()
    let context = NovelContext(store: fixture.store, novel: fixture.novel)
    let model = readers.model(for: context)
    _ = await model.startNext()
    let editor = model.editor(for: 1, draft: try await draft(1, in: fixture))

    editor.text.body = "Unsaved."
    readers.prune(keeping: [])
    #expect(readers.model(for: context) === model)

    editor.leave()
    model.release(1)
    readers.prune(keeping: [])
    #expect(readers.model(for: context) !== model)
  }

  @Test("should keep held text reachable over a final chapter after leaving and after a restart, until discarded")
  func keptTextIsReachable() async throws {
    let fixture = try await makeFixture()
    let editor = try await started(fixture)
    let novel = fixture.novel
    try await fixture.store.write { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: "Canon.")).create(in: &transaction)
    }
    editor.text.body = "Typed too late."
    _ = await editor.finish()
    await editor.flush()
    editor.leave()
    #expect(!editor.needsAttention)

    let locator = ChapterLocator(novel: novel, chapter: 1)
    let afterLeaving = try await fixture.store.load(ChapterContent.self, locator)
    #expect(afterLeaving.kept?.body == "Typed too late.")
    let restarted = ReaderModel(context: NovelContext(store: fixture.store, novel: novel), unsavedWork: UnsavedWork())
    let afterRestart = try await fixture.store.load(ChapterContent.self, locator)
    #expect(afterRestart.kept?.body == "Typed too late.")

    await restarted.discardKept(in: 1)

    #expect(try await fixture.store.load(ChapterContent.self, locator).kept == nil)
    #expect(try await heldText(1, in: fixture) == nil)
  }

  @Test("should show the kept text of a conflict beside the versions and not as the draft's own text")
  func keptConflictText() async throws {
    let fixture = try await makeFixture()
    let editor = try await started(fixture)
    _ = try await fixture.model.service.importDraft(chapter: 1, prose: "Theirs.", base: nil)
    editor.text.body = "Mine."
    _ = await editor.finish()
    editor.leave()

    let locator = ChapterLocator(novel: fixture.novel, chapter: 1)
    let content = try await fixture.store.load(ChapterContent.self, locator)
    let versions = try await fixture.store.load(ChapterVersions.self, locator)

    #expect(content.kept?.body == "Mine.")
    guard case .listed(_, let kept) = versions.state else {
      Issue.record("expected versions")
      return
    }
    #expect(kept?.body == "Mine.")
  }

  @Test("should not call a working copy over the live head kept")
  func workingCopyIsNotKept() async throws {
    let fixture = try await makeFixture()
    let editor = try await started(fixture)
    editor.text.body = "Held over the head."
    await editor.flush()

    let content = try await fixture.store.load(ChapterContent.self, ChapterLocator(novel: fixture.novel, chapter: 1))

    #expect(content.kept == nil)
  }

  @Test("should unregister an editor's flush when its model is released")
  func modelReleaseUnregisters() async throws {
    let fixture = try await makeFixture()
    var model: ReaderModel? = ReaderModel(context: NovelContext(store: fixture.store, novel: fixture.novel), unsavedWork: fixture.work)
    _ = await model?.startNext()
    _ = model?.editor(for: 1, draft: try await draft(1, in: fixture))
    #expect(fixture.work.hasWork)

    model = nil
    for _ in 0..<12_000 where fixture.work.hasWork { try await Task.sleep(for: .milliseconds(10)) }

    #expect(!fixture.work.hasWork)
  }

  @Test("should stop waiting for a flush that ignores cancellation once the limit passes")
  func flushTimeout() async {
    let work = UnsavedWork()
    _ = work.register { await Task.detached { blockingSleep(seconds: 2) }.value }
    let clock = ContinuousClock()

    let elapsed = await clock.measure { await work.flushAll(within: .milliseconds(200)) }

    #expect(elapsed < .milliseconds(1000))
  }
}

private nonisolated func blockingSleep(seconds: TimeInterval) {
  Thread.sleep(forTimeInterval: seconds)
}
