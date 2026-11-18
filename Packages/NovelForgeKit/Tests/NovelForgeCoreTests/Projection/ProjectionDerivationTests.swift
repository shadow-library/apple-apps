import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel

@Suite("Projection derivations", .timeLimit(.minutes(2)))
struct ProjectionDerivationTests {
  @Test func shouldPutTheCursorOnTheFirstChapterThatIsNotFinal() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, in: store)
    #expect(try await Projection.cursors(in: store) == [novel: 1])

    for chapter in [1, 2, 4] { try await Projection.finalize(novel: novel, chapter: chapter, in: store) }
    #expect(try await Projection.finals(in: store).map(\.chapter) == [1, 2, 4])
    #expect(try await Projection.finals(in: store).allSatisfy(\.isReadable))
    #expect(try await Projection.cursors(in: store) == [novel: 3])

    try await Projection.finalize(novel: novel, chapter: 3, in: store)
    #expect(try await Projection.cursors(in: store) == [novel: 5])
  }

  @Test func shouldKeepEachNovelsChaptersApart() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, in: store)
    try await Projection.createNovel(other, in: store)
    try await Projection.finalize(novel: other, chapter: 1, in: store)
    #expect(try await Projection.cursors(in: store) == [novel: 1, other: 2])
  }

  @Test func shouldNotChangeTheFinalSetWhenTheSameChapterIsFinalizedAgain() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.finalize(novel: novel, chapter: 1, body: "First.", in: store)
    let before = try await Projection.derived(reconciler, in: store)
    try await Projection.finalize(novel: novel, chapter: 1, body: "Second.", in: store)
    #expect(try await Projection.derived(reconciler, in: store) == before)
  }

  @Test func shouldIgnoreAnAmendmentWhenDecidingWhatIsFinal() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.finalize(novel: novel, chapter: 1, in: store)
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: 1)
    _ = try await Projection.write(store) { transaction in try FinalChapterRecord.amend(ref, FinalChapterText(body: "Amended."), in: &transaction) }
    #expect(try await Projection.finals(in: store).map(\.chapter) == [1])
    #expect(try await Projection.cursors(in: store) == [novel: 2])
  }

  @Test func shouldIndexRecordsUnderTheirNovelWithTheirStatus() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, in: store)
    let volume = VolumeRecord(novel: novel, volume: "one", ordinal: 1)
    _ = try await Projection.write(store) { transaction in try volume.create(in: &transaction) }
    let entry = NotebookEntryRecord(novel: novel, entryKind: .known(.decision), topic: "tone", statement: "Keep it dry.")
    _ = try await Projection.write(store) { transaction in try entry.append(in: &transaction) }

    #expect(try await Projection.entry(NovelForgeKey.novel(novel), in: store) == IndexEntry(ref: NovelForgeKey.novel(novel), novel: novel, status: .live))
    #expect(try await Projection.indexed(volume.ref, in: store)?.status == .live)
    #expect(try await Projection.entry(entry.ref, in: store) == IndexEntry(ref: entry.ref, novel: novel, status: .live))
    #expect(try await Projection.indexed(entry.ref, in: store)?.ref == entry.ref)

    _ = try await Projection.write(store) { transaction in try VolumeRecord.remove(volume.ref, in: &transaction) }
    #expect(try await Projection.indexed(volume.ref, in: store)?.status == .removed)
    _ = try await Projection.write(store) { transaction in try volume.restore(in: &transaction) }
    #expect(try await Projection.indexed(volume.ref, in: store)?.status == .live)

    let kinds = try await Projection.fetch(IndexedRecord.filter(Column("novel") == novel).order(Column("kind")), in: store).map(\.kind)
    #expect(kinds == [.notebookEntry, .novel, .volume])
  }

  @Test func shouldIndexTheReviewAndFinalizeKindsUnderTheirNovelAndChapter() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    var generator = SeededGenerator(seed: 0xD1A)
    try await Projection.createNovel(novel, in: store)
    let appended: [(record: any AppendedRecord, chapter: Int)] = [
      (Gen.chapterReview(&generator, novel: novel, chapter: 2), 2), (Gen.finalizeReview(&generator, novel: novel, chapter: 3), 3),
      (Gen.refreshReport(&generator, novel: novel, chapter: 4), 4), (Gen.approval(&generator, novel: novel, chapter: 5), 5),
    ]
    for (record, _) in appended {
      let (ref, item) = (record.ref, record.item)
      _ = try await Projection.write(store) { transaction in try transaction.append(ref, item: item) }
    }
    let answer = try FinalizeDecisionRecord(
      novel: novel, chapter: 6, draftRevision: "v:one", item: "summary", answer: StoredFinalizeAnswer(decision: .known(.kept), proposalDigest: "d"))
    _ = try await Projection.write(store) { transaction in
      _ = try answer.create(in: &transaction)
      return try ReviewRemedyRecord.set(
        novel: novel, review: SchemaFixture.review, finding: "f1", ReviewRemedy(action: .known(.dismissed), fingerprint: "fp"), in: &transaction)
    }
    let draft = try DraftRecord(novel: novel, chapter: 7, content: DraftContent(body: "Waves.", source: .known(.generated)))
    _ = try await Projection.write(store) { transaction in try draft.create(in: &transaction) }

    for (record, chapter) in appended {
      let row = try #require(try await Projection.indexed(record.ref, in: store))
      #expect(row.novel == novel && row.chapter == chapter && row.status == .live, "\(record.ref.kind)")
    }
    let remedyRef = ReviewRemedyRecord.ref(novel: novel, review: SchemaFixture.review, finding: "f1")
    for (ref, chapter) in [(answer.ref, 6), (draft.ref, 7), (remedyRef, nil), (NovelForgeKey.novel(novel), nil)] as [(EntityRef, Int?)] {
      let row = try #require(try await Projection.indexed(ref, in: store))
      #expect(row.novel == novel && row.chapter == chapter && row.status == .live, "\(ref.kind)")
    }

    let broken = Gen.chapterReview(&generator, novel: novel, chapter: 8)
    var item = broken.item
    item["disposition"] = 3
    let brokenItem = item
    _ = try await Projection.write(store) { transaction in try transaction.append(broken.ref, item: brokenItem) }
    #expect(try await Projection.indexed(broken.ref, in: store).map { [$0.novel == novel, $0.chapter == 8, $0.status == .unreadable] } == [true, true, true])
    let unchaptered = Gen.chapterReview(&generator, novel: novel, chapter: 8)
    item = unchaptered.item
    item["chapter"] = "eight"
    let unchapteredItem = item
    _ = try await Projection.write(store) { transaction in try transaction.append(unchaptered.ref, item: unchapteredItem) }
    #expect(try await Projection.indexed(unchaptered.ref, in: store).map { [$0.novel == novel, $0.chapter == nil, $0.status == .unreadable] } == [true, true, true])
    try await Projection.set(answer.ref, ["decision": "kept"], in: store)
    #expect(try await Projection.indexed(answer.ref, in: store).map { [$0.novel == novel, $0.chapter == 6, $0.status == .unreadable] } == [true, true, true])
    _ = try await Projection.write(store) { transaction in try ReviewRemedyRecord.clear(novel: novel, review: SchemaFixture.review, finding: "f1", in: &transaction) }
    #expect(try await Projection.indexed(remedyRef, in: store)?.status == .live)

    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test func shouldReachAPerNovelAggregateThroughTheIndexWhenARecordIsEdited() async throws {
    let reconciler = try Projection.reconciler(NovelForgeDerivations.standard + [HighestVolumeDerivation()])
    let store = try Projection.store(reconciler)
    let volume = VolumeRecord(novel: novel, volume: "one", ordinal: 1)
    _ = try await Projection.write(store) { transaction in try volume.create(in: &transaction) }
    let digest = try await Projection.indexed(volume.ref, in: store)?.digest
    try await Projection.set(volume.ref, ["ordinal": .int(7)], in: store)
    #expect(try await Projection.indexed(volume.ref, in: store)?.digest != digest)
    #expect(try await Projection.fetch(HighestVolumeDerivation.request(for: novel), in: store) == [HighestVolume(novel: novel, ordinal: 7)])
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test func shouldReachAnAggregateOfVersionsWhenARevisionThatIsNotTheHeadArrives() async throws {
    let reconciler = try Projection.reconciler(NovelForgeDerivations.standard + [VersionCountDerivation()])
    let store = try Projection.store(reconciler)
    let draft = try DraftRecord(novel: novel, chapter: 1, content: DraftContent(body: "Waves.", source: .known(.generated)))
    _ = try await Projection.write(store) { transaction in try draft.create(in: &transaction) }
    let digest = try await Projection.indexed(draft.ref, in: store)?.digest
    let body = DraftContent(body: "Tide.", source: .known(.generated)).json
    _ = try await Projection.write(store) { transaction in try transaction.revise(draft.ref, body: body, head: false) }
    #expect(try await Projection.indexed(draft.ref, in: store)?.digest != digest)
    #expect(try await Projection.fetch(VersionCountDerivation.request(for: novel), in: store) == [VersionCount(novel: novel, versions: 2)])
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test func shouldFindTheFirstChapterThatIsNotFinal() {
    #expect(StoryCursorDerivation.firstNotFinal(among: []) == 1)
    #expect(StoryCursorDerivation.firstNotFinal(among: [2, 3]) == 1)
    #expect(StoryCursorDerivation.firstNotFinal(among: [1, 2, 3]) == 4)
    #expect(StoryCursorDerivation.firstNotFinal(among: [1, 3, 4]) == 2)
    #expect(StoryCursorDerivation.firstNotFinal(among: [1, 2, Int.max]) == 3)
    #expect(StoryCursorDerivation.firstNotFinal(among: [Int.max]) == 1)
  }
}
