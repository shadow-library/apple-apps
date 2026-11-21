import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForge

private struct FinalizeCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

/// A starter that records every job the runtime starts and refuses it, so nothing runs.
private final class RecordingStarter: Sendable {
  private let started = Mutex<[EntityRef]>([])

  var jobs: [EntityRef] { started.withLock { $0 } }

  var starter: JobEngineCalls.Start {
    { [self] _, job throws(JobEngineError) in
      started.withLock { $0.append(job) }
      throw .pipelineNotYetAvailable(.finalizeReview)
    }
  }
}

/// apps/novel-forge-server/tests/finalize-review/finalize-review.service.spec.ts:12-28: the prose and what its continuity read returns, one unsure update and
/// two routine ones.
nonisolated private enum FinalizeScript {
  static let prose = "Mira climbs the tower and the lamp burns cold."

  static let extraction: JSONValue = [
    "appeared": ["mira"], "newEntities": [], "threads": [["threadKey": "lamp_debt", "status": "closed", "summary": "Mira repays the keeper"]], "mysteries": [],
    "timeline": [], "relationships": [], "power": [], "characterStates": [["entityKey": "mira", "location": "the tower", "evidence": "Mira climbs the tower"]],
    "knowledgeChanges": [], "chapterSummary": "Mira climbs.", "milestones": [],
  ]
}

/// A novel with chapter 1 drafted, its Story Bible holding mira, and a job engine whose model answers the finalize review's read.
@MainActor
private struct FinalizeWorld {
  let store: VaultStore
  let novel: UUID
  let engine: JobEngine
  let model: FinalizeModel

  static func make(summary: String? = "Mira climbs.") async throws -> FinalizeWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in
      let novel = try Library.create(NewNovel(title: "Ashfall"), in: &transaction)
      try Entities.create(novel: novel, entity: "mira", type: .character, name: "Mira", in: &transaction)
      return novel
    }
    _ = try await store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: FinalizeScript.prose, summary: summary), base: nil, at: Date(), in: &transaction)
    }
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(FinalizeScript.extraction), as: UTF8.self))])
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let consent = ConsentDisclosure.novelText
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: binding.host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
    }
    let engine = try JobEngine(
      store: store,
      router: { requestGuard in
        TaskRouter(
          configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: FinalizeCredentials(), store: store,
          requestGuard: requestGuard)
      }, consent: consent.requirement, clock: LeaseClock(trusted: nil))
    return FinalizeWorld(store: store, novel: novel, engine: engine, model: FinalizeModel(store: store, novel: novel, chapter: 1))
  }

  func head() async throws -> String {
    let novel = novel
    let body = try await store.read { transaction in try ChapterContent.load(ChapterLocator(novel: novel, chapter: 1), in: transaction).body }
    guard case .draft(let draft) = body else { throw ChatFixtureError.noBinding }
    return draft.revision
  }

  /// Approves the head through the model and runs the read the approval asked for.
  func approvedAndRead() async throws {
    try await store.setFinalizeAutoKeep(novel: novel, categories: [])
    #expect(await model.approve(revision: try await head(), stale: nil))
    let job = try #require(try await store.finalizeReviewJob(novel: novel, chapter: 1))
    #expect(try await engine.run(job: job).result == .settled(.succeeded))
  }

  func screen() async throws -> FinalizeReviewScreen {
    try await store.load(FinalizeReviewScreen.self, FinalizeReviewScreenQuery(novel: novel, chapter: 1))
  }

  func readiness() async throws -> FinalizeReadiness {
    try await store.load(FinalizeReadiness.self, FinalizeReadinessQuery(novel: novel, chapter: 1))
  }

  func presentation() async throws -> FinalizePresentation {
    FinalizePresentation(screen: try await screen(), readiness: try await readiness())
  }

  func item(_ key: String) async throws -> FinalizeReviewScreen.Item {
    try #require(try await presentation().review?.items.first { $0.key == key })
  }
}

