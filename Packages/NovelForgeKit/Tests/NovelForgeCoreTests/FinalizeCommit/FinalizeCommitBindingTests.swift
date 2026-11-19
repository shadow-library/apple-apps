import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

private let kael = Kept.entity("kael")
private let renamed = Kept.entity("mara", name: "Mara Renamed")
private let seen = Kept.appearance("kael")
private let learned = Kept.knowledge("mara", "heir")
private let rivals = Kept.relationship("mara", "kael", "rival")
private let reached = Kept.milestone("rise")
private let tower = Kept.state("mara", location: "the tower")

/// A read of chapter 1 whose items the author answered: the new entity and its appearance kept on their own, the rest kept, edited or skipped by the author.
private func answeredRead(_ book: ChapterBook, claims: [String]? = nil) async throws {
  try await book.plan(1, learns: [], claims: claims)
  try await book.draft(1)
  try await book.approve(1)
  let items = [
    ReviewItems.item(kael, position: 0, autoKept: true), ReviewItems.item(renamed, position: 1), ReviewItems.item(seen, position: 2, autoKept: true),
    ReviewItems.item(learned, triage: .consequential, position: 3), ReviewItems.item(rivals, position: 4), ReviewItems.item(reached, position: 5),
    ReviewItems.item(tower, position: 6),
  ]
  try await book.reviewRead(1, items: items)
  try await book.answer(1, item: renamed.itemKey, .kept)
  try await book.answer(1, item: learned.itemKey, .kept)
  try await book.answer(1, item: rivals.itemKey, .skipped, reason: "Not yet.")
  try await book.answer(1, item: reached.itemKey, .kept)
  try await book.answer(1, item: tower.itemKey, .edited, edit: ["location": "the sea"])
}

/// finalize-review-gate.ts:143-181 and review-event-apply.ts:190-226 as decision 3 reads them: the canon records the kept changes, G27 derives what they change.
@Suite("Finalize commit review binding", TestTimeLimit.standard)
struct FinalizeCommitBindingTests {
  @Test func shouldBindEveryKeptChangeInTheReviewsOrderAndCreateOnlyTheNewEntity() async throws {
    let book = try await ChapterBook.make()
    try await answeredRead(book)
    try await book.run(book.commit(1))
    let review = try #require(try await book.final(1)?.canon.review)
    let edited = Kept.state("mara", location: "the sea")
    #expect(review.kept == [kael, renamed, seen, learned, reached, edited].compactMap(\.json.objectValue))
    #expect(review.unreached.isEmpty)
    #expect(review.id == (try await book.reads(1).first?.id))
    let created = try #require(try await book.entity("kael"))
    #expect(created.name == "Kael" && created.origin == .known(.generated) && created.type == .known(.character))
    #expect(try await book.entity("mara")?.name == "Mara")
  }

  // G27 end to end: the winning canon's kept items are what the canon-derived tables show
  @Test func shouldShowTheKeptItemsInTheCanonDerivedTablesOnceTheCommitLands() async throws {
    let book = try await ChapterBook.make()
    try await answeredRead(book)
    let novel = book.novel
    #expect(try await CanonTables.appearances(novel, in: book.store).isEmpty)
    try await book.run(book.commit(1))
    #expect(try await CanonTables.appearances(novel, in: book.store).isSuperset(of: ["kael@1"]))
    #expect(try await CanonTables.states(novel, in: book.store).contains(StateView("mara", location: "the sea", chapter: 1)))
    #expect(try await CanonTables.relationships(novel, in: book.store).isEmpty)
    #expect(try await ChapterTables.knowledge(novel, in: book.store) == [LedgerView("heir", "mara", 1, .generated, .committed)])
    #expect(try await PlanWorldTables.milestones(novel, in: book.store)["rise"]?.reached == 1)
    let comparison = try await Projection.compare(try Projection.reconciler(chapterAreaDerivations), in: book.store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  // finalize-review-gate.ts:161-166: a claim the answers leave unreached is recorded so it never counts as reached
  @Test func shouldRecordAClaimTheAnswersLeaveUnreached() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1, claims: ["rise"])
    try await book.draft(1)
    try await book.approve(1)
    let missed = Kept.milestone("rise", reached: false)
    try await book.reviewRead(1, items: [ReviewItems.item(missed)])
    try await book.answer(1, item: missed.itemKey, .kept)
    try await book.run(book.commit(1))
    #expect(try await book.final(1)?.canon.review?.unreached == ["rise"])
    #expect(try await PlanWorldTables.milestones(book.novel, in: book.store)["rise"]?.reached == nil)
  }

