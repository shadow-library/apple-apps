import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Entities: create new and clearing details")
struct EntityCreateNewTests {
  @Test
  func shouldCreateANewEntityWithItsDetails() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.createNew(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(status: "alive"), in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", status: "alive"))
  }

  @Test
  func shouldRefuseToCreateOverALiveKeyAndLeaveItUnchanged() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(notes: "old"), in: &$0) }
    await world.expect(.entityExists("mara")) { try Entities.createNew(novel: novel, entity: "mara", type: .faction, name: "Other", EntityDetails(notes: "new"), in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", notes: "old"))
  }

  @Test
  func shouldRefuseAKeyThatIsTheLiveKeyAfterNormalisation() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.createNew(novel: novel, entity: "\u{E9}lan", type: .concept, name: "Elan", in: &$0) }
    await world.expect(.entityExists("\u{E9}lan")) { try Entities.createNew(novel: novel, entity: "e\u{301}lan", type: .concept, name: "Elan", in: &$0) }
  }

  @Test
  func shouldCreateARemovedKeyAnew() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(notes: "old"), in: &$0)
      try Entities.remove(novel: novel, entity: "mara", in: &$0)
    }
    try await world.run { try Entities.createNew(novel: novel, entity: "mara", type: .faction, name: "Mara", in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == EntityRecord(novel: novel, entity: "mara", type: .known(.faction), name: "Mara"))
  }

  @Test
  func shouldApplyTheCreateGuardsBeforeTheKeyCheck() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    await world.expect(.blank(field: "name")) { try Entities.createNew(novel: novel, entity: "mara", type: .character, name: "  ", in: &$0) }
    let missing = UUID()
    await world.expect(.novelNotFound(missing)) { try Entities.createNew(novel: missing, entity: "mara", type: .character, name: "Mara", in: &$0) }
  }

  @Test
  func shouldReportTheExistingKeyWithItsOwnCode() {
    #expect(DomainError.entityExists("mara").code == "bible.entity_exists")
  }

  @Test
  func shouldClearAFieldOnEditAndKeepTheOthers() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let details = EntityDetails(significance: .major, status: "alive", origin: .seeded, notes: "n")
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", details, in: &$0) }
    var clearing = EntityDetails(motivation: "home")
    clearing.status = .set(nil)
    clearing.significance = .set(nil)
    let edit = clearing
    try await world.run { try Entities.edit(novel: novel, entity: "mara", edit, in: &$0) }
    #expect(
      liveRecord(try await world.entity("mara"))
        == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", origin: .known(.seeded), notes: "n", motivation: "home"))
  }

  @Test
  func shouldCountAClearAsAChange() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(body: "b"), in: &$0) }
    var clearing = EntityDetails()
    clearing.body = .set(nil)
    let edit = clearing
    try await world.run { try Entities.edit(novel: novel, entity: "mara", edit, in: &$0) }
    #expect(liveRecord(try await world.entity("mara"))?.body == nil)
    await world.expect(.noChanges) { try Entities.edit(novel: novel, entity: "mara", EntityDetails(), in: &$0) }
  }

  @Test
  func shouldClearAFieldWhenUpsertingOverALiveKey() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(notes: "old", body: "b"), in: &$0) }
    var details = EntityDetails(status: "alive")
    details.notes = .set(nil)
    let upsert = details
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", upsert, in: &$0) }
    #expect(liveRecord(try await world.entity("mara")) == EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", status: "alive", body: "b"))
  }

  @Test
  func shouldStoreAnEmptyStringAsSetNotAsCleared() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(status: "alive"), in: &$0) }
    try await world.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(status: ""), in: &$0) }
    #expect(liveRecord(try await world.entity("mara"))?.status == "")
  }

  @Test
  func shouldWriteAnEditThatOnlyChangesTheNormalisationForm() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Ren\u{E9}", EntityDetails(notes: "caf\u{E9}"), in: &$0) }
    try await world.run { try Entities.edit(novel: novel, entity: "mara", name: "Rene\u{301}", EntityDetails(notes: "cafe\u{301}"), in: &$0) }
    let record = try #require(liveRecord(try await world.entity("mara")))
    #expect(record.name.utf8.elementsEqual("Rene\u{301}".utf8))
    #expect(record.notes.map { $0.utf8.elementsEqual("cafe\u{301}".utf8) } == true)
  }
}
