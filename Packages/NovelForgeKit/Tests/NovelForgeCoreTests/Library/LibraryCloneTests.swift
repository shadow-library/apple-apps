import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Library clone")
struct LibraryCloneTests {
  private struct Source {
    let world: LibraryWorld
    let id: UUID
  }

  private func source() async throws -> Source {
    let world = try LibraryWorld.make()
    let target = WordTarget(min: 900, max: 1500)
    let id = try await world.create(NewNovel(title: "Ember", notes: "private notes", costTier: .performant, writingStyle: "Close third.", wordTarget: target))
    let changes = changing {
      $0.theme = .set("grief")
      $0.brief = .set("brief")
    }
    try await world.run { try Library.edit(novel: id, changes, in: &$0) }
    try await world.run {
      try Pages.create(novel: id, section: .world, slug: "city", frontmatter: ["title": "City"], body: "glass", in: &$0)
      try Pages.create(novel: id, section: .lore, slug: "myth", body: "old", in: &$0)
      try Pages.remove(novel: id, section: .lore, slug: "myth", in: &$0)
      try Entities.create(novel: id, entity: "mara", type: .character, name: "Mara", EntityDetails(status: "alive"), in: &$0)
      try Entities.create(novel: id, entity: "ghost", type: .character, name: "Ghost", in: &$0)
      try Entities.remove(novel: id, entity: "ghost", in: &$0)
      try Volumes.create(novel: id, volume: "one", ordinal: 0, title: "Book one", in: &$0)
      try Volumes.create(novel: id, volume: "two", ordinal: 1, in: &$0)
    }
    return Source(world: world, id: id)
  }

  private func clone(_ source: Source, _ copy: NovelCopy, id: UUID = UUID()) async throws -> UUID {
    try await source.world.store.writeDomain { transaction throws(DomainError) in try Library.clone(novel: source.id, as: copy, id: id, in: &transaction) }
  }