@MainActor
@Suite("Finalize")
struct FinalizeTests {
  @Test func shouldStartTheApprovedChaptersReadFromThisDevicesBacklog() async throws {
    let world = try await FinalizeWorld.make()
    let recorder = RecordingStarter()
    let runtime = JobRuntime(store: world.store, clock: LeaseClock(trusted: nil), platform: .mac, calls: JobEngineCalls(run: recorder.starter)) {
      [engine = world.engine] () throws(JobEngineError) in engine
    }
    await runtime.launch()
    defer { runtime.shutDown() }
    #expect(await world.model.approve(revision: try await world.head(), stale: nil))
    let job = try #require(try await world.store.finalizeReviewJob(novel: world.novel, chapter: 1))
    try await JobsWait.until("the runtime starts the read") { recorder.jobs.contains(job) }
    #expect(try await world.presentation().phase == .preparing)
  }

  @Test func shouldRefuseToApproveTextTheAuthorDidNotRead() async throws {
    let world = try await FinalizeWorld.make()
    #expect(await world.model.approve(revision: "not-the-head", stale: nil) == false)
    #expect(world.model.refusal?.detail == "DRF_013")
    #expect(world.model.refusal?.headline == FinalizeErrors.headline(code: "DRF_013"))
  }

  @Test func shouldShowTheUpdatesByCategoryAndKeepEveryAnswer() async throws {
    let world = try await FinalizeWorld.make()
    try await world.approvedAndRead()
    let presentation = try await world.presentation()
    #expect(presentation.phase == .answering(open: 3))
    #expect(presentation.consequential.map(\.category) == [.promise] && presentation.routine.map(\.category) == [.appearance, .characterState])
    let state = try await world.item("character_state:mira")
    #expect(FinalizeReviewDisplay.evidence(state.evidence)?.text == "“Mira climbs the tower”")
    #expect(FinalizeReviewDisplay.details(of: state.proposed).first?.value == "the tower")

    #expect(await world.model.answer(try await world.item("appearance:mira"), .keep))
    #expect(try await world.item("appearance:mira").decision == .kept)
    #expect(await world.model.answer(try await world.item("promise:thread:lamp_debt"), .skip(reason: "half paid")))
    let payoff = try await world.item("promise:thread:lamp_debt")
    #expect(payoff.decision == .skipped && payoff.reason == "half paid")

    var values = FinalizeEditFields.values(state)
    values["location"] = .text("the lighthouse")
    guard case .patch(let patch) = FinalizeEditFields.patch(state, values: values) else { throw ChatFixtureError.noBinding }
    #expect(await world.model.answer(state, .edit(patch)))
    let edited = try await world.item("character_state:mira")
    #expect(edited.decision == .edited && edited.edited?["state"]?["location"] == "the lighthouse")
    #expect(FinalizeEditFields.values(edited)["location"] == .text("the lighthouse"))
    #expect(try await world.presentation().phase == .finalizable)
  }

  @Test func shouldKeepTheProblemByItsItemWhenASkipHasNoReason() async throws {
    let world = try await FinalizeWorld.make()
    try await world.approvedAndRead()
    #expect(await world.model.answer(try await world.item("promise:thread:lamp_debt"), .skip(reason: "  ")) == false)
    #expect(world.model.problem(for: "promise:thread:lamp_debt")?.detail == "FRV_010")
    #expect(try await world.item("promise:thread:lamp_debt").decision == nil)
  }

