import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let iterations = 6
private let wrongType = JSONValue.array([.null])

func reading<S: RecordSubject>(_: S.Type, _ record: S.Record, _ members: [String: JSONValue], in store: VaultStore) async throws -> RecordReading<S.Record> {
  try await SchemaFixture.set(record.ref, members, in: store)
  return try await Harness.read(record.ref, as: S.Record.self, in: store)
}

func fresh<S: RecordSubject>(_: S.Type, _ generator: inout SeededGenerator) -> S.Record {
  S.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
}

func totality<S: RecordSubject>(_: S.Type, seed: UInt64, anyJSON: Set<String> = []) async throws {
  let store = try SchemaFixture.store()
  let newerStore = try Harness.newerVersionStore()
  var seeding = SeededGenerator(seed: seed)
  let names = try fresh(S.self, &seeding).storedMembers.keys.sorted()
  try await forAll(iterations: iterations, seed: seed) { generator in
    for name in names {
      let missing = fresh(S.self, &generator)
      var members = try missing.storedMembers
      members[name] = nil
      let afterRemoval = try await reading(S.self, missing, members, in: store)
      if S.requiredMembers.contains(name) {
        #expect(afterRemoval == .unreadable(.missing(field: name)), "missing \(name)")
      } else {
        #expect(afterRemoval.entry?.record.fields.members[name] == JSONValue.null, "missing \(name)")
      }

      let wrong = fresh(S.self, &generator)
      members = try wrong.storedMembers
      members[name] = wrongType
      let afterCorruption = try await reading(S.self, wrong, members, in: store)
      if name == "natural_key" {
        guard case .unreadable(.naturalKey) = afterCorruption else {
          Issue.record("wrong type of \(name) gave \(afterCorruption)")
          continue
        }
      } else if anyJSON.contains(name) {
        #expect(afterCorruption.entry?.record.fields.members[name] == wrongType, "\(name) carries any JSON")
      } else {
        #expect(afterCorruption == .unreadable(.invalid(field: name)), "wrong type \(name)")
      }
    }

    let extra = fresh(S.self, &generator)
    var members = try extra.storedMembers
    members[Harness.newerMember] = ["nested": [1, 2]]
    #expect(try await reading(S.self, extra, members, in: newerStore) == .readable(RecordEntry(record: extra, isRemoved: false)))

    if let (member, value) = S.unknownEnum {
      let unknown = fresh(S.self, &generator)
      members = try unknown.storedMembers
      members[member] = value
      let carried = try await reading(S.self, unknown, members, in: store)
      #expect(carried.entry?.record.fields.members[member] == value)
      #expect(try carried.entry?.record.storedMembers == members)
    }

    let absent = fresh(S.self, &generator)
    #expect(try await Harness.read(absent.ref, as: S.Record.self, in: store) == .absent)
  }
}

func mismatchedNaturalKey<S: RemovableSubject>(_: S.Type) async throws {
  let store = try SchemaFixture.store()
  var generator = SeededGenerator(seed: 0xD1)
  let record = fresh(S.self, &generator)
  let other = fresh(S.self, &generator)
  var members = try record.storedMembers
  members["natural_key"] = try other.storedMembers["natural_key"]
  guard case .unreadable(.naturalKey(.keyMismatch)) = try await reading(S.self, record, members, in: store) else {
    Issue.record("a natural key of another record was accepted")
    return
  }
}

@Suite("Typed record totality", TestTimeLimit.property)
struct RecordTotalityTests {
  @Test func shouldReadANovelTotally() async throws { try await totality(NovelSubject.self, seed: 0xE1) }
  @Test func shouldReadAVolumeTotally() async throws { try await totality(VolumeSubject.self, seed: 0xE2) }
  @Test func shouldReadAMilestoneTotally() async throws { try await totality(MilestoneSubject.self, seed: 0xE3) }
  @Test func shouldReadAThreadTotally() async throws { try await totality(ThreadSubject.self, seed: 0xE4) }
  @Test func shouldReadAMysteryTotally() async throws { try await totality(MysterySubject.self, seed: 0xE5) }