  // generation.service.ts:583-602: a final chapter queues its canon refresh once, keyed by the canon it refreshes (decision 8)
  @Test func shouldRequestExactlyOneCanonRefreshPerCommit() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.approve(1)
    try await book.reviewRead(1)
    #expect(try await book.refreshJobs().isEmpty)
    try await book.run(book.commit(1))
    let digest = try #require(try await book.final(1)).canonDigest
    let jobs = try await book.refreshJobs()
    #expect(jobs.count == 1)
    let key = try #require(jobs.first?.request.key)
    #expect(key.target == NovelJobAddress.target(chapter: 1) && key.fingerprint == digest && key.run == 1)
    let review = try #require(try await book.final(1)?.canon.review)
    #expect(
      jobs.first?.request.payload == [
        "chapter": 1, "canon": .string(digest), "review": .string(review.id.lowercasedString), "kept": .string(CanonRefreshReview.fingerprint(of: review.kept)),
      ])
    #expect(jobs.first?.request.origin == .null)
  }

  @Test func shouldRefuseAFinalizeReviewOfTheChapterThisVersionCannotRead() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1)
    try await book.approve(1)
    try await book.reviewRead(1)
    let unreadable = FinalizeReviewRecord.ref(attempt: try ReviewWrites.attempt(41))
    try await book.run { transaction in _ = try transaction.append(unreadable, item: ["novel": novel.json, "chapter": .int(1), "items": .string("newer")]) }
    await book.expect(.unreadable(unreadable), book.commit(1))
    #expect(try await book.final(1) == nil)
  }

  @Test func shouldRefuseAnAnswerOfTheChainThisVersionCannotRead() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let head = try await book.draft(1)
    try await book.approve(1)
    try await book.reviewRead(1, items: [ReviewItems.item(seen, autoKept: true)])
    let kept = StoredFinalizeAnswer(decision: .known(.kept), proposalDigest: "d")
    let answer = try FinalizeDecisionRecord(novel: novel, chapter: 1, draftRevision: head, item: seen.itemKey, answer: kept)
    try await book.run { transaction in
      _ = try answer.create(in: &transaction)
      _ = try transaction.set(answer.ref, [FinalizeDecisionField.decision.rawValue: .string("from a newer version")])
    }
    let ref = answer.ref
    await book.expect(.unreadable(ref), book.commit(1))
  }

  // G21: readiness shows an entry fault and lets it pass; the commit refuses it
  @Test func shouldRefuseAFaultedEntryThatReadinessLetsPass() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1)
    try await book.approve(1)
    try await book.reviewRead(1)
    let judge = UUID()
    try await book.run { transaction in _ = try ReviewWrites.judge(novel: novel, chapter: 1, findings: [], verdict: "pass", id: judge, in: &transaction) }
    let key = ProjectionFaults.key(ChapterReviewRecord.ref(judge))
    try await book.tamper("INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES ('\(ChapterReviewEntry.databaseTableName)', '\(key)', 1, 'x')")
    let readiness = try await book.store.load(FinalizeReadiness.self, FinalizeReadinessQuery(novel: novel, chapter: 1))
    #expect(readiness.isReady && readiness.faults.map(\.scope) == [.entry])
    await book.expect(.lifecycleUnavailable(1), book.commit(1))
  }

  // Decision 2: the author's finalize with no read of the head refuses FRV_002 and asks for the read
  @Test func shouldRequestTheMissingReviewWhenTheAuthorFinalizes() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1)
    try await book.run { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await book.store.finalizeReviewJob(novel: novel, chapter: 1) == nil)
    await #expect(throws: DomainError.finalizeRefused(.reviewPreparing(chapter: 1))) { try await book.store.finalizeChapter(novel: novel, chapter: 1) }
    #expect(try await book.store.finalizeReviewJob(novel: novel, chapter: 1) != nil)
    try await book.reviewRead(1)
    #expect(try await book.store.finalizeChapter(novel: novel) == 1)
  }
}

/// hub-action.registrar.ts:96-100: the chat card's finalize takes the same gate and queues the refresh with the card as its origin (action-jobs.ts:27-30).
@Suite("Finalize from a chat card", TestTimeLimit.standard)
struct FinalizeCardActionTests {
  @Test func shouldRefuseTheCardsFinalizeUntilTheReviewIsReadAndThenFinalizeWithTheCardAsOrigin() async throws {
    let book = try await StagingWorld.workspace()
    try await book.approve(3)
    let refused = try await book.stage(ApplyWorld.finalize3).proposal.id
    let failure = try #require(try await book.applied(refused, .indexes([0])).first?.failure)
    #expect(failure == ProposalChangeFailure(.domain(.finalizeRefused(.reviewPreparing(chapter: 3)))))
    #expect(try await book.final(3) == nil)

    try await book.reviewRead(3)
    let id = try await book.stage(ApplyWorld.finalize3).proposal.id
    #expect(try await book.applied(id, .indexes([0])).first?.status == .applied)
    #expect(try await book.final(3) != nil)
    let origin = try #require(try await book.refreshJobs().first { $0.request.key.target == NovelJobAddress.target(chapter: 3) }?.request.origin)
    #expect(origin[NovelJobOriginMember.proposal.rawValue]?.stringValue == id.lowercasedString && origin[NovelJobOriginMember.opIndex.rawValue] == 0)
    #expect(origin[NovelJobOriginMember.session.rawValue]?.stringValue == StagingWorld.session.lowercasedString)
  }
}