  @Test func shouldKeepEveryRoutineUpdateAndRememberTheCategoriesKeptFromNowOn() async throws {
    let world = try await FinalizeWorld.make()
    try await world.approvedAndRead()
    let before = try await world.presentation()
    #expect(FinalizeReviewDisplay.keepAllTitle(before.routine) == String(localized: "Keep All", table: "Finalize"))
    #expect(before.autoKeepChoices == [.appearance, .characterState])
    #expect(await world.model.keepRoutine() == nil)
    let after = try await world.presentation()
    #expect(after.routine.allSatisfy { $0.decision == .kept && !$0.autoKept } && after.openRoutine == 0 && after.openConsequential == 1)

    #expect(await world.model.setAutoKeep(.characterState, on: true, current: after.autoKeep) == nil)
    #expect(try await world.screen().autoKeep == [.characterState])
    #expect(await world.model.setAutoKeep(.appearance, on: true, current: [.characterState]) == nil)
    #expect(try await world.screen().autoKeep == [.appearance, .characterState])
    #expect(await world.model.setAutoKeep(.characterState, on: false, current: [.appearance, .characterState]) == nil)
    #expect(try await world.screen().autoKeep == [.appearance])
  }

  @Test func shouldListWhatBlocksFinalizeInReadinessOrderAndEnableItOnlyWhenNothingDoes() async throws {
    let world = try await FinalizeWorld.make(summary: nil)
    try await world.store.setFinalizeAutoKeep(novel: world.novel, categories: [])
    #expect(await world.model.approve(revision: try await world.head(), stale: nil))
    let blockers = try #require(try await world.readiness().blockers.value)
    #expect(blockers == [.reviewPreparing, .summaryMissing(chapter: 1)])
    #expect(
      blockers.map(FinalizeErrors.headline(for:)) == [
        FinalizeErrors.headline(for: FinalizeRefusal.reviewPreparing(chapter: 1)), FinalizeErrors.headline(for: DomainError.summaryMissing(1)),
      ])