  @Test func shouldReportAVolumeWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(VolumeSubject.self) }
  @Test func shouldReportAMilestoneWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(MilestoneSubject.self) }
  @Test func shouldReportAThreadWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(ThreadSubject.self) }
  @Test func shouldReportAMysteryWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(MysterySubject.self) }

  @Test func shouldReportAMilestoneNaturalKeyOfAnotherKindAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let volume = VolumeRecord(novel: SchemaFixture.novel, volume: "aria", ordinal: 1)
    let milestone = MilestoneRecord(novel: SchemaFixture.novel, milestone: "aria", label: "Aria")
    var members = try milestone.storedMembers
    members["natural_key"] = volume.key.stored
    guard case .unreadable(.naturalKey) = try await reading(MilestoneSubject.self, milestone, members, in: store) else {
      Issue.record("a natural key of another kind was accepted")
      return
    }
  }

  @Test func shouldReportANovelWhoseRefIsNotAUUIDAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let ref = EntityRef(kind: NovelForgeKind.novel.entityKind, key: EntityKey("not-a-uuid") ?? EntityKey(uuid: SchemaFixture.novel))
    try await SchemaFixture.set(ref, NovelRecord(id: SchemaFixture.novel, name: "Aria").storedMembers, in: store)
    #expect(try await Harness.read(ref, as: NovelRecord.self, in: store) == .unreadable(.identity(ref)))
  }

  @Test func shouldReadHandWrittenVolumeStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = try NovelForgeKey(novel: SchemaFixture.novel, .volume("book-one"))
    try await SchemaFixture.set(
      key.ref, ["natural_key": key.stored, "removed": false, "ordinal": 3, "title": "Book One", "objective": nil, "body": "Text", "goal_met": true], in: store)
    let expected = VolumeRecord(novel: SchemaFixture.novel, volume: "book-one", ordinal: 3, title: "Book One", objective: nil, body: "Text", goalMet: true)
    #expect(try await Harness.read(key.ref, as: VolumeRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: false)))
  }

  @Test func shouldReadHandWrittenMilestoneStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = try NovelForgeKey(novel: SchemaFixture.novel, .milestone("rank-two"))
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "removed": true, "label": "Second rank", "subject": "aria", "kind": "learned_from"], in: store)
    let expected = MilestoneRecord(novel: SchemaFixture.novel, milestone: "rank-two", label: "Second rank", subject: "aria", kind: .known(.learnedFrom))
    #expect(try await Harness.read(key.ref, as: MilestoneRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: true)))
  }

  @Test func shouldReadHandWrittenThreadStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = try NovelForgeKey(novel: SchemaFixture.novel, .thread("the-locket"))
    try await SchemaFixture.set(
      key.ref,
      [
        "natural_key": key.stored, "removed": false, "summary": "Who owns it", "opened_chapter": 2, "status": ["state": "closed", "chapter": 9, "extra": 1], "payoff_window": 12,
        "payoff_milestone": nil, "payoff_volume": "book-one", "dormant": false,
      ], in: store)
    let expected = ThreadRecord(
      novel: SchemaFixture.novel, thread: "the-locket", summary: "Who owns it", openedChapter: 2, status: ThreadProgress(state: .known(.closed), chapter: 9), payoffWindow: 12,
      payoffMilestone: nil, payoffVolume: "book-one", dormant: false)
    #expect(try await Harness.read(key.ref, as: ThreadRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: false)))
  }

  @Test func shouldReadHandWrittenMysteryStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = try NovelForgeKey(novel: SchemaFixture.novel, .mystery("the-fire"))
    try await SchemaFixture.set(
      key.ref,
      [
        "natural_key": key.stored, "removed": false, "question": "Who lit it", "opened_chapter": 1, "status": ["state": "resolved", "chapter": 20], "truth_fact": "arson-fact",
        "payoff_window": nil, "payoff_milestone": "reveal", "payoff_volume": nil, "dormant": true,
      ], in: store)
    let expected = MysteryRecord(
      novel: SchemaFixture.novel, mystery: "the-fire", question: "Who lit it", openedChapter: 1, status: MysteryProgress(state: .known(.resolved), chapter: 20),
      truthFact: "arson-fact", payoffWindow: nil, payoffMilestone: "reveal", payoffVolume: nil, dormant: true)
    #expect(try await Harness.read(key.ref, as: MysteryRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: false)))
  }

  @Test func shouldReadHandWrittenNovelStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let ref = NovelForgeKey.novel(SchemaFixture.novel)
    try await SchemaFixture.set(
      ref,
      [
        "name": "Aria", "title": nil, "content_mode": "unrestricted", "cost_tier": "performant", "word_target": ["min": 1500, "max": 3000], "brief": "A brief", "premise": nil,
        "themes": ["loss", "home"], "theme": nil, "ending_question": nil, "ending": nil, "reader_promise": nil, "protagonist": "aria", "opposition": nil, "writing_style": "Terse",
        "archived": false,
      ], in: store)
    let expected = NovelRecord(
      id: SchemaFixture.novel, name: "Aria", contentMode: .known(.unrestricted), costTier: .known(.performant), wordTarget: WordTarget(min: 1500, max: 3000), brief: "A brief",
      themes: ["loss", "home"], protagonist: "aria", writingStyle: "Terse")
    #expect(try await Harness.read(ref, as: NovelRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: false)))
  }

  @Test func shouldReportAWordTargetMissingOneBoundAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let record = NovelRecord(id: SchemaFixture.novel, name: "Aria")
    var members = try record.storedMembers
    members["word_target"] = ["min": 1500]
    #expect(try await reading(NovelSubject.self, record, members, in: store) == .unreadable(.invalid(field: "word_target")))
  }

  @Test func shouldCarryAnUnknownEnumRawTextThroughARestore() async throws {
    let store = try SchemaFixture.store()
    let record = MilestoneRecord(novel: SchemaFixture.novel, milestone: "future", label: "Future", kind: .unknown("x_future_kind"))
    _ = try await Harness.create(record, in: store)
    _ = try await Harness.remove(record, in: store)
    let removed = try await Harness.read(record.ref, as: MilestoneRecord.self, in: store)
    let carried = try #require(removed.entry)
    #expect(carried.isRemoved)
    _ = try await Harness.restore(carried.record, in: store)
    let stored = try await SchemaFixture.record(record.ref, in: store)
    #expect(stored[field: "kind"]?.value == "x_future_kind")
  }
}
