import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Entities")
struct EntityOperationTests {
  @Test
  func shouldCreateAnEntityWithOnlyItsTypeAndName() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara"))
  }

  @Test
  func shouldCreateAnEntityWithEveryField() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let details = EntityDetails(significance: .major, status: "alive", origin: .seeded, notes: "n", motivation: "m", body: "b", appearance: "tall")
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", details, in: &$0) }
    #expect(
      liveRecord(try await world.entity("mara"))
        == EntityRecord(
          novel: novel, entity: "mara", type: .known(.character), name: "Mara", significance: .known(.major), status: "alive", origin: .known(.seeded), notes: "n", motivation: "m",
          body: "b", appearance: "tall"))
  }

  @Test
  func shouldKeepTheTypeAndUnnamedFieldsWhenCreatingOverALiveEntity() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(status: "alive", notes: "old"), in: &$0) }
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .faction, name: "Mara II", EntityDetails(notes: "new"), in: &$0) }
    #expect(
      liveRecord(try await world.entity("mara"))
        == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara II", status: "alive", notes: "new"))
  }

  @Test
  func shouldWriteNothingWhenCreatingAnIdenticalEntityAgain() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldCreateARemovedEntityAnewWithoutItsOldFields() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(notes: "old"), in: &$0)
      try Entities.remove(novel: novel, entity: "mara", in: &$0)
    }
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .faction, name: "Mara", in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == EntityRecord(novel: novel, entity: "mara", type: .known(.faction), name: "Mara"))
  }

  @Test
  func shouldNormaliseTheKeyToNFC() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "e\u{301}lan", type: .concept, name: "Elan", in: &$0) }
    let found = try await world.store.read { try Entities.get(novel: novel, entity: "\u{e9}lan", in: $0) }
    #expect(found?.entity == "\u{e9}lan")
  }

  @Test
  func shouldRefuseCreationWithoutAKeyAnAcceptableNameOrNovel() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    await world.expect(.invalidKey(field: "entityKey")) { try Entities.create(novel: novel, entity: "", type: .character, name: "Mara", in: &$0) }
    await world.expect(.blank(field: "name")) { try Entities.create(novel: novel, entity: "mara", type: .character, name: " \n", in: &$0) }
    let missing = SchemaFixture.otherNovel
    await world.expect(.novelNotFound(missing)) { try Entities.create(novel: missing, entity: "mara", type: .character, name: "Mara", in: &$0) }
    #expect(try await world.entity("mara") == .absent)
  }

  @Test
  func shouldEditOnlyTheNamedFields() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(status: "alive", notes: "n"), in: &$0) }
    try await world.run { try Entities.edit(novel: novel, entity: "mara", name: "Mara Vale", EntityDetails(status: "dead"), in: &$0) }
    #expect(
      liveRecord(try await world.entity("mara"))
        == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara Vale", status: "dead", notes: "n"))
  }

  @Test
  func shouldRefuseAnEditThatNamesNoFieldOrABlankName() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0) }
    await world.expect(.noChanges) { try Entities.edit(novel: novel, entity: "mara", in: &$0) }
    await world.expect(.blank(field: "name")) { try Entities.edit(novel: novel, entity: "mara", name: "", in: &$0) }
  }

  @Test
  func shouldReportAMissingOrRemovedEntityOnEditRemoveAndRestore() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    await world.expect(.entityNotFound("ghost")) { try Entities.edit(novel: novel, entity: "ghost", name: "G", in: &$0) }
    await world.expect(.entityNotFound("ghost")) { try Entities.remove(novel: novel, entity: "ghost", in: &$0) }
    await world.expect(.entityNotFound("ghost")) { try Entities.restore(novel: novel, entity: "ghost", in: &$0) }
    try await world.run {
      try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0)
      try Entities.remove(novel: novel, entity: "mara", in: &$0)
    }
    await world.expect(.entityNotFound("mara")) { try Entities.edit(novel: novel, entity: "mara", name: "M", in: &$0) }
    await world.expect(.entityNotFound("mara")) { try Entities.remove(novel: novel, entity: "mara", in: &$0) }
  }

  @Test
  func shouldRemoveAndRestoreAnEntityWithItsFieldsIntact() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let created = EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", notes: "n")
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(notes: "n"), in: &$0) }
    try await world.run { try Entities.remove(novel: novel, entity: "mara", in: &$0) }
    #expect(removedRecord(try await world.entity("mara")))
    try await world.run { try Entities.restore(novel: novel, entity: "mara", in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == created)
    try await world.run { try Entities.restore(novel: novel, entity: "mara", in: &$0) }
  }

  @Test
  func shouldListLiveEntitiesByKeyFilteredByTypeAndOrigin() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Entities.create(novel: novel, entity: "b", type: .character, name: "B", EntityDetails(origin: .seeded), in: &$0)
      try Entities.create(novel: novel, entity: "a", type: .location, name: "A", EntityDetails(origin: .seeded), in: &$0)
      try Entities.create(novel: novel, entity: "c", type: .character, name: "C", EntityDetails(origin: .generated), in: &$0)
      try Entities.create(novel: novel, entity: "d", type: .character, name: "D", in: &$0)
      try Entities.remove(novel: novel, entity: "d", in: &$0)
    }
    let keys = { (type: EntityType?, origin: EntityOrigin?) async throws -> [String] in
      try await world.store.read { try Entities.list(novel: novel, type: type, origin: origin, in: $0).map(\.entity) }
    }
    #expect(try await keys(nil, nil) == ["a", "b", "c"])
    #expect(try await keys(.character, nil) == ["b", "c"])
    #expect(try await keys(.character, .seeded) == ["b"])
    #expect(try await keys(.item, nil) == [])
  }

  @Test
  func shouldNotShowARemovedEntityToTheReaderOrAnotherNovel() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0)
      try Entities.remove(novel: novel, entity: "mara", in: &$0)
    }
    #expect(try await world.store.read { try Entities.get(novel: novel, entity: "mara", in: $0) } == nil)
    let other = SchemaFixture.otherNovel
    #expect(try await world.store.read { try Entities.list(novel: other, in: $0) }.isEmpty)
  }
}
