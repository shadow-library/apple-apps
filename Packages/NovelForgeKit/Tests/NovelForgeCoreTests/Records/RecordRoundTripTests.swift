import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let iterations = 100

private func expectLive<R: NovelForgeRecord>(_ reading: RecordReading<R>, _ record: R) {
  #expect(reading == .readable(RecordEntry(record: record, isRemoved: false)))
}

private func expectRemoved<R: NovelForgeRecord>(_ reading: RecordReading<R>, _ record: R) {
  #expect(reading == .readable(RecordEntry(record: record, isRemoved: true)))
}

private func createAndEdit<S: RecordSubject>(_: S.Type, seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  try await forAll(iterations: iterations, seed: seed) { generator in
    let record = S.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
    #expect(try await Harness.read(record.ref, as: S.Record.self, in: store) == .absent)
    let created = try await Harness.create(record, in: store)
    #expect(Set(created.fields.keys) == Harness.memberNames(S.self))
    if S.Record.self is any RemovableRecord.Type { #expect(created.fields["removed"] == .bool(false)) }
    expectLive(try await Harness.read(record.ref, as: S.Record.self, in: store), record)

    var expected = record
    for _ in 0..<3 {
      let edit = S.randomEdit(&generator, of: expected)
      let change = try await Harness.perform(edit, in: store)
      #expect(Set(change.fields.keys) == edit.members)
      #expect(change.fields["removed"] == nil)
      expected = edit.applied(to: expected)
      expectLive(try await Harness.read(record.ref, as: S.Record.self, in: store), expected)
    }
  }
}

private func removalCycle<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  try await forAll(iterations: iterations, seed: seed) { generator in
    let (novel, key) = (generator.uuid(), Gen.key(&generator))
    let record = S.random(&generator, novel: novel, key: key)
    _ = try await Harness.create(record, in: store)

    let removal = try await Harness.remove(record, in: store)
    #expect(removal.fields == ["removed": .bool(true)])
    expectRemoved(try await Harness.read(record.ref, as: S.Record.self, in: store), record)

    let edit = S.randomEdit(&generator, of: record)
    _ = try await Harness.perform(edit, in: store)
    let edited = edit.applied(to: record)
    expectRemoved(try await Harness.read(record.ref, as: S.Record.self, in: store), edited)

    let restoration = try await Harness.restore(edited, in: store)
    #expect(Set(restoration.fields.keys) == Harness.memberNames(S.self))
    expectLive(try await Harness.read(record.ref, as: S.Record.self, in: store), edited)

    _ = try await Harness.remove(edited, in: store)
    let replacement = S.random(&generator, novel: novel, key: key)
    _ = try await Harness.create(replacement, in: store)
    expectLive(try await Harness.read(record.ref, as: S.Record.self, in: store), replacement)
  }
}

private func createOverLiveRecord<S: RemovableSubject>(_: S.Type, seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  try await forAll(iterations: 30, seed: seed) { generator in
    let (novel, key) = (generator.uuid(), Gen.key(&generator))
    _ = try await Harness.create(S.random(&generator, novel: novel, key: key), in: store)
    let replacement = S.random(&generator, novel: novel, key: key)
    _ = try await Harness.create(replacement, in: store)
    expectLive(try await Harness.read(replacement.ref, as: S.Record.self, in: store), replacement)
  }
}

@Suite("Typed record round trip", .timeLimit(.minutes(1)))
struct RecordRoundTripTests {
  @Test func shouldCreateAndEditANovelWithoutTouchingOtherFields() async throws { try await createAndEdit(NovelSubject.self, seed: 0xA1) }
  @Test func shouldCreateAndEditAVolumeWithoutTouchingOtherFields() async throws { try await createAndEdit(VolumeSubject.self, seed: 0xA2) }
  @Test func shouldCreateAndEditAMilestoneWithoutTouchingOtherFields() async throws { try await createAndEdit(MilestoneSubject.self, seed: 0xA3) }
  @Test func shouldCreateAndEditAThreadWithoutTouchingOtherFields() async throws { try await createAndEdit(ThreadSubject.self, seed: 0xA4) }
  @Test func shouldCreateAndEditAMysteryWithoutTouchingOtherFields() async throws { try await createAndEdit(MysterySubject.self, seed: 0xA5) }

  @Test func shouldRemoveRestoreAndRecreateAVolume() async throws { try await removalCycle(VolumeSubject.self, seed: 0xB2) }
  @Test func shouldRemoveRestoreAndRecreateAMilestone() async throws { try await removalCycle(MilestoneSubject.self, seed: 0xB3) }
  @Test func shouldRemoveRestoreAndRecreateAThread() async throws { try await removalCycle(ThreadSubject.self, seed: 0xB4) }
  @Test func shouldRemoveRestoreAndRecreateAMystery() async throws { try await removalCycle(MysterySubject.self, seed: 0xB5) }

