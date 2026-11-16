import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Library create")
struct LibraryCreateTests {
  @Test
  func shouldCreateANovelNamedByItsTrimmedTitleWithTheReferenceDefaults() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "  Ember  "))
    #expect(try await world.novel(id) == NovelRecord(id: id, name: "Ember", title: "Ember"))
    #expect(try await world.notes(id) == "")
  }

  @Test
  func shouldCreateTheAuthorsNotesWithTheNovelTrimmed() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember", notes: "\n  A city of glass.  \n"))
    #expect(try await world.notes(id) == "A city of glass.")
  }

  @Test
  func shouldWriteNoNotesForBlankNotes() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember", notes: "   "))
    let reading = try await world.store.read { try AuthorNotesRecord.read(novel: id, in: $0) }
    #expect(reading == .absent)
  }

  @Test
  func shouldStoreTheChosenModeTierStyleAndWordTarget() async throws {
    let world = try LibraryWorld.make()
    let target = WordTarget(min: 1000, max: 2000)
    let input = NewNovel(title: "Ember", contentMode: .unrestricted, costTier: .performant, writingStyle: "  Close third.  ", wordTarget: target)
    let id = try await world.create(input)
    #expect(
      try await world.novel(id)
        == NovelRecord(id: id, name: "Ember", title: "Ember", contentMode: .known(.unrestricted), costTier: .known(.performant), wordTarget: target, writingStyle: "Close third."))
  }

  @Test
  func shouldTreatABlankWritingStyleAsNone() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember", writingStyle: " \n "))
    #expect(try await world.novel(id)?.writingStyle == nil)
  }

  @Test
  func shouldRefuseABlankTitle() async throws {
    let world = try LibraryWorld.make()
    await world.expect(.blank(field: "title")) { _ = try Library.create(NewNovel(title: " \t "), in: &$0) }
    await world.expect(.blank(field: "title")) { _ = try Library.create(NewNovel(title: ""), in: &$0) }
  }

  @Test
  func shouldAcceptATitleOfExactlyTheLimitAndRefuseOneCharacterMore() async throws {
    let world = try LibraryWorld.make()
    _ = try await world.create(NewNovel(title: String(repeating: "a", count: 255)))
    await world.expect(.tooLong(field: "title", limit: 255)) { _ = try Library.create(NewNovel(title: String(repeating: "a", count: 256)), in: &$0) }
  }

  @Test
  func shouldRefuseNotesOverTheCharacterLimit() async throws {
    let world = try LibraryWorld.make()
    await world.expect(.tooLong(field: "notes", limit: 100_000)) {
      _ = try Library.create(NewNovel(title: "Ember", notes: String(repeating: "a", count: 100_001)), in: &$0)
    }
  }

  @Test
  func shouldRefuseNotesOverTheWordLimitAndAcceptTheLimitExactly() async throws {
    let world = try LibraryWorld.make()
    let over = Array(repeating: "w", count: 10_001).joined(separator: " ")
    await world.expect(.notesTooLong(words: 10_001, maximum: 10_000)) { _ = try Library.create(NewNovel(title: "Ember", notes: over), in: &$0) }
    let exact = Array(repeating: "w", count: 10_000).joined(separator: " ")
    let id = try await world.create(NewNovel(title: "Ember", notes: exact))
    #expect(try await world.notes(id) == exact)
  }

  @Test
  func shouldCheckTheWordTargetBoundsAndOrder() async throws {
    let world = try LibraryWorld.make()
    func create(_ target: WordTarget) -> LibraryBody { { _ = try Library.create(NewNovel(title: "Ember", wordTarget: target), in: &$0) } }
    await world.expect(.belowMinimum(field: "wordTarget.min", minimum: 500), create(WordTarget(min: 499, max: 2000)))
    await world.expect(.aboveMaximum(field: "wordTarget.max", maximum: 6000), create(WordTarget(min: 1000, max: 6001)))
    await world.expect(.wordTargetInverted, create(WordTarget(min: 2000, max: 2000)))
    await world.expect(.wordTargetInverted, create(WordTarget(min: 3000, max: 2000)))
    _ = try await world.create(NewNovel(title: "Ember", wordTarget: WordTarget(min: 500, max: 6000)))
  }

  @Test
  func shouldRefuseAnIdThatAlreadyNamesANovel() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    await world.expect(.novelExists(id)) { _ = try Library.create(NewNovel(title: "Other"), id: id, in: &$0) }
    #expect(try await world.novel(id)?.name == "Ember")
  }

  @Test
  func shouldWriteNothingWhenACreateIsRefused() async throws {
    let world = try LibraryWorld.make()
    await world.expect(.notesTooLong(words: 10_001, maximum: 10_000)) {
      _ = try Library.create(NewNovel(title: "Ember", notes: Array(repeating: "w", count: 10_001).joined(separator: " ")), in: &$0)
    }
    #expect(try await world.pendingChangeCount() == 0)
    #expect(try await world.list().novels.isEmpty)
  }
}
