import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Canon refresh pipeline", TestTimeLimit.standard)
struct CanonRefreshPipelineTests {
  private static func refresh(_ world: RefreshWorld, unrestrictedAvailable: Bool = false) async throws -> (JobKey, AttemptResult) {
    let engine = try world.engine(unrestrictedAvailable: unrestrictedAvailable)
    let key = try await engine.requestCanonRefresh(novel: world.novel, chapter: 1)
    return (key, try await engine.run(job: key.ref).result)
  }

  // chapter-canon-refresh.service.ts:82-146: one call over the Bible and the chapter, then one bible_audit card and the report that names it
  @Test func shouldStageOneSessionlessBibleAuditCardAndStoreTheReport() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let (key, result) = try await Self.refresh(world)
    guard case .settled(.succeeded) = result else {
      Issue.record("the refresh did not succeed: \(result)")
      return
    }
    #expect(world.provider.requests.count == 1)
    let system = world.provider.requests.first?.system.map(\.text).joined(separator: "\n") ?? ""
    #expect(system.contains("[entity:mara]\nname: Mara\ntype: character\nstatus: \(RefreshWorld.maraStatus)"))
    #expect(system.contains("[fact:heir]\nSECRET — the reader has not been told. Mara is the heir."))
    #expect(world.userPrompts.first?.hasPrefix("## The finalized chapter\n\n[chapter:1]\nThe Crown\n\n\(RefreshWorld.prose)") == true)

    let card = try #require(try await world.card(of: key))
    let report = try #require(try await world.reports().first)
    let copy = "Chapter 1: 1 finding: 1 to revise. Checked against chapter 1: 1 page, 1 character, 1 fact."
    let digest = try await world.canonDigest()
    #expect(report.copy == copy && report.canonDigest == digest)
    #expect(report.id == RefreshRecords.report(of: key.ref) && report.proposal == card.id && report.attempt != nil)
    #expect(report.findings.map { $0["group"] } == [.string("revise")] && report.findings.first?["opIndexes"] == .array([.int(0)]))
    #expect(report.findings.first?["withheld"] == .null && report.checked["copy"] == .string("Checked against chapter 1: 1 page, 1 character, 1 fact."))
    #expect(card.card.kind == .known(.bibleAudit) && card.card.session == nil && card.card.summary == copy && card.card.run == key.ref.key.rawValue)
    let proposals = try await world.proposals()
    #expect(card.card.changeSet.count == 1 && proposals.count == 1)

