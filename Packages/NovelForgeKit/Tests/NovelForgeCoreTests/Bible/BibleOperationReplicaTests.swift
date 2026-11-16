import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func readEach<T: Sendable>(_ replicas: CausalReplicas, _ body: @Sendable (ReadTransaction) throws -> T) async throws -> [T] {
  var results = [T]()
  for index in 0..<replicas.count { results.append(try await replicas.store(index).read(body)) }
  return results
}

private func seededReplicas(seed: UInt64) async throws -> CausalReplicas {
  let replicas = try await replicas(seed: seed)
  _ = try await replicas.write(0) { transaction in try NovelRecord(id: novel, name: "Ember").create(in: &transaction) }
  try await replicas.settle()
  return replicas
}

private func entities(_ replicas: CausalReplicas, _ key: String) async throws -> [RecordReading<EntityRecord>] {
  try await readEach(replicas) { try EntityRecord.read(novel: novel, entity: key, in: $0) }
}

private func versions(_ replicas: CausalReplicas, _ section: BiblePageSection, _ slug: String) async throws -> [[PageVersion]] {
  try await readEach(replicas) { try Pages.versions(novel: novel, section: section, slug: slug, in: $0) }
}

@Suite("Bible operations across replicas", .timeLimit(.minutes(2)))
struct BibleOperationReplicaTests {
  @Test
  func shouldMergeDifferentEntityFieldsEditedOnTwoDevices() async throws {
    let replicas = try await seededReplicas(seed: 0xD19A)
    _ = try await replicas.write(0) { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", EntityDetails(notes: "n"), in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try Entities.edit(novel: novel, entity: "mara", EntityDetails(status: "alive"), in: &$0) }
    _ = try await replicas.write(1) { try Entities.edit(novel: novel, entity: "mara", name: "Mara Vale", in: &$0) }
    _ = try await replicas.write(2) { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "revenge"), in: &$0) }
    try await replicas.settle()
    let expected = EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara Vale", status: "alive", notes: "n", motivation: "revenge")
    #expect(try await entities(replicas, "mara") == Array(repeating: live(expected), count: 3))
  }

  @Test
  func shouldKeepBothConcurrentPageRevisionsInHistoryWithOneHeadEverywhere() async throws {
    let replicas = try await seededReplicas(seed: 0xD19B)
    _ = try await replicas.write(0) { try Pages.create(novel: novel, section: .world, slug: "city", frontmatter: ["title": "City"], body: "base", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try Pages.revise(novel: novel, section: .world, slug: "city", frontmatter: ["title": "City"], body: "from zero", in: &$0) }
    _ = try await replicas.write(1) { try Pages.revise(novel: novel, section: .world, slug: "city", frontmatter: ["title": "City"], body: "from one", in: &$0) }
    try await replicas.settle()
    let history = try await versions(replicas, .world, "city")
    #expect(history[0] == history[1])
    #expect(history[1] == history[2])
    #expect(Set(history[0].compactMap { $0.content?.body }) == ["base", "from zero", "from one"])
    let heads = history[0].filter(\.isHead)
    #expect(heads.count == 1)
    let pages = try await readEach(replicas) { try Pages.get(novel: novel, section: .world, slug: "city", in: $0)?.content.body }
    #expect(pages == Array(repeating: heads[0].content?.body, count: 3))
  }

  @Test
  func shouldKeepBothVersionsWhenTwoDevicesCreateTheSamePage() async throws {
    let replicas = try await seededReplicas(seed: 0xD19C)
    _ = try await replicas.write(0) { try Pages.create(novel: novel, section: .lore, slug: "myth", body: "zero", in: &$0) }
    _ = try await replicas.write(1) { try Pages.create(novel: novel, section: .lore, slug: "myth", body: "one", in: &$0) }
    try await replicas.settle()
    let history = try await versions(replicas, .lore, "myth")
    #expect(history[0] == history[1] && history[1] == history[2])
    #expect(Set(history[0].compactMap { $0.content?.body }) == ["zero", "one"])
    #expect(history[0].filter(\.isHead).count == 1)
  }

  @Test
  func shouldRestoreAnOlderVersionOnOneDeviceWhileAnotherRevises() async throws {
    let replicas = try await seededReplicas(seed: 0xD19D)
    _ = try await replicas.write(0) { try Pages.create(novel: novel, section: .power, slug: "rank", body: "one", in: &$0) }
    _ = try await replicas.write(0) { try Pages.revise(novel: novel, section: .power, slug: "rank", body: "two", in: &$0) }
    try await replicas.settle()
    let first = try #require(try await versions(replicas, .power, "rank")[0].last)
    _ = try await replicas.write(0) { try Pages.restoreVersion(novel: novel, section: .power, slug: "rank", revision: first.revision, in: &$0) }
    _ = try await replicas.write(1) { try Pages.revise(novel: novel, section: .power, slug: "rank", body: "three", in: &$0) }
    try await replicas.settle()
    let history = try await versions(replicas, .power, "rank")
    #expect(history[0] == history[1] && history[1] == history[2])
    #expect(history[0].compactMap { $0.content?.body }.sorted() == ["one", "one", "three", "two"])
    #expect(history[0].filter(\.isHead).count == 1)
  }

  @Test
  func shouldLetALaterRemovalWinOverAnEditAndKeepARemovedEntityRemovedAfterAnEdit() async throws {
    let replicas = try await seededReplicas(seed: 0xD1A0)
    _ = try await replicas.write(0) { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0) }
    try await replicas.settle()
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { try Entities.edit(novel: novel, entity: "mara", EntityDetails(status: "alive"), in: &$0) }
    await replicas.advanceClock(of: 0, by: .seconds(10))
    _ = try await replicas.write(0) { try Entities.remove(novel: novel, entity: "mara", in: &$0) }
    try await replicas.settle()
    let edited = EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", status: "alive")
    #expect(try await entities(replicas, "mara") == Array(repeating: removed(edited), count: 3))

    await replicas.advanceClock(of: 2, by: .seconds(10))
    _ = try await replicas.write(2) { try Entities.restore(novel: novel, entity: "mara", in: &$0) }
    try await replicas.settle()
    #expect(try await entities(replicas, "mara") == Array(repeating: live(edited), count: 3))
  }

  @Test
  func shouldHideAPageRemovedOnOneDeviceFromEveryDeviceWhileAnotherRevisesIt() async throws {
    let replicas = try await seededReplicas(seed: 0xD1A1)
    _ = try await replicas.write(0) { try Pages.create(novel: novel, section: .plot, slug: "arc", body: "one", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try Pages.remove(novel: novel, section: .plot, slug: "arc", in: &$0) }
    _ = try await replicas.write(1) { try Pages.revise(novel: novel, section: .plot, slug: "arc", body: "two", in: &$0) }
    try await replicas.settle()
    let listed = try await readEach(replicas) { try Pages.list(novel: novel, in: $0).count }
    let history = try await versions(replicas, .plot, "arc")
    #expect(listed == [0, 0, 0])
    #expect(history[0].compactMap { $0.content?.body }.sorted() == ["one", "two"])
  }
}

private func live(_ record: EntityRecord) -> RecordReading<EntityRecord> { .readable(RecordEntry(record: record, isRemoved: false)) }
private func removed(_ record: EntityRecord) -> RecordReading<EntityRecord> { .readable(RecordEntry(record: record, isRemoved: true)) }