    let job = try #require(try await world.store.finalizeReviewJob(novel: world.novel, chapter: 1))
    #expect(try await world.engine.run(job: job).result == .settled(.succeeded))
    let answering = try await world.presentation()
    #expect(answering.blockers == [FinalizeErrors.headline(for: FinalizeBlocker.summaryMissing(chapter: 1))])
    #expect(answering.offersFinalize && !answering.canFinalize)
    try await answerEverything(world)
    let answered = try await world.presentation()
    #expect(answered.phase == .answered && !answered.canFinalize && answered.blockers.count == 1)
  }

  @Test func shouldFinalizeOnceEverythingIsAnsweredAndShowTheChapterFinal() async throws {
    let world = try await FinalizeWorld.make()
    try await world.approvedAndRead()
    try await answerEverything(world)
    let ready = try await world.presentation()
    #expect(ready.canFinalize && ready.blockers.isEmpty && ready.kept == 2)
    #expect(FinalizeReviewDisplay.finalizeTitle(kept: ready.kept) == String(localized: "Finalize and Keep \(2) Updates", table: "Finalize"))
    #expect(await world.model.finalize())
    #expect(world.model.finalized && world.model.refusal == nil)
    let final = try await world.presentation()
    #expect(final.phase == .applied && final.twoSets == nil && !final.offersFinalize)
    #expect(final.review?.items.count == 3)
    #expect(await world.model.finalize() == false)
    #expect(world.model.refusal?.detail == "DRF_002")
  }

  @Test(arguments: [
    FinalizeRefusal.openBlockingFindings(chapter: 1, count: 2), .reviewPreparing(chapter: 1), .reviewFailed, .proseChanged, .unanswered(count: 3),
    .strandedReveal(milestone: "crown", facts: ["heir"]), .isolatedByAuthorOnly(chapter: 1),
  ])
  func shouldHeadlineEveryFinalizeRefusal(_ refusal: FinalizeRefusal) {
    let presented = FinalizeErrors.presented(DomainError.finalizeRefused(refusal))
    #expect(presented.headline == FinalizeErrors.headline(for: refusal) && presented.detail == refusal.code)
    #expect(presented.headline != String(localized: "Something went wrong.", table: "Finalize"))
  }

  @Test func shouldHeadlineEachRefusalDifferently() {
    let refusals: [FinalizeRefusal] = [
      .openBlockingFindings(chapter: 1, count: 2), .reviewPreparing(chapter: 1), .reviewFailed, .proseChanged, .unanswered(count: 3),
      .strandedReveal(milestone: "crown", facts: ["heir"]), .isolatedByAuthorOnly(chapter: 1),
    ]
    #expect(Set(refusals.map(FinalizeErrors.headline(for:))).count == refusals.count)
    for code in ["DRF_001", "DRF_002", "DRF_004", "DRF_013", "DRF_017", "DRF_019", "PLN_004", "CHP_005", "CHP_010", "FIN_001", "FRV_001", "FRV_010", "FRV_011"] {
      let error: DomainError? =
        switch code {
        case "PLN_004": .planRevealsHeld(chapter: 1, violations: "crown")
        case "CHP_010": .summaryMissing(1)
        default: nil
        }
      let headline = error.flatMap(FinalizeErrors.headline(for:)) ?? FinalizeErrors.headline(code: code)
      #expect(headline != nil, "no headline for \(code)")
    }
  }

  @Test func shouldNeverPromiseToFinalizeAnIsolatedChapterOnItsOwnNorQuoteItsText() async throws {
    let withheld = "[excerpt withheld: unrestricted chapter]"
    let item = Self.item(evidence: withheld)
    let review = FinalizeReviewScreen.Review(id: UUID(), revision: "r1", isolated: true, items: [item])
    let isolated = FinalizePresentation(screen: FinalizeReviewScreen(state: .ready(review), autoKeep: [], isolated: true), readiness: nil)
    #expect(!isolated.finalizesOnItsOwn)
    #expect(FinalizePresentation(screen: FinalizeReviewScreen(state: .preparing(revision: "r1"), autoKeep: [], isolated: true), readiness: nil).finalizesOnItsOwn == false)
    #expect(FinalizePresentation(screen: FinalizeReviewScreen(state: .preparing(revision: "r1"), autoKeep: [], isolated: false), readiness: nil).finalizesOnItsOwn)
    let line = try #require(FinalizeReviewDisplay.evidence(item.evidence))
    #expect(line.label == nil && line.text == withheld)

    let world = try await FinalizeWorld.make()
    let (novel, head) = (world.novel, try await world.head())
    try await world.store.writeDomain { transaction throws(DomainError) in
      _ = try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: FinalizeScript.prose, isolated: true), base: head, in: &transaction)
    }
    #expect(try await world.screen().isolated)
  }

  @Test func shouldListBothSetsOfChangesOnlyWhenAnotherDevicesFinalizeNamedOthers() throws {
    let applied = FinalizeReviewScreen.Update(
      category: .characterState, claim: "Mira is at the tower",
      change: [
        "category": "character_state", "state": ["entityKey": "mira", "location": "the tower", "evidence": "Mira climbs the tower"],
      ])
    let other = FinalizeReviewScreen.Update(
      category: .characterState, claim: "Mira is at the lighthouse",
      change: [
        "category": "character_state", "state": ["entityKey": "mira", "location": "the lighthouse", "evidence": "Mira climbs the tower"],
      ])
    let lost = FinalizeReviewScreen.Applied(
      review: nil, isolated: false, kept: [applied],
      otherSets: [.init(id: "job-b", updates: [other], exact: true), .init(id: "job-a", updates: nil, exact: false)])
    let sets = try? #require(FinalizePresentation(screen: FinalizeReviewScreen(state: .applied(lost), autoKeep: [], isolated: false), readiness: nil).twoSets)
    #expect(sets?.applied.map(\.claim) == ["Mira is at the tower"] && sets?.others.map { $0.updates?.map(\.claim) } == [["Mira is at the lighthouse"], nil])
    #expect(sets?.others.map(\.exact) == [true, false] && sets?.id == "job-a job-b")
    #expect(
      sets?.others.first?.updates?.first?.details.first == FinalizePresentation.Detail(label: String(localized: "Where they are", table: "Finalize"), value: "the lighthouse"))
    #expect(sets?.applied.first?.category == FinalizeReviewDisplay.category(.characterState))

    let defaults = try #require(UserDefaults(suiteName: "FinalizeTests-\(UUID().uuidString)"))
    let acknowledgements = FinalizeAcknowledgements(defaults: defaults)
    let (novel, shown) = (UUID(), try #require(sets))
    #expect(!acknowledgements.isAcknowledged(shown, novel: novel, chapter: 1))
    acknowledgements.acknowledge(shown, novel: novel, chapter: 1)
    #expect(acknowledgements.isAcknowledged(shown, novel: novel, chapter: 1) && !acknowledgements.isAcknowledged(shown, novel: novel, chapter: 2))
    let later = FinalizePresentation.TwoSets(id: "job-a job-b job-c", applied: shown.applied, others: shown.others)
    #expect(!acknowledgements.isAcknowledged(later, novel: novel, chapter: 1))

    let alone = FinalizeReviewScreen.Applied(review: nil, isolated: false, kept: [applied], otherSets: [])
    #expect(FinalizePresentation(screen: FinalizeReviewScreen(state: .applied(alone), autoKeep: [], isolated: false), readiness: nil).twoSets == nil)
  }

  @Test func shouldWaitForReadinessBeforeApprovingAndConfirmEveryOverride() {
    let loading = FinalizeOffer(stage: .drafted, review: .needsReview, stale: nil, held: .loading)
    #expect(loading.approve == .standard && !loading.canApprove)
    let clear = FinalizeOffer(stage: .drafted, review: .needsReview, stale: nil, held: .count(0))
    #expect(clear.canApprove && clear.confirmation == .none)
    #expect(FinalizeOffer(stage: .drafted, review: .needsReview, stale: nil, held: .count(2)).confirmation == .overriding(2))
    let unknown = FinalizeOffer(stage: .drafted, review: .contradiction, stale: nil, held: .unknown)
    #expect(unknown.approve == .standard && unknown.canApprove && unknown.confirmation == .overridingUnknown)
    #expect(FinalizeOffer(stage: .drafted, review: .contradiction, stale: nil, held: .count(0)).approve == .refused)
    #expect(FinalizeOffer(stage: .drafted, review: .contradiction, stale: nil, held: .count(1)).confirmation == .overriding(1))
    let stale = FinalizeOffer(stage: .drafted, review: .needsReview, stale: .unrecorded, held: .count(0))
    #expect(stale.approve == .asWritten(.unrecorded) && stale.staleCause == .unrecorded)
    #expect(FinalizeOffer(stage: .drafted, review: .generating, stale: nil, held: .count(0)).approve == .none)
    let approved = FinalizeOffer(stage: .approved, review: .approved, stale: nil, held: .count(0))
    #expect(approved.approve == .none && approved.finalize && !approved.canApprove)
    let final = FinalizeOffer(stage: .final, review: .final, stale: nil, held: .count(0))
    #expect(final.final && !final.finalize && final.approve == .none)
    #expect(FinalizeOffer.Held(.loading) == .loading && FinalizeOffer.Held(.failed(PresentedError(headline: "x", detail: nil))) == .unknown)
  }

  @Test func shouldAskAgainWhenACheckLandedAfterTheConfirmationAndReportWhatWasOverridden() async throws {
    let world = try await FinalizeWorld.make()
    #expect(FinalizeOffer.Held(.loaded(try await world.readiness())) == .count(0))
    try await world.approvedAndRead()
    let head = try await world.head()
    let novel = world.novel
    let reads = try await world.store.read { transaction in try FinalizeReviewRecord.listing(novel: novel, chapter: 1, in: transaction).entries }
    let read = try #require(reads.first?.record)
    let findings = [
      ReviewFinding(id: "late-a", severity: .known(.blocking), category: .known(.continuity), text: "A.", fingerprint: "f-a"),
      ReviewFinding(id: "late-b", severity: .known(.blocking), category: .known(.continuity), text: "B.", fingerprint: "f-b"),
    ]
    let judge = try ChapterReviewRecord(
      novel: world.novel, chapter: 1, reviewKind: .known(.judge), draftRevision: head, bodyHash: read.sourceHash, disposition: .known(.blocking), findings: findings)
    _ = try await world.store.write { transaction in try judge.append(in: &transaction) }

    #expect(await world.model.approve(revision: head, stale: nil, overriding: .none) == false)
    #expect(world.model.reconfirm == 2 && world.model.refusal == nil && world.model.approved == nil)
    #expect(await world.model.approve(revision: head, stale: nil, overriding: .overriding(1)) == false)
    #expect(world.model.reconfirm == 2)
    #expect(await world.model.approve(revision: head, stale: nil, overriding: .overriding(2)))
    #expect(world.model.approved == FinalizeModel.Approved(overridden: 2) && world.model.reconfirm == nil)
    #expect(FinalizeErrors.headline(code: "chapters.approval_overrides_unconfirmed") != nil)
  }

  @Test func shouldListEveryBlockerButTheOpenAnswersInReadinessOrder() {
    let item = Self.item(evidence: "Mira climbs").answered
    let review = FinalizeReviewScreen.Review(id: UUID(), revision: "r1", isolated: false, items: [item])
    let screen = FinalizeReviewScreen(state: .ready(review), autoKeep: [], isolated: false)
    let blockers: [FinalizeBlocker] = [.summaryMissing(chapter: 2), .unanswered(count: 1), .planReveals(chapter: 2, violations: "crown"), .outOfOrder(chapter: 2)]
    let presentation = FinalizePresentation(screen: screen, blockers: .available(blockers))
    #expect(presentation.phase == .answered && !presentation.canFinalize)
    #expect(presentation.blockers == [blockers[0], blockers[2], blockers[3]].map(FinalizeErrors.headline(for:)))
    #expect(FinalizePresentation(screen: screen, blockers: .available([])).phase == .finalizable)
    let unavailable = FinalizePresentation(screen: screen, blockers: .unavailable([]))
    #expect(unavailable.readinessUnavailable && !unavailable.canFinalize)
    #expect(FinalizePresentation(screen: FinalizeReviewScreen(state: .preparing(revision: "r1"), autoKeep: [], isolated: false), blockers: .available(blockers)).blockers.isEmpty)
  }

  @Test func shouldAskForAReasonBeforeSkipping() {
    #expect(FinalizeSkipForm.reason("  \n") == nil)
    #expect(FinalizeSkipForm.reason(" half paid \n") == "half paid")
    #expect(FinalizeSkipForm.reason("\u{FEFF} half paid\u{FEFF}") == "half paid")
  }

  @Test func shouldMarkWhatCarriedOverAndWhatAReadReopened() {
    let reopened = Self.item(evidence: "Mira climbs", carriedOver: false, reopened: true)
    let carried = Self.item(evidence: "Mira climbs", carriedOver: true, reopened: false).answered
    #expect(FinalizeItemProvenance.marks(reopened) == [.reopened] && FinalizeItemProvenance.marks(carried) == [.carriedOver])
    #expect(FinalizeItemProvenance.marks(Self.item(evidence: "Mira climbs")).isEmpty)
    let review = FinalizeReviewScreen.Review(id: UUID(), revision: "r1", isolated: false, items: [reopened, carried])
    #expect(FinalizePresentation(screen: FinalizeReviewScreen(state: .ready(review), autoKeep: [], isolated: false), blockers: nil).reopened == 1)
  }

  @Test func shouldOfferReadAgainAtOnceForAFailedReadAndAfterAMinuteForAStuckOne() {
    #expect(FinalizePresentation.stuckAfter == .seconds(60))
    let preparing = FinalizePresentation(screen: FinalizeReviewScreen(state: .preparing(revision: "r1"), autoKeep: [], isolated: false), blockers: nil)
    #expect(!preparing.offersReadAgain(stuck: false) && preparing.offersReadAgain(stuck: true))
    let failure = AttemptFailure(code: "model.server", message: "upstream 500")
    let failed = FinalizePresentation(screen: FinalizeReviewScreen(state: .failed(revision: "r1", failure: failure), autoKeep: [], isolated: false), blockers: nil)
    #expect(failed.phase == .failed(failure) && failed.offersReadAgain(stuck: false))
    #expect(JobsErrors.failure(failure) == JobsErrors.headline(code: "model.server"))
    let unavailable = FinalizePresentation(screen: FinalizeReviewScreen(state: .unavailable(.unreadable), autoKeep: [], isolated: false), blockers: nil)
    #expect(unavailable.phase == .unavailable(.unreadable) && !unavailable.offersReadAgain(stuck: true) && !unavailable.offersFinalize)
    #expect(unavailable.unavailableMessage?.contains("update the app") == true)
    let rebuilding = FinalizePresentation(screen: FinalizeReviewScreen(state: .unavailable(.rebuilding), autoKeep: [], isolated: false), blockers: nil)
    #expect(rebuilding.unavailableMessage != unavailable.unavailableMessage && rebuilding.unavailableMessage != nil)
  }

  @Test func shouldEnableTheDialogsFinalizeOnlyWhenNothingBlocksOrWaits() {
    let review = FinalizeReviewScreen.Review(id: UUID(), revision: "r1", isolated: false, items: [Self.item(evidence: "Mira climbs").answered])
    let ready = FinalizePresentation(screen: FinalizeReviewScreen(state: .ready(review), autoKeep: [], isolated: false), blockers: .available([]))
    #expect(ready.finalizeEnabled(deciding: false, finalizing: false, formOpen: false))
    #expect(!ready.finalizeEnabled(deciding: true, finalizing: false, formOpen: false))
    #expect(!ready.finalizeEnabled(deciding: false, finalizing: true, formOpen: false))
    #expect(!ready.finalizeEnabled(deciding: false, finalizing: false, formOpen: true))
    let blocked = FinalizePresentation(screen: FinalizeReviewScreen(state: .ready(review), autoKeep: [], isolated: false), blockers: .available([.outOfOrder(chapter: 2)]))
    #expect(blocked.offersFinalize && !blocked.finalizeEnabled(deciding: false, finalizing: false, formOpen: false))
  }

  private func answerEverything(_ world: FinalizeWorld) async throws {
    #expect(await world.model.keepRoutine() == nil)
    #expect(await world.model.answer(try await world.item("promise:thread:lamp_debt"), .skip(reason: "half paid")))
  }

  private static func item(evidence: String, carriedOver: Bool = false, reopened: Bool = false) -> FinalizeReviewScreen.Item {
    FinalizeReviewScreen.Item(
      key: "character_state:mira", category: .characterState, triage: .consequential, basis: .observed, flag: nil, subject: "mira", claim: "Mira is at the tower",
      evidence: evidence, dependents: [], proposed: ["category": "character_state", "state": ["entityKey": "mira", "evidence": .string(evidence)]], edited: nil,
      decision: nil, reason: nil, autoKept: false, carriedOver: carriedOver, reopened: reopened)
  }
}

extension FinalizeReviewScreen.Item {
  fileprivate var answered: FinalizeReviewScreen.Item {
    FinalizeReviewScreen.Item(
      key: key, category: category, triage: triage, basis: basis, flag: flag, subject: subject, claim: claim, evidence: evidence, dependents: dependents,
      proposed: proposed, edited: edited, decision: .kept, reason: reason, autoKept: autoKept, carriedOver: carriedOver, reopened: reopened)
  }
}
