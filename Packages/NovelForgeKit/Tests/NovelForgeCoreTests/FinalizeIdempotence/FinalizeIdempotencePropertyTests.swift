import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let replicaCount = 3

private func expect(_ condition: Bool, _ what: @autoclosure () -> String) throws {
  guard condition else { throw IdempotenceFailure(description: what()) }
}

private func expectUnchanged(_ book: ChapterBook, since dump: [String], after what: String) async throws {
  let now = try await VaultDump.everything(in: book.store)
  let (added, removed) = (now.filter { !dump.contains($0) }, dump.filter { !now.contains($0) })
  try expect(now == dump, "\(what) wrote: added \(added) removed \(removed)")
}

private func answerRefusal(_ book: ChapterBook, chapter: Int, item: String) async -> FinalizeAnswerError? {
  do throws(FinalizeAnswerError) {
    try await book.store.decideFinalizeItem(novel: book.novel, chapter: chapter, item: item, decision: .kept)
    return nil
  } catch {
    return error
  }
}

private func resume(_ card: UUID?, on book: ChapterBook) async throws {
  guard let card else { return }
  _ = try await book.store.resumeProposalActions(card, novel: book.novel)
}

/// Replica 0 commits once and then asks again by every path; nothing the second asks may write.
private func finalizeTwice(_ finalizeCase: FinalizeCase, _ book: ChapterBook, card: UUID?) async throws {
  let before = try await VaultDump.everything(in: book.store)
  let first = await book.attempt(finalizeCase, card: card)
  try expect(first == finalizeCase.first, "the first commit answered \(first), not \(finalizeCase.first)")
  if case .refused = first, card == nil { try await expectUnchanged(book, since: before, after: "a refused commit") }
  let once = try await VaultDump.everything(in: book.store)

  let again = await book.attempt(finalizeCase, card: card)
  try expect(again == finalizeCase.again, "the second commit answered \(again), not \(finalizeCase.again)")
  try await expectUnchanged(book, since: once, after: "the second commit")

  let finalized = finalizeCase.open == 0
  let unanswered = FinalizeAttempt.refused(FinalizeRefusal.unanswered(count: finalizeCase.open).code)
  let named = await book.finalizeDirectly(finalizeCase.chapter)
  try expect(named == (finalized ? .refused(DomainError.draftFinal(finalizeCase.chapter).code) : unanswered), "finalizing the chapter again answered \(named)")
  let lowest = await book.finalizeDirectly(nil)
  try expect(lowest == (finalized ? .refused(DomainError.draftNotFound(nil).code) : unanswered), "finalizing the lowest approved again answered \(lowest)")
  if finalized, let item = finalizeCase.items.first {
    let refusal = await answerRefusal(book, chapter: finalizeCase.chapter, item: item.change.itemKey)
    try expect(refusal == .alreadyApplied, "an answer after the commit refused \(refusal.map(\.code) ?? "nothing"), not FRV_011")
  }
  try await expectUnchanged(book, since: once, after: "finalizing again directly")
  guard let card else { return }

  let replayed = try await book.store.resumeProposalActions(card, novel: book.novel)
  let settled: StoredEnum<ProposalChangeStatus> = finalized ? .known(.applied) : .known(.failed)
  try expect(replayed == [ProposalActionResult(index: 0, outcome: settled)], "replaying the card's action gave \(replayed)")
  try expect(try await book.store.retryPendingActions(card, novel: book.novel).isEmpty, "Try Again left actions pending")
  let swept = await book.store.resumePendingActions()
  try expect(swept.isEmpty, "the launch sweep found \(swept)")
  try await expectUnchanged(book, since: once, after: "replaying the card's action")
}

/// Replica 1 asks twice at once (with the card's own resume racing them); the store runs one commit and the other answers as a second one does.
private func finalizeConcurrently(_ finalizeCase: FinalizeCase, _ book: ChapterBook, card: UUID?) async throws {
  async let one = book.attempt(finalizeCase, card: card)
  async let two = book.attempt(finalizeCase, card: card)
  async let resumed = resume(card, on: book)
  let answers = await [one, two].sorted()
  try await resumed
  let expected = [finalizeCase.first, finalizeCase.again].sorted()
  try expect(answers == expected, "two commits at once answered \(answers), not \(expected)")
}

/// Replica 2 ends inside the commit's transaction, which leaves nothing, and relaunches.
private func finalizeAfterCrash(_ finalizeCase: FinalizeCase, _ book: ChapterBook, card: UUID?) async throws {
  if let card {
    let context = book.context()
    _ = try await book.run { try ProposalApply.apply(proposal: card, selection: .indexes([0]), context: context, in: &$0) }
  }
  let before = try await VaultDump.everything(in: book.store)
  try await book.crashInsideCommit(finalizeCase, card: card)
  try await expectUnchanged(book, since: before, after: "a commit that never committed")
  let resumed = await book.resumeAfterCrash(finalizeCase, card: card)
  try expect(resumed == finalizeCase.first, "the commit after the crash answered \(resumed), not \(finalizeCase.first)")
}

private func expectCommitted(_ finalizeCase: FinalizeCase, _ book: ChapterBook, _ footprint: FinalizeFootprint) async throws {
  let target = NovelJobAddress.target(chapter: finalizeCase.chapter)
  let refreshes = try await book.refreshJobs().filter { $0.request.key.target == target }
  guard finalizeCase.open == 0 else {
    try expect(footprint.canon == nil && refreshes.isEmpty, "a refused commit left a canon or a refresh")
    return
  }
  let record = try #require(try await book.final(finalizeCase.chapter))
  try expect(footprint.digest == record.canonDigest, "the stored canon's digest is not the record's")
  let rebuilt = try FinalChapterRecord(novel: book.novel, chapter: finalizeCase.chapter, canon: record.canon)
  try expect(rebuilt.canonDigest == record.canonDigest, "the canon's digest is not a function of the canon")
  try expect(refreshes.map(\.request.key.fingerprint) == [record.canonDigest], "the commit left refreshes \(refreshes.map(\.request.key))")
  let kept = finalizeCase.kept.count
  try expect(record.canon.review?.kept.count == kept, "the canon kept \(record.canon.review?.kept.count ?? -1) items, not \(kept)")
}

