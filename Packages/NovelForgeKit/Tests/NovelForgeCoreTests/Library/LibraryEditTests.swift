import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Library edit, archive and notes")
struct LibraryEditTests {
  private func edit(_ world: LibraryWorld, _ id: UUID, _ changes: NovelChanges) async throws {
    try await world.run { try Library.edit(novel: id, changes, in: &$0) }
  }

  @Test
  func shouldEditEachStoryFieldTrimmedAndClearItWhenBlank() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    var changes = NovelChanges()
    changes.theme = .set("  grief  ")
    changes.endingQuestion = .set("Will she stay?")
    changes.ending = .set("She leaves.")
    changes.readerPromise = .set("A slow burn")
    changes.protagonist = .set("mara")
    changes.opposition = .set("the tide")
    changes.brief = .set("A brief")
    changes.writingStyle = .set(" Present tense. ")
    try await edit(world, id, changes)
    let edited = try await world.novel(id)
    #expect(edited?.theme == "grief")
    #expect(edited?.endingQuestion == "Will she stay?")
    #expect(edited?.ending == "She leaves.")
    #expect(edited?.readerPromise == "A slow burn")
    #expect(edited?.protagonist == "mara")
    #expect(edited?.opposition == "the tide")
    #expect(edited?.brief == "A brief")
    #expect(edited?.writingStyle == "Present tense.")
    var clear = NovelChanges()
    clear.theme = .set("   ")
    clear.ending = .set(nil)
    try await edit(world, id, clear)
    let cleared = try await world.novel(id)
    #expect(cleared?.theme == nil)
    #expect(cleared?.ending == nil)
    #expect(cleared?.opposition == "the tide")
  }

  @Test
  func shouldEditTheTitleModeTierAndWordTargetAndLeaveTheRestAlone() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember", notes: "n"))
    var changes = NovelChanges()
    changes.title = .set(" Cinder ")
    changes.contentMode = .set(.known(.unrestricted))
    changes.costTier = .set(.known(.economy))
    changes.wordTarget = .set(WordTarget(min: 800, max: 1600))
    try await edit(world, id, changes)
    let edited = try await world.novel(id)
    #expect(edited?.title == "Cinder")
    #expect(edited?.name == "Ember")
    #expect(edited?.contentMode == .known(.unrestricted))
    #expect(edited?.costTier == .known(.economy))
    #expect(edited?.wordTarget == WordTarget(min: 800, max: 1600))
    var restore = NovelChanges()
    restore.wordTarget = .set(nil)
    restore.title = .set(" ")
    try await edit(world, id, restore)
    let cleared = try await world.novel(id)
    #expect(cleared?.wordTarget == nil)
    #expect(cleared?.title == nil)
    #expect(try await world.notes(id) == "n")
  }

  @Test
  func shouldRefuseAnEditThatChangesNothing() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    await world.expect(.noChanges) { try Library.edit(novel: id, NovelChanges(), in: &$0) }
  }

  @Test
  func shouldRefuseEditsToAnUnknownNovelAndInvalidValues() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    let unknown = UUID()
    let title = changing { $0.title = .set("x") }
    await world.expect(.novelNotFound(unknown)) { try Library.edit(novel: unknown, title, in: &$0) }
    let long = changing { $0.title = .set(String(repeating: "a", count: 501)) }
    await world.expect(.tooLong(field: "title", limit: 500)) { try Library.edit(novel: id, long, in: &$0) }
    let target = changing { $0.wordTarget = .set(WordTarget(min: 2000, max: 1000)) }
    await world.expect(.wordTargetInverted) { try Library.edit(novel: id, target, in: &$0) }
    let low = changing { $0.wordTarget = .set(WordTarget(min: 100, max: 1000)) }
    await world.expect(.belowMinimum(field: "wordTarget.min", minimum: 500)) { try Library.edit(novel: id, low, in: &$0) }
  }

  @Test
  func shouldMoveANovelBetweenTheMainListAndTheArchive() async throws {
    let world = try LibraryWorld.make()
    let first = try await world.create(NewNovel(title: "Ember"))
    let second = try await world.create(NewNovel(title: "Cinder"))
    try await world.run { try Library.archive(novel: first, in: &$0) }
    #expect(try await world.list().novels.map(\.id) == [second])
    #expect(try await world.archivedList().novels.map(\.id) == [first])
    try await world.run { try Library.restore(novel: first, in: &$0) }
    #expect(try await world.list().novels.map(\.name) == ["Cinder", "Ember"])
    #expect(try await world.archivedList().novels.isEmpty)
  }

  @Test
  func shouldKeepEverythingElseOfAnArchivedNovel() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember", notes: "n"))
    try await world.run { try Library.archive(novel: id, in: &$0) }
    let archived = try await world.novel(id)
    #expect(archived == NovelRecord(id: id, name: "Ember", title: "Ember", archived: true))
    #expect(try await world.notes(id) == "n")
  }

  @Test
  func shouldWriteNothingWhenTheNovelIsAlreadyInTheRequestedState() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    let before = try await world.pendingChangeCount()
    try await world.run { try Library.restore(novel: id, in: &$0) }
    try await world.run { try Library.archive(novel: id, in: &$0) }
    let archived = try await world.pendingChangeCount()
    try await world.run { try Library.archive(novel: id, in: &$0) }
    #expect(archived == before + 1)
    #expect(try await world.pendingChangeCount() == archived)
  }

  @Test
  func shouldRefuseToArchiveOrRestoreAnUnknownNovel() async throws {
    let world = try LibraryWorld.make()
    let unknown = UUID()
    await world.expect(.novelNotFound(unknown)) { try Library.archive(novel: unknown, in: &$0) }
    await world.expect(.novelNotFound(unknown)) { try Library.restore(novel: unknown, in: &$0) }
  }

  @Test
  func shouldAllowEditingAnArchivedNovel() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    try await world.run { try Library.archive(novel: id, in: &$0) }
    var changes = NovelChanges()
    changes.theme = .set("grief")
    try await edit(world, id, changes)
    let record = try await world.novel(id)
    #expect(record?.theme == "grief")
    #expect(record?.archived == true)
  }

  @Test
  func shouldCountANovelItCannotReadWithoutListingIt() async throws {
    let world = try LibraryWorld.make()
    let readable = try await world.create(NewNovel(title: "Ember"))
    let broken = UUID()
    try await SchemaFixture.set(NovelForgeKey.novel(broken), ["name": .bool(true), "archived": .bool(false)], in: world.store)
    let list = try await world.list()
    #expect(list.novels.map(\.id) == [readable])
    #expect(list.unreadable == 1)
  }

  @Test
  func shouldOrderTheListByNameThenId() async throws {
    let world = try LibraryWorld.make()
    let low = SchemaFixture.uuid("00000000-0000-4000-8000-000000000001")
    let high = SchemaFixture.uuid("00000000-0000-4000-8000-000000000002")
    _ = try await world.create(NewNovel(title: "Same"), id: high)
    _ = try await world.create(NewNovel(title: "Same"), id: low)
    _ = try await world.create(NewNovel(title: "Alpha"))
    #expect(try await world.list().novels.map(\.name) == ["Alpha", "Same", "Same"])
    #expect(try await world.list().novels.dropFirst().map(\.id) == [low, high])
  }

  @Test
  func shouldReplaceTheNotesAsRevisionsAndWriteNothingForIdenticalNotes() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember", notes: "one"))
    try await world.run { try Library.replaceNotes(novel: id, text: " two ", in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try Library.replaceNotes(novel: id, text: "two", in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
    #expect(try await world.notes(id) == "two")
    let history = try await world.store.read { try AuthorNotesRecord.history(novel: id, in: $0) }
    #expect(history.history?.revisions.count == 2)
  }

  @Test
  func shouldCreateTheNotesOnFirstReplaceAndClearThemWhenBlank() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    try await world.run { try Library.replaceNotes(novel: id, text: "  ", in: &$0) }
    #expect(try await world.pendingChangeCount() == 1)
    try await world.run { try Library.replaceNotes(novel: id, text: "hello", in: &$0) }
    #expect(try await world.notes(id) == "hello")
    try await world.run { try Library.replaceNotes(novel: id, text: "", in: &$0) }
    #expect(try await world.notes(id) == "")
  }

  @Test
  func shouldRefuseNotesOverTheLimitsAndForAnUnknownNovel() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    await world.expect(.notesTooLong(words: 10_001, maximum: 10_000)) {
      try Library.replaceNotes(novel: id, text: Array(repeating: "w", count: 10_001).joined(separator: " "), in: &$0)
    }
    await world.expect(.tooLong(field: "notes", limit: 100_000)) { try Library.replaceNotes(novel: id, text: String(repeating: "a", count: 100_001), in: &$0) }
    let unknown = UUID()
    await world.expect(.novelNotFound(unknown)) { try Library.replaceNotes(novel: unknown, text: "x", in: &$0) }
  }
}
