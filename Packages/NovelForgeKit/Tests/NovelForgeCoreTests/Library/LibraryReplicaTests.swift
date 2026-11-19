import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func seededReplicas(seed: UInt64) async throws -> CausalReplicas {
  let replicas = try await replicas(seed: seed)
  _ = try await replicas.write(0) { transaction in try Library.create(NewNovel(title: "Ember", notes: "base"), id: novel, in: &transaction) }
  try await replicas.settle()
  return replicas
}

private func readEach<T: Sendable>(_ replicas: CausalReplicas, _ body: @Sendable (ReadTransaction) throws -> T) async throws -> [T] {
  var results = [T]()
  for index in 0..<replicas.count { results.append(try await replicas.store(index).read(body)) }
  return results
}

private func novels(_ replicas: CausalReplicas, _ id: UUID = novel) async throws -> [NovelRecord?] {
  try await readEach(replicas) { try Library.novel(id, in: $0) }
}

@Suite("Library operations across replicas", TestTimeLimit.standard)
struct LibraryReplicaTests {
  @Test
  func shouldMergeDifferentNovelFieldsEditedOnTwoDevices() async throws {
    let replicas = try await seededReplicas(seed: 0xD22A)
    _ = try await replicas.write(0) { try Library.edit(novel: novel, changing { $0.theme = .set("grief") }, in: &$0) }
    _ = try await replicas.write(1) { try Library.edit(novel: novel, changing { $0.costTier = .set(.known(.economy)) }, in: &$0) }
    _ = try await replicas.write(2) { try Library.edit(novel: novel, changing { $0.wordTarget = .set(WordTarget(min: 700, max: 1400)) }, in: &$0) }
    try await replicas.settle()
    let expected = NovelRecord(id: novel, name: "Ember", title: "Ember", costTier: .known(.economy), wordTarget: WordTarget(min: 700, max: 1400), theme: "grief")
    #expect(try await novels(replicas) == Array(repeating: expected, count: 3))
  }

  @Test
  func shouldKeepAnEditAndAnArchiveMadeConcurrently() async throws {
    let replicas = try await seededReplicas(seed: 0xD22B)
    _ = try await replicas.write(0) { try Library.archive(novel: novel, in: &$0) }
    _ = try await replicas.write(1) { try Library.edit(novel: novel, changing { $0.ending = .set("She leaves.") }, in: &$0) }
    try await replicas.settle()
    let expected = NovelRecord(id: novel, name: "Ember", title: "Ember", ending: "She leaves.", archived: true)
    #expect(try await novels(replicas) == Array(repeating: expected, count: 3))
    #expect(try await readEach(replicas) { try Library.novels(in: $0).novels.isEmpty } == [true, true, true])
  }

  @Test
  func shouldConvergeOnOneArchiveStateWhenTwoDevicesArchiveAndRestore() async throws {
    let replicas = try await seededReplicas(seed: 0xD22C)
    _ = try await replicas.write(0) { try Library.archive(novel: novel, in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(1) { try Library.restore(novel: novel, in: &$0) }
    _ = try await replicas.write(2) { try Library.edit(novel: novel, changing { $0.theme = .set("x") }, in: &$0) }
    try await replicas.settle()
    let results = try await novels(replicas)
    #expect(results[0] == results[1] && results[1] == results[2])
    #expect(results[0]?.archived == false)
    #expect(results[0]?.theme == "x")
  }

  @Test
  func shouldKeepBothRevisionsOfTheNotesEditedOnTwoDevices() async throws {
    let replicas = try await seededReplicas(seed: 0xD22D)
    _ = try await replicas.write(0) { try Library.replaceNotes(novel: novel, text: "from zero", in: &$0) }
    _ = try await replicas.write(1) { try Library.replaceNotes(novel: novel, text: "from one", in: &$0) }
    try await replicas.settle()
    let histories = try await readEach(replicas) { try AuthorNotesRecord.history(novel: novel, in: $0).history }
    #expect(histories[0] == histories[1] && histories[1] == histories[2])
    #expect(Set(histories[0]?.revisions.compactMap { $0.body.body?.text } ?? []) == ["base", "from zero", "from one"])
    let heads = try await readEach(replicas) { try Library.notes(novel: novel, in: $0) }
    #expect(Set(heads).count == 1)
  }

  @Test
  func shouldCopyTheSourceAsItWasWhenAnotherDeviceEditsItDuringTheClone() async throws {
    let replicas = try await seededReplicas(seed: 0xD22E)
    _ = try await replicas.write(0) { try Entities.create(novel: novel, entity: "mara", type: .character, name: "Mara", in: &$0) }
    try await replicas.settle()
    let copy = UUID()
    _ = try await replicas.write(0) { try Library.clone(novel: novel, as: NovelCopy(name: "Ember II"), id: copy, in: &$0) }
    _ = try await replicas.write(1) { try Entities.edit(novel: novel, entity: "mara", name: "Mara Vale", in: &$0) }
    _ = try await replicas.write(1) { try Library.edit(novel: novel, changing { $0.costTier = .set(.known(.performant)) }, in: &$0) }
    try await replicas.settle()
    let cloned = try await readEach(replicas) { try EntityRecord.read(novel: copy, entity: "mara", in: $0) }
    #expect(cloned.compactMap(liveRecord).map(\.name) == ["Mara", "Mara", "Mara"])
    let sources = try await readEach(replicas) { try EntityRecord.read(novel: novel, entity: "mara", in: $0) }
    #expect(sources.compactMap(liveRecord).map(\.name) == ["Mara Vale", "Mara Vale", "Mara Vale"])
    let copies = try await novels(replicas, copy)
    #expect(copies.compactMap(\.self).map(\.costTier) == Array(repeating: .known(.balanced), count: 3))
    #expect(try await novels(replicas).compactMap(\.self).map(\.costTier) == Array(repeating: .known(.performant), count: 3))
  }

  @Test
  func shouldLeaveTwoCopiesWhenTwoDevicesCloneTheSameNovel() async throws {
    let replicas = try await seededReplicas(seed: 0xD22F)
    _ = try await replicas.write(0) { try Library.clone(novel: novel, as: NovelCopy(name: "A"), in: &$0) }
    _ = try await replicas.write(1) { try Library.clone(novel: novel, as: NovelCopy(name: "B"), in: &$0) }
    try await replicas.settle()
    let lists = try await readEach(replicas) { try Library.novels(in: $0).novels.map(\.name) }
    #expect(lists == Array(repeating: ["A", "B", "Ember"], count: 3))
  }

  @Test
  func shouldReplicateAClonedNovelWithItsPagesToEveryDevice() async throws {
    let replicas = try await seededReplicas(seed: 0xD220)
    _ = try await replicas.write(0) { try Pages.create(novel: novel, section: .world, slug: "city", body: "glass", in: &$0) }
    let copy = UUID()
    _ = try await replicas.write(0) { try Library.clone(novel: novel, as: NovelCopy(name: "Ember II"), id: copy, in: &$0) }
    try await replicas.settle()
    let pages = try await readEach(replicas) { try Pages.get(novel: copy, section: .world, slug: "city", in: $0)?.content.body }
    #expect(pages == ["glass", "glass", "glass"])
  }
}
