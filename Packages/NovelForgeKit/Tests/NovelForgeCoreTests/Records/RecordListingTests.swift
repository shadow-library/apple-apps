import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let wrongType = JSONValue.array([.null])

private struct Population<S: RemovableSubject> {
  let novel: UUID
  let other: UUID
  let own: [S.Record]
  let removedOwn: [S.Record]
  let foreign: [S.Record]

  var expected: [RecordEntry<S.Record>] {
    (own.map { RecordEntry(record: $0, isRemoved: false) } + removedOwn.map { RecordEntry(record: $0, isRemoved: true) }).sorted { $0.record.ref < $1.record.ref }
  }
}

private func populate<S: RemovableSubject>(_: S.Type, in store: VaultStore, _ generator: inout SeededGenerator) async throws -> Population<S> {
  let (novel, other) = (generator.uuid(), generator.uuid())
  let own = (0..<3).map { S.random(&generator, novel: novel, key: "live-\($0)-" + Gen.key(&generator)) }
  let removedOwn = (0..<2).map { S.random(&generator, novel: novel, key: "gone-\($0)-" + Gen.key(&generator)) }
  let foreign = (0..<2).map { S.random(&generator, novel: other, key: "live-\($0)-" + Gen.key(&generator)) }
  for record in own + removedOwn + foreign { _ = try await Harness.create(record, in: store) }
  for record in removedOwn { _ = try await Harness.remove(record, in: store) }
  return Population(novel: novel, other: other, own: own, removedOwn: removedOwn, foreign: foreign)
}

private func writeOtherKinds(excluding kind: NovelForgeKind, for novel: UUID, key: String, in store: VaultStore, _ generator: inout SeededGenerator) async throws {
  if kind != .volume { _ = try await Harness.create(VolumeSubject.random(&generator, novel: novel, key: key), in: store) }
  if kind != .milestone { _ = try await Harness.create(MilestoneSubject.random(&generator, novel: novel, key: key), in: store) }
  if kind != .thread { _ = try await Harness.create(ThreadSubject.random(&generator, novel: novel, key: key), in: store) }
  if kind != .mystery { _ = try await Harness.create(MysterySubject.random(&generator, novel: novel, key: key), in: store) }
}

private func listing<S: RemovableSubject>(_: S.Type, novel: UUID, in store: VaultStore) async throws -> RecordListing<S.Record> {
  try await store.read { transaction in try S.Record.listing(novel: novel, in: transaction) }
}

private func listsOnlyTheNovelsOwnRecords<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  try await forAll(iterations: 5, seed: seed) { generator in
    let population = try await populate(S.self, in: store, &generator)
    for key in ["shared-key", population.own[0].ref.key.rawValue] {
      try await writeOtherKinds(excluding: S.Record.kind, for: population.novel, key: key, in: store, &generator)
      try await writeOtherKinds(excluding: S.Record.kind, for: population.other, key: key, in: store, &generator)
    }
    let result = try await listing(S.self, novel: population.novel, in: store)
    #expect(result.unreadable == 0)
    #expect(result.entries == population.expected)
    #expect(Set(result.live.map(\.ref)) == Set(population.own.map(\.ref)))

    let fromWrite = try await store.write { transaction in try S.Record.listing(novel: population.novel, in: transaction) }
    #expect(fromWrite == result)

    let others = try await listing(S.self, novel: population.other, in: store)
    #expect(others.entries.map(\.record) == population.foreign.sorted { $0.ref < $1.ref })
  }
}