private func expectRebuilt(_ reconciler: NovelForgeReconciler, _ book: ChapterBook, _ which: String) async throws {
  let comparison = try await Projection.compare(reconciler, in: book.store)
  let stale = comparison.incremental.keys.filter { comparison.incremental[$0] != comparison.rebuilt[$0] }.sorted()
  try expect(stale.isEmpty, "\(which): derived tables \(stale) are not a rebuild: \(stale.map { (comparison.incremental[$0] ?? [], comparison.rebuilt[$0] ?? []) })")
}

private func check(_ finalizeCase: FinalizeCase, reconciler: NovelForgeReconciler, generator: inout SeededGenerator) async throws {
  let seed = generator.next()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: replicaCount, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  var books = [ChapterBook]()
  for index in 0..<replicaCount { books.append(ChapterBook(store: await replicas.store(index), clock: OperationClock())) }
  let card = try await books[0].prepare(finalizeCase)
  _ = try await replicas.write(0) { _ in }
  try await replicas.settle()

  for index in 1..<replicaCount { await replicas.advanceClock(of: index, by: .milliseconds(generator.int(in: 0...5_000))) }
  try await labelled("finalizing twice") { try await finalizeTwice(finalizeCase, books[0], card: card) }
  try await labelled("finalizing at once") { try await finalizeConcurrently(finalizeCase, books[1], card: card) }
  try await labelled("finalizing after a crash") { try await finalizeAfterCrash(finalizeCase, books[2], card: card) }

  let footprint = try await FinalizeFootprint.read(books[0], chapter: finalizeCase.chapter)
  try await expectCommitted(finalizeCase, books[0], footprint)
  for (index, book) in books.enumerated() {
    try await expectRebuilt(reconciler, book, "replica \(index) before syncing")
    guard index > 0 else { continue }
    let other = try await FinalizeFootprint.read(book, chapter: finalizeCase.chapter)
    try expect(other == footprint, "replica \(index) committed other values than replica 0: \(other.difference(from: footprint))")
  }

  for index in 0..<replicaCount { _ = try await replicas.write(index) { _ in } }
  try await replicas.settle()
  let derived = try await Projection.derived(reconciler, in: books[0].store)
  for (index, book) in books.enumerated() {
    try await Projection.expectNoFaults(in: book.store)
    let synced = try await FinalizeFootprint.read(book, chapter: finalizeCase.chapter)
    let (one, held) = finalizeCase.createsEntity ? (footprint.recorded, synced.recorded) : (footprint, synced)
    try expect(held == one, "replica \(index) after syncing holds other values than one commit: \(held.difference(from: one))")
    try await expectCommitted(finalizeCase, book, synced)
    try await expectRebuilt(reconciler, book, "replica \(index) after syncing")
    try expect(try await Projection.derived(reconciler, in: book.store) == derived, "replica \(index)'s derived tables are not replica 0's")
  }
}

/// Decisions 2-4: whichever way the commit is asked for again, at once, on two devices, from the card again or after a crash inside it, the canon, its review,
/// its knowledge, the records beside it and what is derived from them are those of one commit (chapter-finalization.graph.ts:127-207, generation.service.ts:583-640).
@Suite("Finalizing twice writes the same values", TestTimeLimit.property)
struct FinalizeIdempotencePropertyTests {
  @Test func shouldWriteTheValuesOfOneCommitHoweverTheCommitIsRepeated() async throws {
    let reconciler = try Projection.reconciler()
    try await forAllConcurrently(iterations: ProjectionProperty.iterations(full: 24), seed: 0x635_F1, width: 4) { generator in
      let finalizeCase = FinalizeCase.generate(&generator)
      do {
        try await check(finalizeCase, reconciler: reconciler, generator: &generator)
      } catch {
        throw IdempotenceFailure(description: "\(finalizeCase): \(error)")
      }
    }
  }

  @Test func shouldGenerateEveryDimensionTheCommitVaries() throws {
    var generator = SeededGenerator(seed: 0x635_F1)
    let cases = (0..<ProjectionProperty.iterations(full: 24)).map { _ in FinalizeCase.generate(&generator) }
    let answers = cases.flatMap(\.items).map(\.answer)
    #expect(answers.contains(.kept) && answers.contains(.skipped) && answers.contains(.automatic))
    #expect(answers.contains { if case .edited = $0 { true } else { false } })
    #expect(cases.contains { $0.open > 0 } && cases.contains { $0.open == 0 })
    #expect(Set(cases.map(\.path)) == Set(FinalizeRepeatPath.allCases))
    #expect(Set(cases.map(\.isolated)) == [true, false] && Set(cases.map(\.chapter)) == [1, 2])
    #expect(cases.contains { !$0.learns.isEmpty } && cases.contains { !$0.claims.isEmpty })
    #expect(cases.flatMap(\.items).contains { $0.change.category == .entity && $0.change.itemKey != Kept.entity("mara").itemKey })
    #expect(cases.flatMap(\.items).contains { $0.change.category == .knowledge })
    #expect(cases.flatMap(\.items).contains { $0.change.category == .milestone && $0.answer == .skipped })
  }
}
