import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private struct Book {
  let store: VaultStore

  static func make() async throws -> Book {
    let book = Book(store: try Projection.store(try Projection.reconciler()))
    try await Projection.createNovel(novel, in: book.store)
    return book
  }

  func run(_ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
    try await Projection.write(store, body)
  }

  func plan(_ chapter: Int, volume: String? = nil, _ contract: ChapterContract) async throws {
    try await run { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(volume: volume, contract), in: &$0) }
  }

  func verdicts() async throws -> [Int: Verdict] {
    try await PlanWorldTables.verdicts(novel, in: store)
  }
}

private let learnsLedger = contract(learns: [Learn("mara", "ledger")])

@Suite("Plan reveal derivation", .timeLimit(.minutes(2)))
struct PlanRevealDerivationTests {
  @Test
  func shouldHoldWhenTheFactIsDatedAtOrBeforeTheChapter() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", revealChapter: 3, in: &$0) }
    try await book.plan(3, learnsLedger)
    try await book.plan(2, learnsLedger)
    #expect(try await book.verdicts() == [3: Verdict(.holds), 2: Verdict(.violated, "ledger (needs chapter 3 or later)")])
  }

  @Test
  func shouldRequireADateOrAnUnlockForAnUndatedFact() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", in: &$0) }
    try await book.plan(1, learnsLedger)
    #expect(try await book.verdicts() == [1: Verdict(.violated, "ledger (needs a reveal chapter or an unlock condition)")])
  }

  @Test
  func shouldLetASeedFactWithoutAnUnlockThrough() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", revealChapter: 9, source: .seed, in: &$0) }
    try await book.plan(1, learnsLedger)
    #expect(try await book.verdicts() == [1: Verdict(.holds)])
  }

  @Test
  func shouldIgnoreAPlanWithoutAPointOfViewAndAnUnknownFact() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", in: &$0) }
    try await book.plan(1, contract(pov: [""], learns: [Learn("mara", "ledger")]))
    try await book.plan(2, contract(learns: [Learn("mara", "ghost")]))
    #expect(try await book.verdicts() == [1: Verdict(.holds), 2: Verdict(.holds)])
  }

  @Test
  func shouldUnlockAMilestoneOnlyFromTheClaimingChapterOn() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.milestone("rise")), in: &$0) }
    try await book.plan(1, learnsLedger)
    try await book.plan(2, contract(claims: ["rise"]))
    try await book.plan(3, learnsLedger)
    #expect(try await book.verdicts() == [1: Verdict(.violated, "ledger (needs milestone rise reached)"), 2: Verdict(.holds), 3: Verdict(.holds)])
    try await book.plan(2, contract())
    #expect(try await book.verdicts()[3] == Verdict(.violated, "ledger (needs milestone rise reached)"))
  }

  @Test
  func shouldJoinEveryMissingTermAndEveryFactAsTheReferenceRendersThem() async throws {
    let book = try await Book.make()
    try await book.run {
      try PlanWorldWrites.secret(novel: novel, "ledger", revealChapter: 4, unlock: unlock(.ending, .chapter(5)), in: &$0)
      try PlanWorldWrites.secret(novel: novel, "heir", unlock: unlock(.milestone("fall")), in: &$0)
    }
    try await book.plan(2, contract(learns: [Learn("mara", "ledger"), Learn("elias", "heir"), Learn("elias", "ledger")]))
    let reason = "ledger (needs chapter 4 or later and the planned ending or later and chapter 5 or later); heir (needs milestone fall reached)"
    #expect(try await book.verdicts() == [2: Verdict(.violated, reason)])
  }

  @Test
  func shouldUnlockTheEndingFromTheEndingPlanOn() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.ending), in: &$0) }
    try await book.plan(4, contract(learns: [Learn("mara", "ledger")], ending: true))
    try await book.plan(3, learnsLedger)
    #expect(try await book.verdicts() == [4: Verdict(.holds), 3: Verdict(.violated, "ledger (needs the planned ending or later)")])
  }

  @Test
  func shouldLetTheLatestOfTwoEndingsStandAndFlagTheOther() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.ending), in: &$0) }
    try await book.plan(3, contract(ending: true))
    try await book.plan(6, contract(ending: true))
    try await book.plan(4, learnsLedger)
    try await book.plan(7, learnsLedger)
    #expect(
      try await book.verdicts() == [3: Verdict(.holds), 4: Verdict(.violated, "ledger (needs the planned ending or later)"), 6: Verdict(.holds), 7: Verdict(.holds)])
    #expect(try await PlanWorldTables.rivalEndings(novel, in: book.store) == [3: 6])
    try await book.plan(6, contract())
    #expect(try await book.verdicts()[4] == Verdict(.holds))
    #expect(try await PlanWorldTables.rivalEndings(novel, in: book.store).isEmpty)
  }

  @Test
  func shouldFlagAPlanThatRivalsAFinalEnding() async throws {
    let book = try await Book.make()
    try await book.plan(2, contract(ending: true))
    try await book.run { try PlanWorldWrites.finalize(novel: novel, chapter: 2, contract(ending: true), in: &$0) }
    try await book.plan(5, contract(ending: true))
    #expect(try await PlanWorldTables.rivalEndings(novel, in: book.store) == [2: 5])
  }

  @Test
  func shouldFollowAVolumeReorder() async throws {
    let book = try await Book.make()
    try await book.run {
      try PlanWorldWrites.volume(novel: novel, "one", ordinal: 1, in: &$0)
      try PlanWorldWrites.volume(novel: novel, "two", ordinal: 2, in: &$0)
      try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.volume("two")), in: &$0)
    }
    try await book.plan(1, volume: "one", learnsLedger)
    #expect(try await book.verdicts() == [1: Verdict(.violated, "ledger (needs volume two reached)")])
    var edit = VolumeEdit()
    edit.ordinal = .set(0)
    let changes = edit
    try await book.run { _ = try VolumeRecord.edit(novel: novel, volume: "two", changes, in: &$0) }
    #expect(try await book.verdicts() == [1: Verdict(.holds)])
    try await book.run { _ = try VolumeRecord.remove(novel: novel, volume: "two", in: &$0) }
    #expect(try await book.verdicts() == [1: Verdict(.violated, "ledger (needs volume two reached)")])
  }

  @Test
  func shouldNotJudgeAPlanAtOrBeforeTheLatestFinalChapter() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", in: &$0) }
    try await book.plan(1, learnsLedger)
    try await book.plan(2, learnsLedger)
    try await book.run { try PlanWorldWrites.finalize(novel: novel, chapter: 1, learnsLedger, in: &$0) }
    #expect(try await book.verdicts() == [1: Verdict(.settled), 2: Verdict(.violated, "ledger (needs a reveal chapter or an unlock condition)")])
  }

  @Test
  func shouldReadAFinalChaptersClaimsFromItsCanonAndNeverFromItsPlan() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.milestone("rise")), in: &$0) }
    try await book.plan(1, contract(claims: ["rise"]))
    try await book.run { try PlanWorldWrites.finalize(novel: novel, chapter: 1, contract(claims: ["rise"]), in: &$0) }
    try await book.plan(1, contract())
    try await book.plan(2, learnsLedger)
    #expect(try await book.verdicts() == [1: Verdict(.settled), 2: Verdict(.holds)])
  }

  @Test
  func shouldNeverLetAnUnreadableUnlockOrSecretHold() async throws {
    let book = try await Book.make()
    try await book.run {
      try PlanWorldWrites.secret(novel: novel, "ledger", revealChapter: 1, unlock: .object(["all": .string("later")]), in: &$0)
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &$0)
    }
    try await book.plan(2, contract(learns: [Learn("mara", "ledger"), Learn("mara", "heir")]))
    #expect(try await book.verdicts() == [2: Verdict(.violated, "ledger (needs a readable unlock condition)")])
    try await book.run { _ = try $0.set(SecretRecord.ref(novel: novel, secret: "heir"), ["text": .int(1)]) }
    #expect(try await book.verdicts() == [2: Verdict(.violated, "ledger (needs a readable unlock condition); heir (needs a readable secret)")])
  }

  @Test
  func shouldSkipARemovedSecretUntilItIsRestored() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", in: &$0) }
    try await book.plan(1, learnsLedger)
    try await book.run { _ = try SecretRecord.remove(novel: novel, secret: "ledger", in: &$0) }
    #expect(try await book.verdicts() == [1: Verdict(.holds)])
    try await book.run { _ = try SecretRecord(novel: novel, secret: "ledger", text: "The ledger is forged.").restore(in: &$0) }
    #expect(try await book.verdicts() == [1: Verdict(.violated, "ledger (needs a reveal chapter or an unlock condition)")])
  }

  @Test
  func shouldMarkAnUnreadablePlanAndDropARemovedOne() async throws {
    let book = try await Book.make()
    try await book.plan(1, learnsLedger)
    try await book.plan(2, learnsLedger)
    try await book.run { _ = try $0.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 1), body: .object(["body": .int(1)])) }
    try await book.run { _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: 2), in: &$0) }
    #expect(try await book.verdicts() == [1: Verdict(.unreadable)])
  }

  @Test
  func shouldCountAnUnreadableCanonAsFinalWithoutReadingItsClaims() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.milestone("rise")), in: &$0) }
    try await book.plan(1, contract(claims: ["rise"]))
    try await book.plan(3, learnsLedger)
    let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 2)
    try await book.run { _ = try $0.set(key.ref, ["natural_key": key.stored, "canon": .string("newer")]) }
    #expect(try await book.verdicts() == [1: Verdict(.settled), 3: Verdict(.holds)])
  }

  @Test
  func shouldMatchKeysTypedDecomposedToTheirRecords() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "caf\u{E9}", unlock: unlock(.milestone("r\u{E9}ve")), in: &$0) }
    try await book.plan(1, contract(claims: ["re\u{301}ve"]))
    try await book.plan(2, contract(learns: [Learn("mara", "cafe\u{301}")]))
    #expect(try await book.verdicts() == [1: Verdict(.holds), 2: Verdict(.holds)])
  }

  @Test
  func shouldReplaceTheRowWhenOnlyTheSpellingOfAnUnlockKeyChanges() async throws {
    let book = try await Book.make()
    try await book.run { try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.milestone("r\u{E9}ve")), in: &$0) }
    try await book.plan(1, learnsLedger)
    var edit = SecretEdit()
    edit.unlock = .set(unlock(.milestone("re\u{301}ve")))
    let changes = edit
    try await book.run { _ = try SecretRecord.edit(novel: novel, secret: "ledger", changes, in: &$0) }
    let comparison = try await Projection.compare(try Projection.reconciler(), in: book.store)
    #expect(comparison.incremental == comparison.rebuilt)
    #expect(try await book.verdicts() == [1: Verdict(.violated, "ledger (needs milestone re\u{301}ve reached)")])
  }
}
