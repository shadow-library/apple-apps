import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let replicaCount = 3

func replicas(seed: UInt64) async throws -> CausalReplicas {
  try await CausalReplicas(CausalReplicaSetup(count: replicaCount, registry: SchemaFixture.registry, seed: seed))
}

func readings<R: NovelForgeRecord>(_ ref: EntityRef, as _: R.Type, in replicas: CausalReplicas) async throws -> [RecordReading<R>] {
  var result = [RecordReading<R>]()
  for index in 0..<replicas.count { result.append(try await Harness.read(ref, as: R.self, in: await replicas.store(index))) }
  return result
}

func expectAgreement<R: NovelForgeRecord>(_ ref: EntityRef, as _: R.Type, in replicas: CausalReplicas, is expected: RecordReading<R>) async throws {
  for reading in try await readings(ref, as: R.self, in: replicas) { #expect(reading == expected) }
}

func live<R>(_ record: R) -> RecordReading<R> { .readable(RecordEntry(record: record, isRemoved: false)) }
func removed<R>(_ record: R) -> RecordReading<R> { .readable(RecordEntry(record: record, isRemoved: true)) }

func writeCreate<S: RemovableSubject>(_: S.Type, _ record: S.Record, on index: Int, in replicas: CausalReplicas) async throws {
  _ = try await replicas.write(index) { transaction in try record.create(in: &transaction) }
}

func writeEdit<R>(_ edit: SubjectEdit<R>, on index: Int, in replicas: CausalReplicas) async throws {
  let perform = edit.perform
  _ = try await replicas.write(index) { transaction in try perform(&transaction) }
}

func writeRemove<R: RemovableRecord>(_ record: R, on index: Int, in replicas: CausalReplicas) async throws {
  let ref = record.ref
  _ = try await replicas.write(index) { transaction in try R.remove(ref, in: &transaction) }
}

func removalWinsOverAnEditWithAnEarlierClock<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  try await forAll(iterations: 6, seed: seed) { generator in
    let replicas = try await replicas(seed: generator.next())
    let record = S.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
    try await writeCreate(S.self, record, on: 0, in: replicas)
    try await replicas.settle()
    let edit = S.randomEdit(&generator, of: record)
    await replicas.advanceClock(of: 1, by: .seconds(5))
    try await writeEdit(edit, on: 1, in: replicas)
    await replicas.advanceClock(of: 0, by: .seconds(10))
    try await writeRemove(record, on: 0, in: replicas)
    try await replicas.settle()
    try await expectAgreement(record.ref, as: S.Record.self, in: replicas, is: removed(edit.applied(to: record)))
  }
}

func anEditAfterARemovalDoesNotRevive<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  try await forAll(iterations: 6, seed: seed) { generator in
    let replicas = try await replicas(seed: generator.next())
    let record = S.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
    try await writeCreate(S.self, record, on: 0, in: replicas)
    try await replicas.settle()
    try await writeRemove(record, on: 0, in: replicas)
    let edit = S.randomEdit(&generator, of: record)
    await replicas.advanceClock(of: 1, by: .seconds(10))
    try await writeEdit(edit, on: 1, in: replicas)
    try await replicas.settle()
    let afterEdit = removed(edit.applied(to: record))
    try await expectAgreement(record.ref, as: S.Record.self, in: replicas, is: afterEdit)

    let restored = edit.applied(to: record)
    await replicas.advanceClock(of: 2, by: .seconds(10))
    _ = try await replicas.write(2) { transaction in try restored.restore(in: &transaction) }
    try await replicas.settle()
    try await expectAgreement(record.ref, as: S.Record.self, in: replicas, is: live(restored))
  }
}

func fieldsEditedOnDifferentReplicasMerge<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  try await forAll(iterations: 6, seed: seed) { generator in
    let replicas = try await replicas(seed: generator.next())
    let record = S.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
    try await writeCreate(S.self, record, on: 0, in: replicas)
    try await replicas.settle()
    let (earlier, later) = (S.randomEdit(&generator, of: record), S.randomEdit(&generator, of: record))
    await replicas.advanceClock(of: 1, by: .seconds(5))
    try await writeEdit(earlier, on: 1, in: replicas)
    await replicas.advanceClock(of: 2, by: .seconds(10))
    try await writeEdit(later, on: 2, in: replicas)
    try await replicas.settle()
    var expected = record
    earlier.apply(&expected)
    later.apply(&expected)
    try await expectAgreement(record.ref, as: S.Record.self, in: replicas, is: live(expected))
  }
}

