import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("StoryBibleModel")
struct StoryBibleModelTests {
  private enum Unexpected: Error { case presence }

  private struct World {
    let store: VaultStore
    let novel: UUID
    let model: StoryBibleModel
  }

  private func makeWorld() async throws -> World {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await LibraryService(store: store).create(title: "Ashfall", notes: "")
    return World(store: store, novel: novel, model: StoryBibleModel(context: NovelContext(store: store, novel: novel)))
  }

  private func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for \(message)")
  }

  private func pages(_ model: StoryBibleModel) -> [String]? { model.state.value?.pages.value?.items.map(\.slug) }
  private func entities(_ model: StoryBibleModel) -> [String]? { model.state.value?.entities.value?.items.map(\.entity) }

  private func page(_ world: World, _ address: PageAddress) async throws -> PageReading {
    try await world.store.load(PageReading.self, PageReading.Input(novel: world.novel, address: address))
  }

  private func livePage(_ world: World, _ address: PageAddress) async throws -> PageRecord {
    guard case .live(let record) = try await page(world, address).presence else { throw Unexpected.presence }
    return record
  }

  private func liveEntity(_ world: World, _ key: String) async throws -> EntityRecord {
    guard case .live(let record) = try await entity(world, key).presence else { throw Unexpected.presence }
    return record
  }

  private func entity(_ world: World, _ key: String) async throws -> EntityReading {
    try await world.store.load(EntityReading.self, EntityReading.Input(novel: world.novel, entity: key))
  }

  @Test("should load an empty Story Bible")
  func loadsEmpty() async throws {
    let world = try await makeWorld()
    let task = Task { await world.model.observe() }
    defer { task.cancel() }

    try await waitUntil("the contents") { world.model.state.value != nil }

    #expect(pages(world.model)?.isEmpty == true)
    #expect(entities(world.model)?.isEmpty == true)
    #expect(world.model.catalogue.isEmpty)
  }

  @Test("should rebuild the cached catalogue from the observed contents")
  func catalogueFollowsContents() async throws {
    let world = try await makeWorld()
    let task = Task { await world.model.observe() }
    defer { task.cancel() }
    try await waitUntil("the contents") { world.model.state.value != nil }

    _ = try await world.model.createEntity(key: "mara", type: .character, name: "Mara", details: EntityDetails())

    try await waitUntil("the catalogue") { world.model.catalogue.entries.map(\.name) == ["Mara"] }
  }

  @Test("should show a created page through observation and keep its section")
  func createPageAppears() async throws {
    let world = try await makeWorld()
    let task = Task { await world.model.observe() }
    defer { task.cancel() }
    try await waitUntil("the contents") { world.model.state.value != nil }

    let address = try await world.model.createPage(section: .world, title: "The City", slug: "the-city", body: "Walls of ash.")

    try await waitUntil("the page") { pages(world.model) == ["the-city"] }
    #expect(address == PageAddress(section: .world, slug: "the-city"))
    #expect(world.model.state.value?.pages.value?.items.first?.title == "The City")
    let record = try await livePage(world, address)
    #expect(record.content.body == "Walls of ash.")
  }

  @Test("should save an edited page, keep its other frontmatter and add a version")
  func editPage() async throws {
    let world = try await makeWorld()
    let address = try await world.model.createPage(section: .plot, title: "Arc", slug: "arc", body: "One.")
    _ = try await world.store.writeDomain { transaction throws(DomainError) in
      try Pages.revise(novel: world.novel, section: .plot, slug: "arc", frontmatter: ["title": "Arc", "mood": "grim"], body: "One.", in: &transaction)
    }
    let head = try await page(world, address).versions.first(where: \.isHead)?.revision

    _ = try await world.model.savePage(address, title: "The Arc", body: "One. Two.", basedOn: head)

    let reading = try await page(world, address)
    let record = try await livePage(world, address)
    #expect(record.content.body == "One. Two.")
    #expect(record.content.frontmatter?["title"]?.stringValue == "The Arc")
    #expect(record.content.frontmatter?["mood"]?.stringValue == "grim")
    #expect(reading.versions.count == 3)
  }

  @Test("should refuse a page save made on a stale revision")
  func staleSaveIsRefused() async throws {
    let world = try await makeWorld()
    let address = try await world.model.createPage(section: .world, title: "Sea", slug: "sea", body: "Salt.")
    let opened = try await page(world, address).versions.first(where: \.isHead)?.revision
    _ = try await world.model.savePage(address, title: "Sea", body: "Salt and ash.", basedOn: opened)

    let form = PageForm(mode: .edit(address: address, title: "Sea", body: "Salt.", revision: opened))
    form.body = "Salt, other."
    let saved = await form.submit(using: world.model)

    #expect(saved == nil)
    #expect(form.failure?.headline == StoryBibleErrors.presented(BibleWriteIssue.pageChanged(head: nil)).headline)
    let record = try await livePage(world, address)
    #expect(record.content.body == "Salt and ash.")
  }

  @Test("should remove a page, list it as removed and restore it")
  func removeAndRestorePage() async throws {
    let world = try await makeWorld()
    let task = Task { await world.model.observe() }
    defer { task.cancel() }
    let address = try await world.model.createPage(section: .lore, title: "Moon", slug: "moon", body: "Pale.")
    try await waitUntil("the page") { pages(world.model) == ["moon"] }

    await world.model.removePage(address, title: "Moon")

    try await waitUntil("the removal") { pages(world.model)?.isEmpty == true && world.model.removed == [.page(address, title: "Moon")] }
    #expect(try await page(world, address).presence == .removed(title: "Moon"))

    await world.model.restore(try #require(world.model.removed.first))

    try await waitUntil("the restore") { pages(world.model) == ["moon"] && world.model.removed.isEmpty }
    #expect(world.model.failure == nil)
  }

  @Test("should keep removed pages and entities restorable after the screen is reopened")
  func removedSurviveRelaunch() async throws {
    let world = try await makeWorld()
    let address = try await world.model.createPage(section: .lore, title: "Moon", slug: "moon", body: "Pale.")
    _ = try await world.model.createEntity(key: "mara", type: .character, name: "Mara", details: EntityDetails())
    await world.model.removePage(address, title: "Moon")
    await world.model.removeEntity("mara", name: "Mara")

    let reopened = StoryBibleModel(context: NovelContext(store: world.store, novel: world.novel))
    let task = Task { await reopened.observe() }
    defer { task.cancel() }
    try await waitUntil("the removed records") { reopened.removed.count == 2 }

    #expect(Set(reopened.removed.map(\.name)) == ["Moon", "Mara"])
    #expect(reopened.removedEntries(kind: .records, query: "").map(\.name) == ["Mara"])
    #expect(reopened.removedEntries(kind: .guides, query: "").map(\.name) == ["Moon"])
    #expect(reopened.removedEntries(kind: .all, query: "mo").map(\.name) == ["Moon"])
    for entry in reopened.removed { await reopened.restore(entry) }
    try await waitUntil("the restores") { reopened.removed.isEmpty && pages(reopened) == ["moon"] && entities(reopened) == ["mara"] }
  }

  @Test("should file a page under the topic of the role it covers and search its excerpt")
  func stagesAndExcerpts() async throws {
    let world = try await makeWorld()
    let task = Task { await world.model.observe() }
    defer { task.cancel() }
    _ = try await world.model.createEntity(key: "guild", type: .faction, name: "The Guild", details: EntityDetails())
    _ = try await world.model.createPage(section: .world, title: "Territory", slug: "territory", body: "Borders along the amber river.")

    try await waitUntil("the catalogue") { world.model.catalogue.entries.contains { $0.isPage } }

    let guide = try #require(world.model.catalogue.entries.first { $0.isPage })
    #expect(guide.topic == .factions)
    #expect(guide.summary == "Borders along the amber river.")
    #expect(world.model.catalogue.groups(kind: .all, query: "amber").flatMap(\.entries).map(\.name) == ["Territory"])
    #expect(world.model.catalogue.groups(kind: .all, query: "granite").isEmpty)
  }

  @Test("should restore an older page version as a new head")
  func restoreVersion() async throws {
    let world = try await makeWorld()
    let address = try await world.model.createPage(section: .world, title: "Gate", slug: "gate", body: "First.")
    let first = try await page(world, address).versions.first(where: \.isHead)?.revision
    _ = try await world.model.savePage(address, title: "Gate", body: "Second.", basedOn: first)

    let restored = await world.model.restoreVersion(address, revision: try #require(first))

    #expect(restored)
    let reading = try await page(world, address)
    let record = try await livePage(world, address)
    #expect(record.content.body == "First.")
    #expect(reading.versions.count == 3)
    #expect(reading.versions.first?.isHead == true)
  }

  @Test("should show a localized error when restoring a version that does not exist")
  func restoreMissingVersion() async throws {
    let world = try await makeWorld()
    let address = try await world.model.createPage(section: .world, title: "Gate", slug: "gate", body: "First.")

    let restored = await world.model.restoreVersion(address, revision: "missing")

    #expect(!restored)
    #expect(world.model.failure?.error.headline == StoryBibleErrors.headline(for: .revisionNotFound("missing")))
  }

  @Test("should show a created entity, edit it, remove it and restore it")
  func entityLifecycle() async throws {
    let world = try await makeWorld()
    let task = Task { await world.model.observe() }
    defer { task.cancel() }
    try await waitUntil("the contents") { world.model.state.value != nil }

    let key = try await world.model.createEntity(key: "mara", type: .character, name: "Mara", details: EntityDetails(significance: .major, body: "A courier."))
    try await waitUntil("the entity") { entities(world.model) == ["mara"] }

    try await world.model.editEntity(key: key, name: "Mara Vey", details: EntityDetails(status: "alive", motivation: "Find her brother."))
    let edited = try await liveEntity(world, key)
    #expect(edited.name == "Mara Vey")
    #expect(edited.status == "alive")
    #expect(edited.motivation == "Find her brother.")
    #expect(edited.body == "A courier.")
    #expect(edited.type == .known(.character))

    await world.model.removeEntity(key, name: "Mara Vey")
    try await waitUntil("the removal") { entities(world.model)?.isEmpty == true }
    #expect(try await entity(world, key).presence == .removed(name: "Mara Vey"))

    await world.model.restoreEntity(key)
    try await waitUntil("the restore") { entities(world.model) == ["mara"] }
  }

  @Test("should clear an entity field")
  func clearsEntityField() async throws {
    let world = try await makeWorld()
    _ = try await world.model.createEntity(key: "keep", type: .location, name: "The Keep", details: EntityDetails(status: "ruined"))
    let record = try await liveEntity(world, "keep")
    let form = EntityForm(mode: .edit(record))
    form.status = ""

    let saved = await form.submit(using: world.model)

    #expect(saved == "keep")
    let edited = try await liveEntity(world, "keep")
    #expect(edited.status == nil)
  }

  @Test("should refuse to create an entity over a live key")
  func entityKeyTaken() async throws {
    let world = try await makeWorld()
    _ = try await world.model.createEntity(key: "mara", type: .character, name: "Mara", details: EntityDetails())

    let form = EntityForm(mode: .create(type: .location))
    form.name = "Other"
    form.editKey("mara")
    let saved = await form.submit(using: world.model)

    #expect(saved == nil)
    #expect(form.failure?.headline == StoryBibleErrors.headline(for: .entityExists("mara")))
    #expect(form.failure?.detail == "bible.entity_exists")
    let record = try await liveEntity(world, "mara")
    #expect(record.name == "Mara")
    #expect(record.type == .known(.character))
  }

  @Test("should show a localized error when a page address already exists")
  func pageExists() async throws {
    let world = try await makeWorld()
    _ = try await world.model.createPage(section: .world, title: "City", slug: "city", body: "")

    let form = PageForm(mode: .create)
    form.section = .world
    form.title = "City"
    let saved = await form.submit(using: world.model)

    #expect(saved == nil)
    #expect(form.failure?.headline == StoryBibleErrors.headline(for: .documentExists(section: "world", slug: "city")))
    #expect(form.failure?.detail == "bible.document_exists")
  }

  @Test("should show a localized error when editing an entity that was removed")
  func editRemovedEntity() async throws {
    let world = try await makeWorld()
    _ = try await world.model.createEntity(key: "mara", type: .character, name: "Mara", details: EntityDetails())
    let record = try await liveEntity(world, "mara")
    await world.model.removeEntity("mara", name: "Mara")
    let form = EntityForm(mode: .edit(record))
    form.name = "Mara Vey"

    let saved = await form.submit(using: world.model)

    #expect(saved == nil)
    #expect(form.failure?.headline == StoryBibleErrors.headline(for: .entityNotFound("mara")))
  }

  @Test("should list what a character knows from the ledger and none for other kinds")
  func knowledgeRows() async throws {
    let world = try await makeWorld()
    _ = try await world.model.createEntity(key: "mara", type: .character, name: "Mara", details: EntityDetails())
    _ = try await world.model.createEntity(key: "keep", type: .location, name: "The Keep", details: EntityDetails())
    try await world.store.writeDomain { transaction throws(DomainError) in
      try Secrets.upsert(novel: world.novel, secret: "heir", text: "Mara is the lost heir.", in: &transaction)
      try ManualReveals.reveal(novel: world.novel, secret: "heir", entity: "mara", chapter: 3, in: &transaction)
    }

    let mara = try await entity(world, "mara")
    let keep = try await entity(world, "keep")

    let items = try #require(mara.knowledge?.value)
    #expect(items.map(\.text) == ["Mara is the lost heir."])
    #expect(items.map(\.chapter) == [3])
    #expect(keep.knowledge == nil)
  }

  @Test("should report a missing page and a missing entity as missing")
  func missingRoutes() async throws {
    let world = try await makeWorld()

    let missingPage = try await page(world, PageAddress(section: .world, slug: "nowhere"))
    let missingEntity = try await entity(world, "nobody")

    #expect(missingPage.presence == .missing)
    #expect(missingEntity.presence == .missing)
  }

  @Test("should observe a page change and its removal as a removed route")
  func observedPageReading() async throws {
    let world = try await makeWorld()
    let address = try await world.model.createPage(section: .world, title: "City", slug: "city", body: "One.")
    let observer = ReadObserver<PageReading>()
    let store = world.store
    let input = PageReading.Input(novel: world.novel, address: address)
    let task = Task { await observer.run { store.observe(PageReading.self, input) } }
    defer { task.cancel() }
    try await waitUntil("the page") { observer.state.value != nil }

    await world.model.removePage(address, title: "City")

    try await waitUntil("the removal") { observer.state.value?.presence == .removed(title: "City") }
  }
}
