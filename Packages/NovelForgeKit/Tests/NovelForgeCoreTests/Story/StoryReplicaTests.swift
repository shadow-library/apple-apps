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
  _ = try await replicas.write(0) { transaction in try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara").create(in: &transaction) }
  try await replicas.settle()
  return replicas
}

@Suite("Story across replicas")
struct StoryReplicaTests {
  @Test
  func shouldAgreeOnTheActiveVolumeWhenTwoDevicesCreateVolumesWithTheSameOrdinal() async throws {
    let replicas = try await seededReplicas(seed: 0xD18A)
    _ = try await replicas.write(0) { try Volumes.create(novel: novel, volume: "b", ordinal: 0, in: &$0) }
    _ = try await replicas.write(1) { try Volumes.create(novel: novel, volume: "a", ordinal: 0, in: &$0) }
    try await replicas.settle()
    let active = try await readEach(replicas) { activeVolume(of: try VolumeRecord.listing(novel: novel, in: $0).live) }
    #expect(active == ["a", "a", "a"])
  }

  @Test
  func shouldLetTwoDevicesCompleteTheSameVolumeWithoutActivatingTwo() async throws {
    let replicas = try await seededReplicas(seed: 0xD18B)
    _ = try await replicas.write(0) {
      try Volumes.create(novel: novel, volume: "one", ordinal: 1, in: &$0)
      try Volumes.create(novel: novel, volume: "two", ordinal: 2, in: &$0)
    }
    try await replicas.settle()
    let results = [
      try await replicas.write(0) { try Volumes.markGoalMet(novel: novel, volume: "one", in: &$0) },
      try await replicas.write(1) { try Volumes.markGoalMet(novel: novel, volume: "one", in: &$0) },
    ]
    #expect(results == [VolumeAdvance(completed: "one", activated: "two"), VolumeAdvance(completed: "one", activated: "two")])
    try await replicas.settle()
    let active = try await readEach(replicas) { activeVolume(of: try VolumeRecord.listing(novel: novel, in: $0).live) }
    #expect(active == ["two", "two", "two"])
  }

  @Test
  func shouldMoveTheActiveVolumePastOneAnotherDeviceRemoved() async throws {
    let replicas = try await seededReplicas(seed: 0xD18C)
    _ = try await replicas.write(0) {
      for (key, ordinal) in [("one", 1), ("two", 2), ("three", 3)] { try Volumes.create(novel: novel, volume: key, ordinal: ordinal, in: &$0) }
    }
    try await replicas.settle()
    _ = try await replicas.write(0) { try Volumes.markGoalMet(novel: novel, volume: "one", in: &$0) }
    _ = try await replicas.write(1) { try Volumes.remove(novel: novel, volume: "two", in: &$0) }
    try await replicas.settle()
    let active = try await readEach(replicas) { activeVolume(of: try VolumeRecord.listing(novel: novel, in: $0).live) }
    #expect(active == ["three", "three", "three"])
  }

  @Test
  func shouldConvergeOnOneMilestoneWhenTwoDevicesCreateTheSameKey() async throws {
    let replicas = try await seededReplicas(seed: 0xD18D)
    _ = try await replicas.write(0) { try Milestones.create(novel: novel, milestone: "ascends", label: "First", in: &$0) }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { try Milestones.create(novel: novel, milestone: "ascends", label: "Second", kind: .known(.rank), in: &$0) }
    try await replicas.settle()
    let records = try await readEach(replicas) { try MilestoneRecord.listing(novel: novel, in: $0).live }
    #expect(records.allSatisfy { $0 == records[0] })
    #expect(records[0] == [MilestoneRecord(novel: novel, milestone: "ascends", label: "Second", kind: .known(.rank))])
  }

  @Test
  func shouldKeepASecretRemovedWhenAnotherDeviceEditsItConcurrently() async throws {
    let replicas = try await seededReplicas(seed: 0xD18E)
    _ = try await replicas.write(0) { try Secrets.upsert(novel: novel, secret: "kin", text: "old", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try Secrets.remove(novel: novel, secret: "kin", in: &$0) }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { try Secrets.upsert(novel: novel, secret: "kin", text: "new", in: &$0) }
    try await replicas.settle()
    let readings = try await readEach(replicas) { try SecretRecord.read(novel: novel, secret: "kin", in: $0) }
    #expect(readings.allSatisfy { isRemoved($0) })
    #expect(readings.allSatisfy { reading in if case .readable(let entry) = reading { entry.record.text == "new" } else { false } })
  }

  @Test
  func shouldLetALaterRetractionWinOverAnEarlierReveal() async throws {
    let replicas = try await seededReplicas(seed: 0xD18F)
    _ = try await replicas.write(0) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 5, in: &$0) }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { try ManualReveals.retract(novel: novel, secret: "kin", entity: "mara", in: &$0) }
    try await replicas.settle()
    let readings = try await readEach(replicas) { try CharacterKnowledgeRecord.read(novel: novel, fact: "kin", entity: "mara", in: $0) }
    #expect(readings.allSatisfy { isRemoved($0) })
  }

  @Test
  func shouldLetALaterRevealWinOverAnEarlierRetraction() async throws {
    let replicas = try await seededReplicas(seed: 0xD190)
    _ = try await replicas.write(0) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try ManualReveals.retract(novel: novel, secret: "kin", entity: "mara", in: &$0) }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 5, note: "again", in: &$0) }
    try await replicas.settle()
    let readings = try await readEach(replicas) { try CharacterKnowledgeRecord.read(novel: novel, fact: "kin", entity: "mara", in: $0) }
    let expected = CharacterKnowledgeRecord(novel: novel, fact: "kin", entity: "mara", reveal: ManualReveal(chapter: 5, note: "again"))
    #expect(readings.allSatisfy { live($0) == expected })
  }

  @Test
  func shouldKeepOneWholeRevealWhenTwoDevicesRevealDifferentChapters() async throws {
    let replicas = try await seededReplicas(seed: 0xD191)
    _ = try await replicas.write(0) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, note: "first", in: &$0) }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 7, in: &$0) }
    try await replicas.settle()
    let readings = try await readEach(replicas) { try CharacterKnowledgeRecord.read(novel: novel, fact: "kin", entity: "mara", in: $0) }
    #expect(readings.allSatisfy { live($0)?.reveal == ManualReveal(chapter: 7, note: nil) })
  }

  @Test
  func shouldMergeSecretFieldsEditedOnDifferentDevices() async throws {
    let replicas = try await seededReplicas(seed: 0xD192)
    _ = try await replicas.write(0) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(0) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(constraintNote: .set("keep")), in: &$0) }
    _ = try await replicas.write(1) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(revealChapter: .set(4)), in: &$0) }
    try await replicas.settle()
    let records = try await readEach(replicas) { try SecretRecord.read(novel: novel, secret: "kin", in: $0) }
    let expected = SecretRecord(novel: novel, secret: "kin", text: "t", constraintNote: "keep", revealChapter: 4)
    #expect(records.allSatisfy { live($0) == expected })
  }
}