func concurrentCreatesComeWholeFromOneReplica<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  try await forAll(iterations: 6, seed: seed) { generator in
    let replicas = try await replicas(seed: generator.next())
    let (novel, key) = (generator.uuid(), Gen.key(&generator))
    let (first, second, third) = (S.random(&generator, novel: novel, key: key), S.random(&generator, novel: novel, key: key), S.random(&generator, novel: novel, key: key))
    try await writeCreate(S.self, first, on: 0, in: replicas)
    try await writeCreate(S.self, second, on: 1, in: replicas)
    await replicas.advanceClock(of: 2, by: .seconds(5))
    try await writeCreate(S.self, third, on: 2, in: replicas)
    try await replicas.settle()
    try await expectAgreement(first.ref, as: S.Record.self, in: replicas, is: live(third))
  }
}

func settlesToTheSameRecordsEverywhere<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  try await forAll(iterations: ProjectionProperty.iterations(full: 60), seed: seed) { generator in
    let replicas = try await replicas(seed: generator.next())
    let novel = generator.uuid()
    let keys = ["key-0", "key-1"]
    let templates = keys.map { S.random(&generator, novel: novel, key: $0) }
    for _ in 0..<14 {
      let position = generator.int(in: 0...(keys.count - 1))
      let template = templates[position]
      let index = generator.int(in: 0...(replicaCount - 1))
      switch generator.int(in: 0...99) {
      case 0..<20:
        try await writeCreate(S.self, S.random(&generator, novel: novel, key: keys[position]), on: index, in: replicas)
      case 20..<45:
        try await writeEdit(S.randomEdit(&generator, of: template), on: index, in: replicas)
      case 45..<55:
        try await writeRemove(template, on: index, in: replicas)
      case 55..<65:
        let ref = template.ref
        _ = try await replicas.write(index) { transaction in
          guard case .readable(let entry) = try S.Record.read(ref, in: transaction), entry.isRemoved else { return false }
          _ = try entry.record.restore(in: &transaction)
          return true
        }
      case 65..<75:
        await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...3)))
      default:
        _ = try await replicas.step(using: &generator)
      }
    }
    try await replicas.settle()

    let results = try await (0..<replicaCount).asyncMap { index in
      try await replicas.store(index).read { transaction in try S.Record.listing(novel: novel, in: transaction) }
    }
    for result in results.dropFirst() { #expect(result == results[0]) }
    for template in templates {
      let all = try await readings(template.ref, as: S.Record.self, in: replicas)
      for reading in all.dropFirst() { #expect(reading == all[0]) }
      guard let group = S.groupMember, let entry = all[0].entry else { continue }
      let written = await replicas.records().filter { $0.key == template.ref.key }.compactMap { $0.fields[group] }
      let value = try #require(entry.record.fields.members[group])
      #expect(written.contains(value), "\(group) of \(template.ref.key) did not come whole from one write")
    }
  }
}

extension Sequence {
  fileprivate func asyncMap<Result>(_ transform: (Element) async throws -> Result) async throws -> [Result] {
    var result = [Result]()
    for element in self { result.append(try await transform(element)) }
    return result
  }
}

@Suite("Typed records across replicas", .timeLimit(.minutes(2)))
struct RecordReplicaTests {
  @Test func shouldLetAVolumeRemovalWithALaterClockWinOverAnEdit() async throws { try await removalWinsOverAnEditWithAnEarlierClock(VolumeSubject.self, seed: 0x11) }
  @Test func shouldLetAMilestoneRemovalWithALaterClockWinOverAnEdit() async throws { try await removalWinsOverAnEditWithAnEarlierClock(MilestoneSubject.self, seed: 0x12) }
  @Test func shouldLetAThreadRemovalWithALaterClockWinOverAnEdit() async throws { try await removalWinsOverAnEditWithAnEarlierClock(ThreadSubject.self, seed: 0x13) }
  @Test func shouldLetAMysteryRemovalWithALaterClockWinOverAnEdit() async throws { try await removalWinsOverAnEditWithAnEarlierClock(MysterySubject.self, seed: 0x14) }