  @Test
  func shouldCopyTheSettingsPagesEntitiesAndVolumesIntoANewNovel() async throws {
    let source = try await source()
    let copy = try await clone(source, NovelCopy(name: "Ember II"))
    let record = try await source.world.novel(copy)
    #expect(
      record
        == NovelRecord(
          id: copy, name: "Ember II", title: "Ember", costTier: .known(.performant), wordTarget: WordTarget(min: 900, max: 1500), writingStyle: "Close third."))
    let world = source.world
    let page = try await world.store.read { try Pages.get(novel: copy, section: .world, slug: "city", in: $0) }
    #expect(page?.content == PageContent(frontmatter: ["title": "City"], body: "glass"))
    let entity = liveRecord(try await world.store.read { try EntityRecord.read(novel: copy, entity: "mara", in: $0) })
    #expect(entity == EntityRecord(novel: copy, entity: "mara", type: .known(.character), name: "Mara", status: "alive"))
    let volumes = try await world.store.read { try VolumeRecord.listing(novel: copy, in: $0).live.sorted { $0.ordinal < $1.ordinal }.map(\.volume) }
    #expect(volumes == ["one", "two"])
  }

  @Test
  func shouldNotCopyNotesStoryFieldsRemovedRecordsOrTheArchiveFlag() async throws {
    let source = try await source()
    try await source.world.run { try Library.archive(novel: source.id, in: &$0) }
    let copy = try await clone(source, NovelCopy(name: "Ember II"))
    let record = try await source.world.novel(copy)
    #expect(record?.theme == nil)
    #expect(record?.brief == nil)
    #expect(record?.archived == false)
    #expect(try await source.world.notes(copy) == "")
    let world = source.world
    #expect(try await world.store.read { try Pages.get(novel: copy, section: .lore, slug: "myth", in: $0) } == nil)
    #expect(liveRecord(try await world.store.read { try EntityRecord.read(novel: copy, entity: "ghost", in: $0) }) == nil)
  }

  @Test
  func shouldApplyTheModeAndWordTargetOverrides() async throws {
    let source = try await source()
    let target = WordTarget(min: 1200, max: 2400)
    let copy = try await clone(source, NovelCopy(name: "Ember II", contentMode: .unrestricted, wordTarget: target))
    let record = try await source.world.novel(copy)
    #expect(record?.contentMode == .known(.unrestricted))
    #expect(record?.wordTarget == target)
  }

  @Test
  func shouldLeaveTheSourceUntouched() async throws {
    let source = try await source()
    let before = try await source.world.novel(source.id)
    _ = try await clone(source, NovelCopy(name: "Ember II"))
    #expect(try await source.world.novel(source.id) == before)
    #expect(try await source.world.notes(source.id) == "private notes")
    #expect(try await source.world.list().novels.count == 2)
  }

  @Test
  func shouldCloneAnArchivedSource() async throws {
    let source = try await source()
    try await source.world.run { try Library.archive(novel: source.id, in: &$0) }
    let copy = try await clone(source, NovelCopy(name: "Ember II"))
    #expect(try await source.world.list().novels.map(\.id) == [copy])
  }

  @Test
  func shouldRefuseABlankNameAnUnknownSourceAnInvalidTargetAndATakenId() async throws {
    let source = try await source()
    let world = source.world
    let id = source.id
    await world.expect(.blank(field: "name")) { _ = try Library.clone(novel: id, as: NovelCopy(name: "  "), in: &$0) }
    let unknown = UUID()
    await world.expect(.novelNotFound(unknown)) { _ = try Library.clone(novel: unknown, as: NovelCopy(name: "x"), in: &$0) }
    await world.expect(.wordTargetInverted) { _ = try Library.clone(novel: id, as: NovelCopy(name: "x", wordTarget: WordTarget(min: 2000, max: 1000)), in: &$0) }
    await world.expect(.novelExists(id)) { _ = try Library.clone(novel: id, as: NovelCopy(name: "x"), id: id, in: &$0) }
  }

  @Test
  func shouldRefuseToCloneANovelWithRecordsItCannotReadAndWriteNothing() async throws {
    let source = try await source()
    let world = source.world
    let id = source.id
    try await SchemaFixture.set(EntityRecord.ref(novel: id, entity: "mara"), ["name": .bool(true)], in: world.store)
    let before = try await world.pendingChangeCount()
    await world.expect(.unreadableRecords(kind: "nf_entity", count: 1)) { _ = try Library.clone(novel: id, as: NovelCopy(name: "x"), in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldCopyEveryFieldOfAnEntityAVolumeAndAPage() async throws {
    let world = try LibraryWorld.make()
    let id = try await world.create(NewNovel(title: "Ember"))
    let entity = EntityRecord(
      novel: id, entity: "mara", type: .known(.character), name: "Mara", attributes: .object(["age": .string("31")]), significance: .known(.major), status: "alive",
      origin: .known(.seeded), notes: "n", motivation: "m", body: "b", appearance: "tall", wikiVisibility: .known(.hidden))
    let volume = VolumeRecord(novel: id, volume: "one", ordinal: 4, title: "Book one", objective: "o", body: "vb", goalMet: true)
    let content = try #require(PageContent(json: .object(["frontmatter": .object(["title": .string("City")]), "body": .string("glass"), "added_by_a_newer_version": .int(3)])))
    let page = PageRecord(novel: id, section: .world, slug: "city", content: content)
    try await world.run {
      try $0.create(entity)
      try $0.create(volume)
      try $0.create(page)
    }
    let copy = try await world.store.writeDomain { transaction throws(DomainError) in try Library.clone(novel: id, as: NovelCopy(name: "Copy"), in: &transaction) }
    let copiedEntity = liveRecord(try await world.store.read { try EntityRecord.read(novel: copy, entity: "mara", in: $0) })
    #expect(
      copiedEntity
        == EntityRecord(
          novel: copy, entity: "mara", type: entity.type, name: entity.name, attributes: entity.attributes, significance: entity.significance, status: entity.status,
          origin: entity.origin, notes: entity.notes, motivation: entity.motivation, body: entity.body, appearance: entity.appearance, wikiVisibility: entity.wikiVisibility))
    let copiedVolume = try await world.store.read { try VolumeRecord.listing(novel: copy, in: $0).live }
    #expect(copiedVolume == [VolumeRecord(novel: copy, volume: "one", ordinal: 4, title: "Book one", objective: "o", body: "vb", goalMet: true)])
    let copiedPage = try await world.store.read { try Pages.get(novel: copy, section: .world, slug: "city", in: $0) }
    #expect(copiedPage?.content == content)
  }

  @Test
  func shouldNameTheCopyWithTheTrimmedName() async throws {
    let source = try await source()
    let copy = try await clone(source, NovelCopy(name: "  Ember II \n"))
    #expect(try await source.world.novel(copy)?.name == "Ember II")
  }

  @Test
  func shouldRefuseToCloneANovelWithAPageOfAnUnknownSectionAndIgnoreOtherNovels() async throws {
    let source = try await source()
    let world = source.world
    let id = source.id
    let other = try await world.create(NewNovel(title: "Other"))
    let foreign = try NovelForgeKey(novel: other, .page(section: .unknown("bestiary"), slug: "wolves"))
    try await SchemaFixture.set(foreign.ref, ["natural_key": foreign.stored, "removed": false], in: world.store)
    _ = try await SchemaFixture.revise(foreign.ref, ["body": "Grey", "frontmatter": nil], in: world.store)
    _ = try await clone(source, NovelCopy(name: "fine"))
    let key = try NovelForgeKey(novel: id, .page(section: .unknown("bestiary"), slug: "wolves"))
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "removed": false], in: world.store)
    _ = try await SchemaFixture.revise(key.ref, ["body": "Grey", "frontmatter": nil], in: world.store)
    let before = try await world.pendingChangeCount()
    await world.expect(.unreadableRecords(kind: "nf_page", count: 1)) { _ = try Library.clone(novel: id, as: NovelCopy(name: "x"), in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }
}
