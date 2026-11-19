import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let undated = ChapterContract(pov: [""])

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

private func book() throws -> VaultStore {
  try Projection.store(try Projection.reconciler(chapterAreaDerivations))
}

private func disclosed(_ store: VaultStore) async throws -> [String: Int] {
  try await ChapterTables.disclosure(novel, in: store)
}

private func plan(_ chapter: Int, _ contract: ChapterContract, in store: VaultStore) async throws {
  try await write(store) { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(contract), in: &transaction) }
}

/// Finalizes `chapter` with its plan head's contract and what it discloses, as finalize records them; with no plan, the canon names none and discloses nothing.
private func finalize(_ chapter: Int, recording: Bool = true, in store: VaultStore) async throws {
  try await write(store) { transaction in
    let contract = try ChapterWrites.planContract(novel: novel, chapter: chapter, in: transaction)
    let disclosed = contract == nil ? [] : try ChapterFinalize.disclosed(novel: novel, chapter: chapter, in: transaction)
    let canon = Canon(
      draftRevision: "v:draft", planRevision: contract.map { _ in "v:plan" }, body: "Final \(chapter).", contract: contract ?? ChapterContract(),
      disclosed: recording ? disclosed : nil)
    _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon).finalize(in: &transaction)
  }
}

private func remove(_ key: String, in store: VaultStore) async throws {
  try await write(store) { transaction in _ = try SecretRecord.remove(novel: novel, secret: key, in: &transaction) }
}

private func restore(_ key: String, revealChapter: Int?, in store: VaultStore) async throws {
  try await write(store) { transaction in
    _ = try SecretRecord(novel: novel, secret: key, text: "Restored.", revealChapter: revealChapter, unlock: nil, source: .known(.manual)).restore(in: &transaction)
  }
}

private func secret(_ key: String, revealChapter: Int? = nil, unlock: JSONValue? = nil, source: FactSource = .manual, in store: VaultStore) async throws {
  try await write(store) { transaction in
    try PlanWorldWrites.secret(novel: novel, key, revealChapter: revealChapter, unlock: unlock, source: source, in: &transaction)
  }
}

private func reschedule(_ key: String, revealChapter: Int?, in store: VaultStore) async throws {
  var edit = SecretEdit()
  edit.revealChapter = .set(revealChapter)
  let changes = edit
  try await write(store) { transaction in _ = try SecretRecord.edit(SecretRecord.ref(novel: novel, secret: key), changes.fields, in: &transaction) }
}