private func skipsUnreadableAndCountsThem<S: RemovableSubject>(_: S.Type) async throws {
  let store = try SchemaFixture.store()
  var generator = SeededGenerator(seed: 0xF1)
  let population = try await populate(S.self, in: store, &generator)

  let attributable = S.random(&generator, novel: population.novel, key: "bad-type")
  var members = try attributable.storedMembers
  let victim = try #require(S.requiredMembers.subtracting(Harness.commonMembers).sorted().first)
  members[victim] = wrongType
  try await SchemaFixture.set(attributable.ref, members, in: store)

  let unattributable = S.random(&generator, novel: population.other, key: "no-key")
  var withoutKey = try unattributable.storedMembers
  withoutKey["natural_key"] = nil
  try await SchemaFixture.set(unattributable.ref, withoutKey, in: store)

  let mine = try await listing(S.self, novel: population.novel, in: store)
  #expect(mine.entries == population.expected)
  #expect(mine.unreadable == 1)
  #expect(mine.unattributed == 0)

  let theirs = try await listing(S.self, novel: population.other, in: store)
  #expect(theirs.entries.map(\.record.ref) == population.foreign.map(\.ref).sorted())
  #expect(theirs.unreadable == 0)
  #expect(theirs.unattributed == 0)

  let all = try await store.read { transaction in try S.Record.listing(in: transaction) }
  #expect(all.unreadable == 1)
  #expect(all.unattributed == 1)
}

@Suite("Typed record listing", .timeLimit(.minutes(1)))
struct RecordListingTests {
  @Test func shouldListOnlyTheVolumesOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(VolumeSubject.self, seed: 0xF2) }
  @Test func shouldListOnlyTheMilestonesOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(MilestoneSubject.self, seed: 0xF3) }
  @Test func shouldListOnlyTheThreadsOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(ThreadSubject.self, seed: 0xF4) }
  @Test func shouldListOnlyTheMysteriesOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(MysterySubject.self, seed: 0xF5) }

  @Test func shouldSkipUnreadableVolumesAndCountThem() async throws { try await skipsUnreadableAndCountsThem(VolumeSubject.self) }
  @Test func shouldSkipUnreadableMilestonesAndCountThem() async throws { try await skipsUnreadableAndCountsThem(MilestoneSubject.self) }
  @Test func shouldSkipUnreadableThreadsAndCountThem() async throws { try await skipsUnreadableAndCountsThem(ThreadSubject.self) }
  @Test func shouldSkipUnreadableMysteriesAndCountThem() async throws { try await skipsUnreadableAndCountsThem(MysterySubject.self) }

  @Test func shouldNotLetAStrayEditInOneNovelChangeAnotherNovelsListing() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xF9)
    let population = try await populate(VolumeSubject.self, in: store, &generator)
    let before = try await listing(VolumeSubject.self, novel: population.novel, in: store)
    let strayNovel = generator.uuid()
    var edit = VolumeEdit()
    edit.title = .set("orphan")
    _ = try await store.write { [edit] transaction in try VolumeRecord.edit(novel: strayNovel, volume: "never-created", edit, in: &transaction) }
    #expect(try await listing(VolumeSubject.self, novel: population.novel, in: store) == before)
    #expect(try await listing(VolumeSubject.self, novel: strayNovel, in: store) == RecordListing(entries: [], unreadable: 0))
    let all = try await store.read { transaction in try VolumeRecord.listing(in: transaction) }
    #expect(all.unattributed == 1)
    #expect(all.unreadable == 0)
  }

  @Test func shouldListEveryNovelAndCountUnreadableOnes() async throws {
    let store = try SchemaFixture.store()
    let first = NovelRecord(id: SchemaFixture.novel, name: "Aria")
    let second = NovelRecord(id: SchemaFixture.otherNovel, name: "Brook", archived: true)
    for novel in [first, second] { _ = try await Harness.create(novel, in: store) }
    var broken = try NovelRecord(id: SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-000000000003"), name: "Broken").storedMembers
    broken["name"] = wrongType
    try await SchemaFixture.set(NovelForgeKey.novel(SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-000000000003")), broken, in: store)
    let result = try await store.read { transaction in try NovelRecord.listing(in: transaction) }
    #expect(result.unreadable == 1)
    #expect(Set(result.entries.map(\.record.id)) == [first.id, second.id])
    #expect(result.live == result.entries.map(\.record))
  }
}
