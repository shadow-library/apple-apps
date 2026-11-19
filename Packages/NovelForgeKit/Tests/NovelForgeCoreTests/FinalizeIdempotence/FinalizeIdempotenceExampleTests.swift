import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let kael = Kept.entity("kael")
private let seen = Kept.appearance("kael")

/// Chapter 1 teaching mara heir and claiming rise, its review keeping the new entity kael on its own and the author answering the rest.
private func reviewed(_ path: FinalizePath) -> FinalizeCase {
  FinalizeCase(
    chapter: 1, isolated: false, path: path, learns: [reveal("mara", "heir")], claims: ["rise"], autoKeep: [.appearance],
    items: [
      CaseItem(change: kael, triage: .consequential, autoKept: false, answer: .kept),
      CaseItem(change: seen, triage: .routine, autoKept: true, answer: .automatic),
      CaseItem(change: Kept.state("mara", location: "the tower"), triage: .routine, autoKept: false, answer: .edited(["location": "the sea"])),
      CaseItem(change: Kept.knowledge("kael", "heir"), triage: .consequential, autoKept: false, answer: .kept),
      CaseItem(change: Kept.milestone("rise"), triage: .consequential, autoKept: false, answer: .kept),
    ])
}

private func vaultURL() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "finalize-\(UUID().uuidString)").appending(path: "vault.sqlite")
}

@Suite("Finalizing again, by example", TestTimeLimit.standard)
struct FinalizeIdempotenceExampleTests {
  // A process ended inside the commit's transaction leaves the file as the last committed transaction left it; the relaunch commits once
  @Test(arguments: [FinalizePath.named, .card])
  func shouldCommitOnceWhenTheAppRelaunchesAfterEndingInsideTheCommit(_ path: FinalizePath) async throws {
    let url = vaultURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let clock = OperationClock()
    let finalizeCase = reviewed(path)
    let book = ChapterBook(store: try NovelForgeStore.open(at: url, wallClock: clock.function), clock: clock)
    let card = try await book.prepare(finalizeCase)
    if let card {
      let context = book.context()
      _ = try await book.run { try ProposalApply.apply(proposal: card, selection: .indexes([0]), context: context, in: &$0) }
    }
    let before = try await VaultDump.everything(in: book.store)
    try await book.crashInsideCommit(finalizeCase, card: card)

    let relaunched = ChapterBook(store: try NovelForgeStore.open(at: url, wallClock: clock.function), clock: clock)
    #expect(try await VaultDump.everything(in: relaunched.store) == before)
    #expect(await relaunched.resumeAfterCrash(finalizeCase, card: card) == .finalized(1))
    let once = try await VaultDump.everything(in: relaunched.store)
    #expect(await relaunched.attempt(finalizeCase, card: card) == finalizeCase.again)
    #expect(await relaunched.finalizeDirectly(1) == .refused(DomainError.draftFinal(1).code))
    #expect(try await VaultDump.everything(in: relaunched.store) == once)

    let canon = try #require(try await relaunched.final(1)?.canon)
    #expect(canon.review?.kept == [kael, seen, Kept.state("mara", location: "the sea"), Kept.knowledge("kael", "heir"), Kept.milestone("rise")].compactMap(\.json.objectValue))
    #expect(canon.knowledge == [reveal("mara", "heir")])
    #expect(try await relaunched.refreshJobs().count == 1)
    #expect(try await CanonTables.appearances(relaunched.novel, in: relaunched.store) == ["kael@1"])
    let reconciler = try Projection.reconciler()
    let comparison = try await Projection.compare(reconciler, in: relaunched.store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  // hub-action.registrar.ts:96-100 through finalize-refusals.ts:13: a new card's finalize of a final chapter refuses DRF_002 and writes only the card's records
  @Test func shouldRefuseANewCardsFinalizeOfAFinalChapterAndWriteOnlyTheCard() async throws {
    let reconciler = try Projection.reconciler()
    let clock = OperationClock()
    let store = try VaultStore.open(.inMemory, registry: Projection.registry, migrations: reconciler.migrations, wallClock: clock.function, reconciler: reconciler)
    let book = ChapterBook(store: store, clock: clock)
    let finalizeCase = reviewed(.card)
    let card = try await book.prepare(finalizeCase)
    #expect(await book.accept(card, chapter: 1) == .finalized(1))
    let once = try await FinalizeFootprint.read(book, chapter: 1)
    let again = try await book.stage(#"{"op":"action.finalize","upTo":1}"#).proposal.id
    #expect(await book.accept(again, chapter: 1) == .refused(DomainError.draftFinal(1).code))
    let after = try await FinalizeFootprint.read(book, chapter: 1)
    let proposals = [NovelForgeKind.proposal, .proposalChange].map { "kind=\"\($0.rawValue)\"" }
    let cards = { (footprint: FinalizeFootprint) in footprint.values.filter { line in !proposals.contains { line.hasPrefix($0) } } }
    #expect(after.canon == once.canon && after.jobs == once.jobs && after.derived == once.derived)
    #expect(cards(after) == cards(once))
  }

  // finalize-review.service.ts:452-467: the review approval settled finalizes once; the author, the job run again and a launch find the chapter final
  @Test func shouldLeaveWhatApprovalCommittedWhenTheAuthorTheJobAndALaunchAskAgain() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.confident)])
    let engine = try world.engine(finalizing: FinalizeReviewPipeline.commit)
    let job = try await world.prepared(on: engine, autoKeep: [.appearance, .characterState])
    let (store, novel) = (world.store, world.novel)
    let canon = try #require(try await store.read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record.canon })
    #expect(canon.review?.kept.count == 2)
    let once = try await VaultDump.everything(in: store)

    await #expect(throws: DomainError.draftFinal(1)) { try await store.finalizeChapter(novel: novel, chapter: 1) }
    await #expect(throws: JobEngineError.self) { _ = try await engine.run(job: job) }
    #expect(try await engine.resumeInterruptedAttempts().isEmpty)
    #expect(try await VaultDump.everything(in: store) == once)
    #expect(try await FinalizeReviews.refreshJobs(in: store).count == 1)
  }

  // G27 x G26 across devices: each device that finalizes creates the kept entity, so its `removed` register ends at the latest create while the canon keeps
  // the earliest write; CanonCharacters then reads the entity as created after the canon and drops what the canon keeps of it
  @Test(.disabled("BUG: two devices finalizing one reviewed chapter lose the kept new entity's appearance, states and relationships once they sync"))
  func shouldKeepTheNewEntitysAppearanceWhenTwoDevicesFinalizeTheSameState() async throws {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0x635_B1))
    let here = ChapterBook(store: await replicas.store(0), clock: OperationClock())
    let there = ChapterBook(store: await replicas.store(1), clock: OperationClock())
    _ = try await here.prepare(reviewed(.named))
    _ = try await replicas.write(0) { _ in }
    try await replicas.settle()
    #expect(await here.finalizeDirectly(1) == .finalized(1))
    await replicas.advanceClock(of: 1, by: .seconds(5))
    #expect(await there.finalizeDirectly(1) == .finalized(1))
    for book in [here, there] { #expect(try await CanonTables.appearances(book.novel, in: book.store) == ["kael@1"]) }
    _ = try await replicas.write(0) { _ in }
    _ = try await replicas.write(1) { _ in }
    try await replicas.settle()
    for book in [here, there] { #expect(try await CanonTables.appearances(book.novel, in: book.store) == ["kael@1"]) }
  }
}