@Suite("Reader disclosure", TestTimeLimit.standard)
struct ReaderDisclosureTests {
  @Test func shouldDiscloseALearnedSecretAtTheFirstFinalChapterThatTeachesItAndNeverFromAPlan() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await plan(2, contract(learns: [Learn("ghost", "heir")]), in: store)
    #expect(try await disclosed(store).isEmpty)
    try await finalize(1, in: store)
    try await finalize(2, in: store)
    #expect(try await disclosed(store) == ["heir": 1])
  }

  @Test func shouldDiscloseALearnWhoseLearnerIsNoRecord() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 2, in: store)
    try await plan(1, contract(), in: store)
    try await plan(2, contract(learns: [Learn("nobody", "heir"), Learn("nobody", "ghost")]), in: store)
    for chapter in 1...2 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store) == ["heir": 2])
  }

  @Test func shouldDiscloseNothingFromAContractThatTeachesNothingEvenWhenADateFalls() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 2, in: store)
    for chapter in 1...2 { try await plan(chapter, contract(), in: store) }
    for chapter in 1...2 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store).isEmpty)
  }

  @Test func shouldDiscloseADatedSecretWhereItFirstBecomesShowableUnderAPlanWithoutAContract() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 3, in: store)
    try await secret("rule", revealChapter: 1, in: store)
    try await secret("someday", in: store)
    try await secret("promise", revealChapter: 2, source: .seed, in: store)
    for chapter in 1...4 { try await plan(chapter, undated, in: store) }
    for chapter in 1...2 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store).isEmpty)
    for chapter in 3...4 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store) == ["heir": 3])
  }

  @Test func shouldDiscloseOpenCanonAndASeedPromiseOnlyThroughAContractThatTeachesThem() async throws {
    let store = try book()
    try await secret("rule", revealChapter: 1, in: store)
    try await secret("promise", revealChapter: 5, source: .seed, in: store)
    try await plan(1, contract(learns: [Learn("mara", "rule"), Learn("mara", "promise")]), in: store)
    try await finalize(1, in: store)
    #expect(try await disclosed(store) == ["rule": 1, "promise": 1])
  }

  @Test func shouldDiscloseADatedSecretWhereItsUnlockFirstHolds() async throws {
    let store = try book()
    try await write(store) { transaction in try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction) }
    try await secret("heir", revealChapter: 2, unlock: unlock(.milestone("rise")), in: store)
    for chapter in 1...4 { try await plan(chapter, chapter == 3 ? ChapterContract(pov: [""], claimedMilestones: ["rise"]) : undated, in: store) }
    for chapter in 1...2 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store).isEmpty)
    for chapter in 3...4 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store) == ["heir": 3])
  }

  @Test func shouldDiscloseNothingFromAChapterFinalizedWithoutAPlan() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 2, in: store)
    try await secret("tide", revealChapter: 3, in: store)
    try await plan(1, undated, in: store)
    try await plan(3, undated, in: store)
    for chapter in 1...3 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store) == ["tide": 3])
  }

  @Test func shouldDiscloseNothingFromACanonWhoseContractCannotBeRead() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await plan(2, contract(learns: [Learn("mara", "heir")]), in: store)
    try await write(store) { transaction in
      let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 1)
      _ = try transaction.set(key.ref, ["natural_key": key.stored, "canon": .object(["plan_revision": .string("v:plan"), "contract": .string("newer")])])
    }
    #expect(try await disclosed(store).isEmpty)
    try await finalize(2, in: store)
    #expect(try await disclosed(store) == ["heir": 2])
  }

  @Test func shouldNotLetAChapterDiscloseASecretCreatedAfterItWasFinalized() async throws {
    let store = try book()
    for chapter in 1...2 { try await plan(chapter, contract(learns: [Learn("mara", "late")]), in: store) }
    try await finalize(1, in: store)
    try await secret("late", revealChapter: 1, in: store)
    #expect(try await disclosed(store).isEmpty)
    try await finalize(2, in: store)
    #expect(try await disclosed(store) == ["late": 2])
  }

  @Test func shouldDiscloseASecretCreatedBetweenTheApprovalAndFinalize() async throws {
    let store = try book()
    try await write(store) { transaction in
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "late")])), in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    try await secret("late", revealChapter: 1, in: store)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await ChapterTables.knowledge(novel, in: store).isEmpty)
    #expect(try await disclosed(store) == ["late": 1])
  }

  @Test func shouldNeverDiscloseASecretRemovedAndCreatedAgainAfterTheChapterThatDisclosedIt() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await finalize(1, in: store)
    try await remove("heir", in: store)
    #expect(try await disclosed(store).isEmpty)
    try await restore("heir", revealChapter: 1, in: store)
    #expect(try await disclosed(store).isEmpty)
  }

  @Test func shouldDiscloseASecretRemovedAndRestoredBeforeTheChapterWasFinalized() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await remove("heir", in: store)
    try await restore("heir", revealChapter: 1, in: store)
    try await finalize(1, in: store)
    #expect(try await disclosed(store) == ["heir": 1])
  }

  @Test func shouldNeverDiscloseASecretWhoseUnlockCannotBeRead() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, unlock: .object(["all": .string("newer")]), in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await finalize(1, in: store)
    #expect(try await disclosed(store).isEmpty)
  }

  @Test func shouldKeepTheDisclosureThroughAnAmendmentAManualRevealAndARetraction() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await finalize(1, in: store)
    try await write(store) { transaction in
      _ = try FinalChapterRecord.amend(try FinalChapterRecord.ref(novel: novel, chapter: 1), FinalChapterText(body: "Amended."), in: &transaction)
      try ChapterWrites.reveal(novel: novel, fact: "heir", entity: "mara", chapter: 4, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.retract(novel: novel, fact: "heir", entity: "mara", in: &transaction) }
    #expect(try await disclosed(store) == ["heir": 1])
  }

  @Test func shouldKeepTheChapterRecordedAtFinalizeWhenTheScheduleMovesLater() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 2, in: store)
    for chapter in 1...3 { try await plan(chapter, undated, in: store) }
    for chapter in 1...2 { try await finalize(chapter, in: store) }
    #expect(try await disclosed(store) == ["heir": 2])
    try await reschedule("heir", revealChapter: 3, in: store)
    try await finalize(3, in: store)
    #expect(try await disclosed(store) == ["heir": 2])
  }

  @Test func shouldNeverDiscloseADatedSecretMovedEarlierBehindTheFinalChapters() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 5, in: store)
    for chapter in 1...4 { try await plan(chapter, undated, in: store) }
    for chapter in 1...3 { try await finalize(chapter, in: store) }
    try await reschedule("heir", revealChapter: 2, in: store)
    try await finalize(4, in: store)
    #expect(try await disclosed(store).isEmpty)
  }

  @Test func shouldNeverDiscloseALearnLockedAtFinalizeThatUnlocksLater() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 3, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await finalize(1, in: store)
    try await reschedule("heir", revealChapter: 1, in: store)
    #expect(try await disclosed(store).isEmpty)
  }

  @Test func shouldDiscloseNothingFromACanonThatRecordedNoSet() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "heir")]), in: store)
    try await finalize(1, recording: false, in: store)
    #expect(try await disclosed(store).isEmpty)
  }

  @Test func shouldRecordWhatAChapterShowsEvenWhenAnEarlierChapterDisclosedIt() async throws {
    let store = try book()
    try await secret("heir", revealChapter: 1, in: store)
    for chapter in 1...2 { try await plan(chapter, contract(learns: [Learn("mara", "heir")]), in: store) }
    for chapter in 1...2 { try await finalize(chapter, in: store) }
    #expect(try await ChapterTables.recorded(in: store) == [["heir"], ["heir"]])
    #expect(try await disclosed(store) == ["heir": 1])
    try await Projection.purge(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: store)
    #expect(try await disclosed(store) == ["heir": 2])
  }

  @Test func shouldDiscloseAKeyTypedDecomposedInTheContractAsItsRecord() async throws {
    let store = try book()
    try await secret("f_\u{E9}", revealChapter: 1, in: store)
    try await plan(1, contract(learns: [Learn("mara", "f_e\u{301}")]), in: store)
    try await finalize(1, in: store)
    let rows = try await Projection.fetch(ReaderDisclosureDerivation.request(for: novel), in: store)
    #expect(rows.map { Array($0.secret.unicodeScalars) } == [Array("f_\u{E9}".unicodeScalars)])
  }
}