  @Test func shouldKeepARemovedVolumeRemovedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws { try await anEditAfterARemovalDoesNotRevive(VolumeSubject.self, seed: 0x21) }
  @Test func shouldKeepARemovedMilestoneRemovedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws {
    try await anEditAfterARemovalDoesNotRevive(MilestoneSubject.self, seed: 0x22)
  }
  @Test func shouldKeepARemovedThreadRemovedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws { try await anEditAfterARemovalDoesNotRevive(ThreadSubject.self, seed: 0x23) }
  @Test func shouldKeepARemovedMysteryRemovedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws {
    try await anEditAfterARemovalDoesNotRevive(MysterySubject.self, seed: 0x24)
  }

  @Test func shouldMergeVolumeFieldsEditedOnDifferentReplicas() async throws { try await fieldsEditedOnDifferentReplicasMerge(VolumeSubject.self, seed: 0x31) }
  @Test func shouldMergeMilestoneFieldsEditedOnDifferentReplicas() async throws { try await fieldsEditedOnDifferentReplicasMerge(MilestoneSubject.self, seed: 0x32) }
  @Test func shouldMergeThreadFieldsEditedOnDifferentReplicas() async throws { try await fieldsEditedOnDifferentReplicasMerge(ThreadSubject.self, seed: 0x33) }
  @Test func shouldMergeMysteryFieldsEditedOnDifferentReplicas() async throws { try await fieldsEditedOnDifferentReplicasMerge(MysterySubject.self, seed: 0x34) }

  @Test func shouldTakeAConcurrentlyCreatedVolumeWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(VolumeSubject.self, seed: 0x41) }
  @Test func shouldTakeAConcurrentlyCreatedMilestoneWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(MilestoneSubject.self, seed: 0x42) }
  @Test func shouldTakeAConcurrentlyCreatedThreadWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(ThreadSubject.self, seed: 0x43) }
  @Test func shouldTakeAConcurrentlyCreatedMysteryWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(MysterySubject.self, seed: 0x44) }

  @Test func shouldSettleVolumesToTheSameRecordsOnEveryReplica() async throws { try await settlesToTheSameRecordsEverywhere(VolumeSubject.self, seed: 0x51) }
  @Test func shouldSettleMilestonesToTheSameRecordsOnEveryReplica() async throws { try await settlesToTheSameRecordsEverywhere(MilestoneSubject.self, seed: 0x52) }
  @Test func shouldSettleThreadsToTheSameRecordsOnEveryReplicaWithEachStatusWhole() async throws { try await settlesToTheSameRecordsEverywhere(ThreadSubject.self, seed: 0x53) }
  @Test func shouldSettleMysteriesToTheSameRecordsOnEveryReplicaWithEachStatusWhole() async throws { try await settlesToTheSameRecordsEverywhere(MysterySubject.self, seed: 0x54) }

  @Test func shouldSettleNovelsWithEachWordTargetWholeFromOneReplica() async throws {
    try await forAll(iterations: ProjectionProperty.iterations(full: 60), seed: 0x61) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let base = NovelSubject.random(&generator, novel: id, key: "")
      _ = try await replicas.write(0) { transaction in try base.create(in: &transaction) }
      try await replicas.settle()
      for _ in 0..<10 {
        let index = generator.int(in: 0...(replicaCount - 1))
        if generator.chance(0.6) {
          try await writeEdit(NovelSubject.randomEdit(&generator, of: base), on: index, in: replicas)
        } else if generator.chance(0.5) {
          await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...3)))
        } else {
          _ = try await replicas.step(using: &generator)
        }
      }
      try await replicas.settle()
      let all = try await readings(base.ref, as: NovelRecord.self, in: replicas)
      for reading in all.dropFirst() { #expect(reading == all[0]) }
      let entry = try #require(all[0].entry)
      let written = await replicas.records().filter { $0.key == base.ref.key }.compactMap { $0.fields["word_target"] }
      #expect(written.contains(try #require(entry.record.fields.members["word_target"])))
    }
  }
}
