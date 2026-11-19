import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Finalize review screen", TestTimeLimit.standard)
struct FinalizeReviewScreenTests {
  static let secret = "SECRETPROSE"

  @Test func shouldShowTheHeadsReadWithTheAnswersAndWhatCarriedOverFromAnEarlierRevision() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(), FinalizeReviewScript.reply()])
    let engine = try world.engine()
    try await world.prepared(on: engine)
    try await world.store.decideFinalizeItem(novel: world.novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .skipped, reason: "not paid yet")
    let revision = try await world.draft("\(FinalizeReviewScript.prose) She pauses.")
    #expect(try await world.run(engine, try await world.approve()) == .settled(.succeeded))

    let review = try #require(try await screen(world).ready)
    #expect(review.revision == revision && !review.isolated)
    let payoff = try #require(review.items.first { $0.key == "promise:thread:lamp_debt" })
    #expect(payoff.decision == .skipped && payoff.reason == "not paid yet" && payoff.carriedOver && !payoff.reopened && payoff.triage == .consequential)
    let state = try #require(review.items.first { $0.key == "character_state:mira" })
    #expect(state.decision == .kept && state.autoKept && !state.carriedOver && state.evidence == "Mira climbs the tower")
  }

  @Test func shouldReopenAnAnsweredItemWhoseProposalALaterReadOfTheSameTextChanged() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(), autoKeep: [])
    try await world.store.decideFinalizeItem(novel: world.novel, chapter: 1, item: "character_state:mira", decision: .kept)
    let first = try #require(try await world.reviews().first?.record)
    #expect(try await screen(world).ready?.items.first { $0.key == "character_state:mira" }?.decision == .kept)

    try await append(world, job: job, from: first, isolated: false, run: 2)
    let state = try #require(try await screen(world).ready?.items.first { $0.key == "character_state:mira" })
    #expect(state.decision == nil && state.reopened && !state.carriedOver)
  }

  @Test func shouldTellWhyNoReadOfTheHeadIsReady() async throws {
    let world = try await FinalizeReviewWorld(replies: [[.failure(.server(status: 500))], [.failure(.server(status: 500))]])
    #expect(try await screen(world).state == .noDraft)
    let head = try await world.draft()
    #expect(try await screen(world).state == .unreviewed)
    let job = try await world.approve()
    #expect(try await screen(world).state == .preparing(revision: head))
    #expect(try await world.run(try world.engine(), job) != .settled(.succeeded))
    guard case .failed(let revision, let failure) = try await screen(world).state else { throw EngineFixtureError(description: "not failed") }
    #expect(revision == head && failure?.code == "model.server")
  }

  @Test func shouldNameTheReadTheProseMovedPast() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine())
    let read = try await world.head()
    try await world.draft("\(FinalizeReviewScript.prose) Edited.")
    #expect(try await screen(world).state == .invalidated(read: read))
  }

  @Test func shouldWithholdEveryExcerptOfAnIsolatedChaptersRead() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(unrestrictedAvailable: true), isolated: true)
    let loaded = try await screen(world)
    let review = try #require(loaded.ready)
    #expect(review.isolated && loaded.isolated)
    let state = try #require(review.items.first { $0.key == "character_state:mira" })
    #expect(state.evidence == FinalizeReviewItem.withheldEvidence && state.proposed["state"]?["evidence"] == .string(FinalizeReviewItem.withheldEvidence))
    #expect(!String(describing: review.items).contains("Mira climbs the tower"))
  }

  // FinalizeReviewScreen.load reads a standard head's read as withheld when the read itself was made isolated.
  @Test func shouldWithholdAnIsolatedReadOfAStandardHead() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(), autoKeep: [])
    let first = try #require(try await world.reviews().first?.record)
    try await append(world, job: job, from: first, isolated: true, run: 2)
    let loaded = try await screen(world)
    let review = try #require(loaded.ready)
    #expect(!loaded.isolated && review.isolated && review.items.contains { $0.claim == "probe" })
    #expect(!String(describing: loaded).contains(Self.secret))
  }

  @Test func shouldWithholdAnIsolatedReadOfAnIsolatedHead() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(unrestrictedAvailable: true), autoKeep: [], isolated: true)
    let first = try #require(try await world.reviews().first?.record)
    try await append(world, job: job, from: first, isolated: true, run: 2)
    let loaded = try await screen(world)
    #expect(loaded.ready?.items.contains { $0.claim == "probe" } == true && !String(describing: loaded).contains(Self.secret))
  }

  @Test func shouldWithholdTheReadOfAStandardReviewOnceTheHeadIsIsolated() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(unrestrictedAvailable: true), autoKeep: [], isolated: true)
    let first = try #require(try await world.reviews().first?.record)
    try await append(world, job: job, from: first, isolated: false, run: 2)
    let loaded = try await screen(world)
    #expect(loaded.ready?.items.contains { $0.claim == "probe" } == true && !String(describing: loaded).contains(Self.secret))
  }

  /// B finalized revision 1 while A, which won, finalized revision 2: the notice names B's review exactly, whatever later reads say.
  @Test func shouldListExactlyWhatTheLosingFinalizeKeptFromItsOwnRevision() async throws {
    let reworded = FinalizeReviewScript.replacing(
      FinalizeReviewScript.extraction, "threads", with: [["threadKey": "lamp_debt", "status": "closed", "summary": "The keeper is repaid at last"]])
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(), FinalizeReviewScript.reply(reworded)])
    let engine = try world.engine()
    try await world.prepared(on: engine, autoKeep: [])
    let (store, novel) = (world.store, world.novel)
    try await keepEverything(world)
    let losing = try #require(try await world.reviews().first?.record)
    try await world.draft("\(FinalizeReviewScript.prose) She pauses.")
    let job = try await world.approve()
    #expect(try await world.run(engine, job) == .settled(.succeeded))
    try await keepEverything(world)
    try await store.finalizeChapter(novel: novel, chapter: 1)
    let winning = try #require(try await world.reviews().last?.record)
    #expect(try await screen(world).applied?.otherSets.isEmpty == true)

    try await append(world, job: job, from: winning, isolated: false, run: 2)
    #expect(try await screen(world).applied?.otherSets.isEmpty == true)

    try await lose(world, naming: losing.id, kept: losing.items.map(\.proposed))
    let applied = try #require(try await screen(world).applied)
    #expect(applied.review?.id == winning.id && applied.otherSets.count == 1)
    let other = try #require(applied.otherSets.first)
    #expect(other.exact && other.updates?.map(\.claim) == losing.items.map(\.claim))
    #expect(other.updates?.contains { $0.claim == "Paid off: Mira repays the keeper" } == true && other.updates?.contains { $0.claim == "probe" } == false)
    #expect(applied.kept.contains { $0.claim == "Paid off: The keeper is repaid at last" })
  }

  @Test func shouldListNothingWhenTheLosingFinalizeKeptWhatTheCanonKept() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(), autoKeep: [])
    try await keepEverything(world)
    try await world.store.finalizeChapter(novel: world.novel, chapter: 1)
    let read = try #require(try await world.reviews().first?.record)
    try await lose(world, naming: read.id, kept: read.items.map(\.proposed))
    #expect(try await screen(world).applied?.otherSets.isEmpty == true)
  }

  @Test func shouldListAnUnknownSetWhenTheLosingFinalizeNamedNoReviewThisDeviceCanRead() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(), autoKeep: [])
    try await keepEverything(world)
    try await world.store.finalizeChapter(novel: world.novel, chapter: 1)
    try await lose(world, naming: UUID(), kept: [])
    let other = try #require(try await screen(world).applied?.otherSets.first)
    #expect(other.updates == nil && !other.exact)
  }

  @Test func shouldMarkTheOtherSetInexactOnceItsAnswersChanged() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(), autoKeep: [])
    let first = try #require(try await world.reviews().first?.record)
    try await keepEverything(world)
    try await world.store.finalizeChapter(novel: world.novel, chapter: 1)
    try await append(world, job: job, from: first, isolated: false, run: 2)
    let duplicate = try #require(try await world.reviews().last?.record)
    try await lose(world, naming: duplicate.id, kept: duplicate.items.map(\.proposed))
    let other = try #require(try await screen(world).applied?.otherSets.first)
    #expect(!other.exact && other.updates?.contains { $0.claim == "probe" } == false)
  }

  @Test func shouldWithholdAnIsolatedLosingReadInTheOtherSets() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(), autoKeep: [])
    let first = try #require(try await world.reviews().first?.record)
    try await keepEverything(world)
    try await world.store.finalizeChapter(novel: world.novel, chapter: 1)
    try await append(world, job: job, from: first, isolated: true, run: 2, autoKeep: true)
    let duplicate = try #require(try await world.reviews().last?.record)
    try await lose(world, naming: duplicate.id, kept: duplicate.items.map(\.proposed))
    let loaded = try await screen(world)
    #expect(loaded.applied?.otherSets.first?.updates?.contains { $0.claim == "probe" } == true)
    #expect(!String(describing: loaded).contains(Self.secret))
  }

  @Test(arguments: SyncOrder.allCases)
  func shouldListTheLosingDevicesSetAfterBothDevicesFinalized(order: SyncOrder) async throws {
    let pair = try await ChapterReplicas.make(seed: 0x41C0 + (order == .firstToSecond ? 0 : 1))
    try await pair.prepare(for: .finalizeReview)
    let first = try #require(try await ChapterStage.finalizeReview.start(on: pair[0], calls: ChapterStage.finalizeReview.calls()).handle)
    #expect(await first.result == .settled(.succeeded))
    let second = try #require(try await ChapterStage.finalizeReview.start(on: pair[1], calls: ChapterStage.finalizeReview.calls(variant: 1)).handle)
    #expect(await second.result == .settled(.succeeded))
    try await pair.sync(order)
    try await pair.expectConverged()
    for device in pair.devices {
      let screen = try await device.store.load(FinalizeReviewScreen.self, FinalizeReviewScreenQuery(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter))
      let applied = try #require(screen.applied)
      #expect(applied.otherSets.count == 1 && applied.otherSets.first?.exact == true)
      #expect(String(describing: applied.otherSets).contains("the lamp room") && !String(describing: applied.kept).contains("the lamp room"))
    }
  }

  @Test func shouldListTheReadTheLosingFinalizeNamedEvenWithAnotherReadBeforeIt() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(), autoKeep: [])
    let first = try #require(try await world.reviews().first?.record)
    try await keepEverything(world)
    try await world.store.finalizeChapter(novel: world.novel, chapter: 1)
    try await append(world, job: job, from: first, isolated: false, run: 2, autoKeep: true, claim: "decoy")
    try await append(world, job: job, from: first, isolated: false, run: 3, autoKeep: true, claim: "named")
    let named = try #require(try await world.reviews().last?.record)
    try await lose(world, naming: named.id, kept: named.items.map(\.proposed))
    let other = try #require(try await screen(world).applied?.otherSets.first)
    #expect(other.updates?.contains { $0.claim == "named" } == true && other.updates?.contains { $0.claim == "decoy" } == false)
  }

  @Test func shouldBeUnavailableWhileAReadOfTheChapterCannotBeRead() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(), autoKeep: [])
    let novel = world.novel
    try await Projection.write(world.store) { transaction in
      _ = try transaction.append(FinalizeReviewRecord.ref(UUID()), item: ["novel": novel.json, "chapter": .int(1), "items": .int(3)])
    }
    #expect(try await screen(world).state == .unavailable(.unreadable))
  }

  @Test func shouldBeUnavailableWhileAReadJobsInputCannotBeRead() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.draft()
    let (novel, replica) = (world.novel, world.store.replica)
    #expect(try await screen(world).state == .unreviewed)
    try await Projection.write(world.store) { transaction in
      let key = try JobKey(
        scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.finalizeReview.rawValue, target: NovelJobAddress.target(chapter: 1), fingerprint: "unreadable",
        run: 1)
      _ = try JobRecords.request(JobRequest(key: key, payload: "a later version's input", replica: replica), in: &transaction)
    }
    #expect(try await screen(world).state == .unavailable(.unreadable))
  }

  private func screen(_ world: FinalizeReviewWorld) async throws -> FinalizeReviewScreen {
    try await world.store.load(FinalizeReviewScreen.self, FinalizeReviewScreenQuery(novel: world.novel, chapter: 1))
  }

  private func keepEverything(_ world: FinalizeReviewWorld) async throws {
    try await world.store.decideFinalizeItem(novel: world.novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .kept)
    try await world.store.keepRoutineFinalizeItems(novel: world.novel, chapter: 1)
  }

  /// The refresh request another device's finalize left when its canon lost, naming the review it applied and what that kept.
  private func lose(_ world: FinalizeReviewWorld, naming review: UUID, kept: [[String: JSONValue]]) async throws {
    let (store, novel, replica) = (world.store, world.novel, world.store.replica)
    let named = CanonRefreshReview(id: review, kept: CanonRefreshReview.fingerprint(of: kept))
    try await store.writeDomain { transaction throws(DomainError) in
      try CanonRefreshJobs.request(novel: novel, chapter: 1, canonDigest: "another-device-canon", review: named, requester: replica, in: &transaction)
    }
  }

  /// A later run's read of the same text, appended as another device's attempt would, with mira's state moved and one more update whose excerpt is secret.
  private func append(
    _ world: FinalizeReviewWorld, job: EntityRef, from first: FinalizeReviewRecord, isolated: Bool, run: Int, autoKeep: Bool = false, claim: String = "probe"
  ) async throws {
    let input = FinalizeReviewJobInput(revision: first.draftRevision, sourceHash: first.sourceHash, plan: first.planHash)
    let novel = world.novel
    let rerun = try await world.store.writeDomain { transaction throws(DomainError) in try FinalizeReviewJobs.key(input, novel: novel, chapter: 1, run: run) }
    #expect(job != rerun.ref)
    var items = first.items.map { item -> StoredFinalizeItem in
      guard item.key == "character_state:mira" else { return item }
      var moved = item
      moved.proposed["state"] = ["entityKey": "mira", "location": "the lighthouse", "evidence": "Mira climbs the tower"]
      return moved
    }
    let secret: [String: JSONValue] = [
      "category": "character_state", "state": ["entityKey": "probe", "location": "the vault", "evidence": .string(Self.secret), "quote": .string(Self.secret)],
    ]
    items.append(
      StoredFinalizeItem(
        key: "character_state:probe", position: items.count, category: .known(.characterState), triage: .known(.routine), basis: .known(.observed), subject: "probe",
        claim: claim, evidence: Self.secret, proposed: secret, autoDecision: autoKeep ? .known(.kept) : nil))
    world.base.clock.advance(1)
    let review = try FinalizeReviewRecord(
      attempt: try AttemptID(UUID.v7(at: world.base.clock.now)), job: rerun.ref.key, novel: novel, chapter: 1, draftRevision: first.draftRevision,
      sourceHash: first.sourceHash, planHash: first.planHash, isolated: isolated, items: items)
    try await Projection.write(world.store) { transaction in _ = try review.append(in: &transaction) }
  }
}

extension FinalizeReviewScreen {
  fileprivate var ready: Review? {
    guard case .ready(let review) = state else { return nil }
    return review
  }

  fileprivate var applied: Applied? {
    guard case .applied(let applied) = state else { return nil }
    return applied
  }
}