    let novel = world.novel
    let waiting = try #require(try await world.store.read { transaction in try ChatWaitingOnYou.load(novel, in: transaction) }.contents.value)
    #expect(waiting.cards.map(\.state.proposal) == [card.id] && waiting.cards.first?.session == ChatProposalSession.none)
  }

  @Test func shouldUpdateTheStoryBibleWhenTheCardIsApplied() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let (key, _) = try await Self.refresh(world)
    let card = try #require(try await world.card(of: key))
    let outcome = try await world.store.applyProposal(card.id, selection: .whole, context: ProposalApplyContext(novel: world.novel, now: world.engineWorld.clock.now))
    guard case .applied = outcome else {
      Issue.record("the refresh card did not apply: \(outcome)")
      return
    }
    #expect(try await world.mara()?.status == RefreshWorld.crowned)
  }

  // bible-audit-report.ts:249, chapter-canon-refresh.service.ts:112-114: findings whose every change is withheld store a report and stage no card
  @Test func shouldStoreTheReportButStageNoCardWhenEveryChangeIsWithheld() async throws {
    let kael = RefreshWorld.update(
      "Kael appears for the first time.", quotes: [("chapter:1", "crowned herself queen of the salt road")],
      ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("kael")), ("type", .string("character")), ("status", .string("A guard."))])])
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([kael])])
    let (key, result) = try await Self.refresh(world)
    #expect(result == .settled(.succeeded))
    let report = try #require(try await world.reports().first)
    #expect(report.proposal == nil && report.findings.first?["withheld"] == .string(RefreshWithheld.newRecord))
    #expect(report.findings.first?["group"] == .string("add") && report.findings.first?["opIndexes"] == .array([]))
    let (card, proposals) = (try await world.card(of: key), try await world.proposals())
    #expect(card == nil && proposals.isEmpty)
  }

  // chapter-canon-refresh.service.ts:105; bible-audit-report.ts:258
  @Test(arguments: [0, 1])
  func shouldStoreNothingWhenNothingStands(unquotedUpdates: Int) async throws {
    let unquoted = Array(
      repeating: RefreshWorld.update(
        "Mara is queen.", quotes: [("chapter:1", "she abdicated the salt road throne")],
        ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("mara")), ("type", .string("character")), ("status", .string("Queen."))])]),
      count: unquotedUpdates)
    let world = try await RefreshWorld(replies: [RefreshWorld.reply(unquoted)])
    let (key, result) = try await Self.refresh(world)
    #expect(result == .settled(.succeeded) && world.provider.requests.count == 1)
    let (reports, card) = (try await world.reports(), try await world.card(of: key))
    #expect(reports.isEmpty && card == nil)
  }

  // chapter-canon-refresh.service.ts:181-182: an isolated chapter is never read by the refresh
  @Test func shouldNotRefreshAnIsolatedChapter() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], canon: Canon(body: RefreshWorld.prose, isolated: true))
    let (_, result) = try await Self.refresh(world, unrestrictedAvailable: true)
    let reports = try await world.reports()
    #expect(result == .settled(.succeeded) && world.provider.requests.isEmpty && reports.isEmpty)
  }

  @Test func shouldSendNothingForAChapterWithNoText() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], canon: Canon(title: "  ", body: "\n"))
    let (_, result) = try await Self.refresh(world)
    let reports = try await world.reports()
    #expect(result == .settled(.succeeded) && world.provider.requests.isEmpty && reports.isEmpty)
  }

  // model-router.service.ts:375-378 with the novel's own plugin class: an unrestricted novel's refresh reaches the unrestricted model only where it may
  @Test func shouldRouteAnUnrestrictedNovelsRefreshUnrestrictedOnlyWhereItIsAvailable() async throws {
    let allowed = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], mode: .unrestricted)
    let (_, ran) = try await Self.refresh(allowed, unrestrictedAvailable: true)
    #expect(ran == .settled(.succeeded) && allowed.provider.requests.first?.model == CompactionWorld.unrestrictedModel)
    let stored = try await allowed.reports()
    #expect(stored.count == 1)

    let refused = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], mode: .unrestricted)
    let (_, result) = try await Self.refresh(refused)
    #expect(refused.failure(result)?.code == ChapterCallError.unrestrictedUnavailable.code)
    let none = try await refused.reports()
    #expect(refused.provider.requests.isEmpty && none.isEmpty)

    let standard = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    _ = try await Self.refresh(standard, unrestrictedAvailable: true)
    #expect(standard.provider.requests.first?.model != CompactionWorld.unrestrictedModel)
  }

  // hard-line.ts:234 with the novel's live minor names (G19): the chapter text is screened before an unrestricted call is sent
  @Test func shouldRefuseAnUnrestrictedRefreshWhoseChapterNamesAMinor() async throws {
    let world = try await RefreshWorld(
      replies: [RefreshWorld.reply([RefreshWorld.crowning])], mode: .unrestricted, canon: Canon(body: "Pip and the orgasm.")
    ) { novel, transaction in
      _ = try EntityRecord(novel: novel, entity: "pip", type: .known(.character), name: "Pip", age: 15).create(in: &transaction)
    }
    let (_, result) = try await Self.refresh(world, unrestrictedAvailable: true)
    #expect(world.failure(result)?.code == ChapterCallError.hardLine(HardLineHit(rule: .minorWithExplicitAct, source: "", sourceRefs: [])).code)
    let reports = try await world.reports()
    #expect(world.provider.requests.isEmpty && reports.isEmpty)
  }

  // chapter-canon-refresh.service.ts:69-70: a report already stored for the canon answers the run with no call
  @Test func shouldAnswerARunWithTheReportAlreadyStoredForTheCanon() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let (novel, digest) = (world.novel, try await world.canonDigest())
    try await world.store.write { transaction in
      _ = try RefreshReportRecord(novel: novel, chapter: 1, canonDigest: digest, findings: [], checked: [:], copy: "earlier").append(in: &transaction)
    }
    let (key, result) = try await Self.refresh(world)
    #expect(result == .settled(.succeeded) && world.provider.requests.isEmpty)
    let (reports, card) = (try await world.reports(), try await world.card(of: key))
    #expect(reports.map(\.copy) == ["earlier"] && card == nil)
  }

  // A canon another device finalized first is refreshed by that device's job; this one's settles with no call.
  @Test func shouldSettleARefreshOfACanonThatNoLongerStands() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let engine = try world.engine()
    let input = CanonRefreshJobInput(chapter: 1, canonDigest: "lost")
    let key = try await engine.request(
      NovelJobRequest(kind: .canonRefresh, novel: world.novel, chapter: 1, fingerprint: input.fingerprint, payload: input.json))
    let result = try await engine.run(job: key.ref).result
    let reports = try await world.reports()
    #expect(result == .settled(.succeeded) && world.provider.requests.isEmpty && reports.isEmpty)
  }

  // chapter-canon-refresh.service.ts:181
  @Test func shouldSettleARefreshOfAChapterThatIsNotFinalWithNoCall() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let engine = try world.engine()
    let key = try await engine.request(NovelJobRequest(kind: .canonRefresh, novel: world.novel, chapter: 2, fingerprint: "abc"))
    let result = try await engine.run(job: key.ref).result
    let reports = try await world.reports(chapter: 2)
    #expect(result == .settled(.succeeded) && world.provider.requests.isEmpty && reports.isEmpty)
  }

  // A report of the chapter this version cannot read may be the canon's, so it answers the run as one would.
  @Test func shouldSettleWithNoCallWhenTheChapterHoldsAReportThisVersionCannotRead() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let report = RefreshReportRecord(novel: world.novel, chapter: 1, canonDigest: try await world.canonDigest(), findings: [], checked: [:], copy: "later")
    let item = report.item.filter { $0.key != RefreshReportMember.copy.rawValue }
    try await world.store.write { transaction in _ = try transaction.append(report.ref, item: item) }
    let (key, result) = try await Self.refresh(world)
    let (card, proposals) = (try await world.card(of: key), try await world.proposals())
    #expect(result == .settled(.succeeded) && world.provider.requests.isEmpty && card == nil && proposals.isEmpty)
  }

  @Test func shouldDeriveTheCardAndReportIdsFromTheJobKey() throws {
    let key = try JobKey(scope: NovelJobAddress.scope(of: SchemaFixture.novel), kind: "canon_refresh", target: "chapter:3", fingerprint: "abc", run: 1)
    #expect(key.ref.key.rawValue == "n:fb46c4da301a669bb1b9705ead9bd9317eb722dd")
    #expect(RefreshRecords.card(of: key.ref) == UUID(uuidString: "C4E88FC4-B782-808F-8CF4-E8A13ACF3BD1"))
    #expect(RefreshRecords.report(of: key.ref) == UUID(uuidString: "8E536027-839F-889D-837F-740A2C51C0B2"))
  }

  // chapter-canon-refresh.service.ts:120: `summary.slice(0, 300)` counts UTF-16 code units, not characters
  @Test func shouldCutTheCardSummaryAtThreeHundredCodeUnits() async throws {
    let world = try await RefreshWorld()
    let (novel, digest) = (world.novel, try await world.canonDigest())
    let job = try JobKey(scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.canonRefresh.rawValue, target: "chapter:1", fingerprint: digest, run: 1).ref
    let copy = String(repeating: "e\u{301}", count: 200)
    let op: JSONValue = ["op": "entity.upsert", "entityKey": "mara", "type": "character", "status": "Queen."]
    let checkpoint = RefreshCheckpoint(findings: [], checked: [:], copy: copy, changeSet: [op], baseline: ArtifactStates())
    let attempt = try AttemptID(UUID.v7(at: world.engineWorld.clock.now))
    try await world.store.write { transaction in
      try RefreshStage.write(checkpoint, canonDigest: digest, job: job, novel: novel, chapter: 1, attempt: attempt, in: &transaction)
    }
    let summary = try #require(try await world.store.read { transaction in try ProposalRecord.read(id: RefreshRecords.card(of: job), in: transaction).entry }?.record.card.summary)
    let report = try #require(try await world.reports().first)
    #expect(summary.jsLength == 300 && summary.jsEquals(String(repeating: "e\u{301}", count: 150)) && report.copy.jsEquals(copy))
  }

  @Test func shouldReadTheCanonFromTheFingerprintWhenThePayloadNamesNone() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let engine = try world.engine()
    let digest = try await world.canonDigest()
    let key = try await engine.request(NovelJobRequest(kind: .canonRefresh, novel: world.novel, chapter: 1, fingerprint: digest))
    let result = try await engine.run(job: key.ref).result
    let reports = try await world.reports()
    #expect(result == .settled(.succeeded) && reports.map(\.canonDigest) == [digest])
    #expect(try await engine.requestCanonRefresh(novel: world.novel, chapter: 1) == key)
  }

  @Test func shouldRequestOneJobPerCanon() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([])])
    let engine = try world.engine()
    let key = try await engine.requestCanonRefresh(novel: world.novel, chapter: 1)
    #expect(key.kind == NovelJobKind.canonRefresh.rawValue && key.target == NovelJobAddress.target(chapter: 1) && key.run == 1)
    let (novel, digest, replica) = (world.novel, try await world.canonDigest(), world.store.replica)
    #expect(key.fingerprint == digest)
    let again = try await engine.requestCanonRefresh(novel: novel, chapter: 1)
    #expect(again == key)
    let committed = try await world.store.writeDomain { transaction throws(DomainError) in
      try CanonRefreshJobs.request(novel: novel, chapter: 1, canonDigest: digest, requester: replica, in: &transaction)
    }
    #expect(committed == key)
    let result = try await engine.run(job: key.ref).result
    let afterwards = try await engine.requestCanonRefresh(novel: novel, chapter: 1)
    #expect(result == .settled(.succeeded) && afterwards == key)

    _ = try await engine.cancel(job: key.ref)
    let next = try await world.store.writeDomain { transaction throws(DomainError) in
      try CanonRefreshJobs.request(novel: novel, chapter: 1, canonDigest: digest, requester: replica, in: &transaction)
    }
    #expect(next == key)

    do {
      _ = try await engine.requestCanonRefresh(novel: world.novel, chapter: 2)
      Issue.record("a chapter that is not final was refreshed")
    } catch {
      #expect(error.code == CanonRefreshRequestError.notFinal(chapter: 2).code)
    }
  }

  @Test func shouldAskForTheNextRunOfACancelledRefresh() async throws {
    let world = try await RefreshWorld()
    let engine = try world.engine()
    let key = try await engine.requestCanonRefresh(novel: world.novel, chapter: 1)
    _ = try await engine.cancel(job: key.ref)
    let (novel, digest, replica) = (world.novel, try await world.canonDigest(), world.store.replica)
    let next = try await world.store.writeDomain { transaction throws(DomainError) in
      try CanonRefreshJobs.request(novel: novel, chapter: 1, canonDigest: digest, requester: replica, in: &transaction)
    }
    #expect(next.run == 2 && next.fingerprint == key.fingerprint)
    let asked = try await engine.requestCanonRefresh(novel: novel, chapter: 1)
    #expect(asked == next)
  }
}