  @Test func shouldOverwriteEveryFieldWhenAVolumeIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(VolumeSubject.self, seed: 0xC2) }
  @Test func shouldOverwriteEveryFieldWhenAMilestoneIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(MilestoneSubject.self, seed: 0xC3) }
  @Test func shouldOverwriteEveryFieldWhenAThreadIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(ThreadSubject.self, seed: 0xC4) }
  @Test func shouldOverwriteEveryFieldWhenAMysteryIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(MysterySubject.self, seed: 0xC5) }

  @Test func shouldSetAnOptionalToNullOnlyWhenTheEditSaysSo() async throws {
    let store = try SchemaFixture.store()
    let record = VolumeRecord(novel: SchemaFixture.novel, volume: "book-one", ordinal: 2, title: "One", objective: "Escape", body: "Text", goalMet: true)
    _ = try await Harness.create(record, in: store)
    var edit = VolumeEdit()
    edit.title = .set(nil)
    let change = try await store.write { [edit] transaction in
      try VolumeRecord.edit(novel: SchemaFixture.novel, volume: "book-one", edit, in: &transaction)
    }
    #expect(change.fields == ["title": .null])
    var expected = record
    expected.title = nil
    expectLive(try await Harness.read(record.ref, as: VolumeRecord.self, in: store), expected)
  }

  @Test(arguments: [-3, 0])
  func shouldReportAChapterBelowOneAsATypedKeyErrorFromTheInitialiserAndWriteNothing(_ chapter: Int) async throws {
    let store = try SchemaFixture.store()
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(chapter)) { try ChapterStubRecord(novel: SchemaFixture.novel, chapter: chapter) }
    #expect(try await store.read { transaction in try transaction.states(ofKind: NovelForgeKind.draft.entityKind).count } == 0)
  }

  @Test func shouldWriteAndReadAChapterKeyedRecordWhoseKeyIsValid() async throws {
    let store = try SchemaFixture.store()
    let record = try ChapterStubRecord(novel: SchemaFixture.novel, chapter: 3)
    #expect(record.ref == (try NovelForgeKey.draft(novel: SchemaFixture.novel, chapter: 3)))
    _ = try await Harness.create(record, in: store)
    _ = try await Harness.remove(record, in: store)
    expectRemoved(try await Harness.read(record.ref, as: ChapterStubRecord.self, in: store), record)
    _ = try await Harness.restore(record, in: store)
    expectLive(try await Harness.read(record.ref, as: ChapterStubRecord.self, in: store), record)
  }

  @Test func shouldRejectAnEditThatChangesNothing() async throws {
    let store = try SchemaFixture.store()
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try VolumeRecord.edit(novel: SchemaFixture.novel, volume: "book-one", VolumeEdit(), in: &transaction) }
    }
  }

  @Test func shouldReadAndListInsideAWriteTransaction() async throws {
    let store = try SchemaFixture.store()
    let record = MilestoneRecord(novel: SchemaFixture.novel, milestone: "rank-two", label: "Second rank", kind: .known(.rank))
    let (reading, listing) = try await store.write { transaction in
      _ = try record.create(in: &transaction)
      return (
        try MilestoneRecord.read(novel: SchemaFixture.novel, milestone: "rank-two", in: transaction), try MilestoneRecord.listing(novel: SchemaFixture.novel, in: transaction)
      )
    }
    expectLive(reading, record)
    #expect(listing.live == [record])
  }

  @Test func shouldNormaliseAKeyTheWayTheStoreDoes() async throws {
    let store = try SchemaFixture.store()
    let record = ThreadRecord(novel: SchemaFixture.novel, thread: "e\u{301}clair", status: ThreadProgress(state: .known(.open), chapter: nil))
    #expect(record.thread == "\u{E9}clair")
    _ = try await Harness.create(record, in: store)
    expectLive(try await Harness.read(ThreadRecord.ref(novel: SchemaFixture.novel, thread: "\u{E9}clair"), as: ThreadRecord.self, in: store), record)
  }

  @Test func shouldArchiveAndUnarchiveANovelThroughAnEdit() async throws {
    let store = try SchemaFixture.store()
    let record = NovelRecord(id: SchemaFixture.novel, name: "Aria")
    _ = try await Harness.create(record, in: store)
    for archived in [true, false] {
      var edit = NovelEdit()
      edit.archived = .set(archived)
      let change = try await store.write { [edit] transaction in try NovelRecord.edit(id: SchemaFixture.novel, edit, in: &transaction) }
      #expect(change.fields == ["archived": .bool(archived)])
      var expected = record
      expected.archived = archived
      expectLive(try await Harness.read(record.ref, as: NovelRecord.self, in: store), expected)
    }
  }
}