private let novel = SchemaFixture.novel

private func committingReplicas(seed: UInt64) async throws -> CausalReplicas {
  let reconciler = try Projection.reconciler(chapterAreaDerivations)
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  _ = try await replicas.write(0) { transaction in
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
  }
  _ = try await replicas.write(0) { try ChapterPlans.write(novel: novel, chapter: 1, ChapterBook.planEdit(), in: &$0) }
  let now = await replicas.store(0).wallClock()
  _ = try await replicas.write(0) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "One.", summary: "Once."), base: nil, at: now, in: &$0) }
  let requester = await replicas.store(0).replica
  _ = try await replicas.write(0) { transaction in
    let head = try #require(try ChapterWrites.head(novel: novel, chapter: 1, in: transaction))
    try ChapterApprovals.approve(novel: novel, chapter: 1, revision: head, requester: requester, in: &transaction)
    try FinalizeReviews.ready(novel: novel, chapter: 1, items: [ReviewItems.item(kael)], in: &transaction)
  }
  try await replicas.settle()
  return replicas
}

@Suite("Finalize commit across replicas", TestTimeLimit.standard)
struct FinalizeCommitReplicaTests {
  // Decision 3: two devices finalize the same chapter with different answers; the first canon stands on every device and the derived tables follow it
  @Test func shouldConvergeOnTheFirstCanonWhenTwoDevicesCommitTheSameChapter() async throws {
    let replicas = try await committingReplicas(seed: 0xD260)
    let answer = { (decision: FinalizeDecision, reason: String?) in
      { @Sendable (transaction: inout WriteTransaction) throws in
        _ = try FinalizeReviewDecisions.decide(novel: novel, chapter: 1, item: kael.itemKey, decision: decision, reason: reason, in: &transaction)
        _ = try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &transaction)
      }
    }
    _ = try await replicas.write(1, answer(.kept, nil))
    await replicas.advanceClock(of: 2, by: .seconds(5))
    _ = try await replicas.write(2, answer(.skipped, "Not him."))
    try await replicas.settle()
    var digests = Set<String>()
    for index in 0..<replicas.count {
      let store = await replicas.store(index)
      let canon = try await store.read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record }
      digests.insert(try #require(canon).canonDigest)
      #expect(canon?.canon.review?.kept == [kael.json.objectValue].compactMap { $0 })
      #expect(try await CanonTables.appearances(novel, in: store).contains("kael@1"))
      #expect(try await FinalizeReviews.refreshJobs(in: store).count == 2)
    }
    #expect(digests.count == 1)
  }
}

/// The finalize_review job settling into the commit (finalize-review.service.ts:452-467), killed at every runner boundary and resumed.
@Suite("Finalize commit from the review pipeline", TestTimeLimit.standard)
struct FinalizeCommitPipelineTests {
  @Test(arguments: FinalizeReviewCrashTests.points)
  func shouldFinalizeExactlyOnceWhenTheSettlingReviewIsKilledAndResumed(_ point: AttemptRunner.Faults.Point) async throws {
    let reply = FinalizeReviewScript.reply(FinalizeReviewScript.confident)
    let world = try await FinalizeReviewWorld(replies: [reply, reply])
    try await world.draft()
    let job = try await world.approve()
    let killed = try world.engine(finalizing: FinalizeReviewPipeline.commit, faults: .once(at: point))
    #expect(await (try killed.run(job: job)).result == .interrupted)
    killed.relinquish()
    world.base.clock.advance(5)
    let relaunched = try world.engine(finalizing: FinalizeReviewPipeline.commit)
    for run in try await relaunched.resumeInterruptedAttempts() { #expect(await run.result == .settled(.succeeded)) }
    let novel = world.novel
    let canon = try await world.store.read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record.canon }
    #expect(canon?.review?.id == (try await world.reviews().first?.record.id))
    #expect(try await FinalizeReviews.refreshJobs(in: world.store).count == 1)
  }

  // Decision 12: approval never finalizes an isolated chapter, whatever its review asks
  @Test func shouldNeverFinalizeAnIsolatedChapterOnItsOwn() async throws {
    var nothing = FinalizeReviewScript.replacing(FinalizeReviewScript.confident, "appeared", with: [])
    nothing = FinalizeReviewScript.replacing(nothing, "characterStates", with: [])
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.replacing(nothing, "chapterSummary", with: " "))])
    try await world.prepared(on: try world.engine(finalizing: FinalizeReviewPipeline.commit, unrestrictedAvailable: true), isolated: true)
    let novel = world.novel
    #expect(try await !world.store.writeDomain { transaction throws(DomainError) in try transaction.isFinal(novel: novel, chapter: 1) })
    #expect(try await FinalizeReviews.refreshJobs(in: world.store).isEmpty)
  }
}
