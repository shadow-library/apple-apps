import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Generation pipeline", TestTimeLimit.standard)
struct GenerationPipelineTests {
  @Test func shouldDraftJudgeAndAcceptAFirstDraftAsTheHead() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    let engine = try world.engine()
    let handle = try await world.generate(engine)

    let saved = try await world.saved(handle.job)
    #expect(saved.count == 1)
    let revision = try #require(saved.first)
    let content = try #require(revision.body.body)
    #expect(content.body == GenerationWorld.body && content.title == "The Torn Page" && content.summary == "Mara finds the logbook torn.")
    #expect(content.source == .known(.generated) && content.generator == .known(.standard) && !content.isolated)
    #expect(content.run == handle.attempt.uuid.lowercasedString && content.job == handle.job.key)
    #expect(content.state == ["lastBeat": "The tide comes in.", "openConflict": "Who tore the page?"])
    #expect(content.upstream != nil)
    #expect(try await world.history().head == revision.id)

    let pass = try #require(try await world.passes().first)
    #expect(pass.id == handle.attempt.uuid && pass.draftRevision == revision.id && pass.verdict == "consistent" && pass.findings.isEmpty)
    #expect(pass.disposition == .known(.clear) && pass.job == handle.job.key && pass.attempt == handle.attempt && !pass.isolated)
    #expect(pass.calls?.count == 1)
    #expect(try await world.lifecycle().review == .needsReview)
    let report = try await world.store.generationReport(novel: world.novel, chapter: 1, job: handle.job)
    #expect(report == GenerationReport(revisions: [revision.id], review: pass.id, judged: revision.id, isHead: true))

    let attempt = try await world.base.attempt(handle.attempt)
    #expect(attempt.calls.count == 2 && world.provider.requests.count == 2)
    let snapshots = try await world.store.writerSnapshots(novel: world.novel, chapter: 1)
    #expect(snapshots.map(\.role) == [.draft] && snapshots.first?.revision == revision.id && snapshots.first?.attempt == 0)
    let draftRequest = try #require(world.provider.requests.first?.messages.last?.text)
    #expect(draftRequest.contains("Chapter brief:\n") && draftRequest.contains("Additional guidance: "))
  }

  @Test func shouldKeepTheOldProseAsAVersionAndMoveTheHeadToTheJudgedRevision() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    let old = try await world.handDraft()
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    let saved = try #require(try await world.saved(handle.job).first)
    #expect(saved.parent == old)
    let history = try await world.history()
    #expect(history.head == saved.id && history.revisions.contains { $0.id == old })
  }

  @Test func shouldHoldTheChapterAfterAcceptingItAsIsOnceTheRepairsAreSpent() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.contradiction])
    let engine = try world.engine()
    let handle = try await world.generate(engine, options: GenerationOptions(maxFixes: 0))
    let pass = try #require(try await world.passes().first)
    #expect(pass.verdict == "contradiction" && pass.disposition == .known(.blocking))
    #expect(pass.findings.map(\.category) == [.known(.continuity)] && pass.findings.first?.severity == .known(.blocking))
    #expect(try await world.history().head == pass.draftRevision)
    let held = try await world.lifecycle()
    #expect(held.review == .contradiction && held.judge == pass.id)
    #expect(try await world.saved(handle.job).count == 1 && world.provider.requests.count == 2)
  }

  @Test func shouldAwaitReviewWithoutRepairingWhenRepairIsOff() async throws {
    let missedBrief = GenerationWorld.judgeReply(brief: ["compliant": false, "issues": []])
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), missedBrief])
    let engine = try world.engine()
    try await world.generate(engine, options: GenerationOptions(autoFix: false))
    let pass = try #require(try await world.passes().first)
    #expect(pass.verdict == "consistent")
    #expect(pass.findings.map(\.category) == [.known(.brief)] && pass.findings.first?.text.contains("named no issue") == true)
    #expect(try await world.lifecycle().review == .contradiction)
    #expect(world.provider.requests.count == 2)
  }

  @Test func shouldPatchSaveAndJudgeAgainUntilAccepted() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.contradiction, GenerationWorld.patchReply(), GenerationWorld.judgeReply()])
    let old = try await world.handDraft()
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    let saved = try await world.saved(handle.job)
    #expect(saved.map { $0.body.body?.source } == [.known(.generated), .known(.patched)])
    #expect(saved.first?.parent == old && saved.last?.parent == saved.first?.id)
    #expect(saved.last?.body.body?.body == GenerationWorld.patchedBody)
    #expect(try await world.history().head == saved.last?.id)
    let passes = try await world.passes()
    #expect(passes.count == 1 && passes.first?.draftRevision == saved.last?.id && passes.first?.verdict == "consistent")
    #expect(try await world.lifecycle().review == .needsReview)
    #expect(world.provider.requests.count == 4)
    let fix = try #require(world.provider.requests[2].messages.last?.text)
    #expect(fix.hasPrefix("Draft to repair:\n\(GenerationWorld.body)\n\nFindings:\n[hard] Mara climbs at dusk"))
    let snapshots = try await world.store.writerSnapshots(novel: world.novel, chapter: 1)
    #expect(snapshots.map(\.role) == [.repair, .draft] && snapshots.first?.attempt == 1 && snapshots.first?.revision == saved.last?.id)
  }

  @Test func shouldRedraftAfreshWhenTheFixAsksForARewriteAndDiscardItsBody() async throws {
    let rewrite = GenerationWorld.reply(["action": "rewrite", "body": "A body the fix wrote that the reference never keeps, long enough to pass the schema of the fix call."])
    let world = try await GenerationWorld(calls: [
      GenerationWorld.draftReply(), GenerationWorld.contradiction, rewrite, GenerationWorld.draftReply(GenerationWorld.rewrittenBody, title: "The Keeper"),
      GenerationWorld.judgeReply(),
    ])
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    let saved = try await world.saved(handle.job)
    #expect(saved.map { $0.body.body?.source } == [.known(.generated), .known(.rewritten)])
    #expect(saved.last?.body.body?.body == GenerationWorld.rewrittenBody && saved.last?.body.body?.title == "The Keeper")
    let redraft = try #require(world.provider.requests[3].messages.last?.text)
    #expect(redraft.hasSuffix("Additional guidance: Avoid these issues from the previous draft:\n[hard] Mara climbs at dusk, but chapter 0 ends at dawn."))
    let snapshots = try await world.store.writerSnapshots(novel: world.novel, chapter: 1)
    #expect(Set(snapshots.prefix(2).map(\.role)) == [.rewrite, .repair] && snapshots.last?.role == .draft)
    #expect(snapshots.prefix(2).allSatisfy { $0.attempt == 1 && $0.revision == saved.last?.id })
    #expect(world.provider.requests.count == 5)
  }

  @Test func shouldAskTheJudgeOnceMoreThenAwaitReviewWithAFailedPass() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), ScriptedModelProvider.reply("no verdict"), ScriptedModelProvider.reply("still none")])
    let engine = try world.engine()
    try await world.generate(engine)
    #expect(world.provider.requests.count == 3 && world.provider.requests[1] == world.provider.requests[2])
    let pass = try #require(try await world.passes().first)
    #expect(pass.verdict == "evaluation_failed" && pass.disposition == .known(.failed) && pass.checked.isEmpty)
    #expect(pass.findings.map(\.text) == ["judge output unparseable", "judge omitted briefCompliance — treated as non-compliant"])
    #expect(pass.calls?.count == 2)
    #expect(try await world.lifecycle().review == .contradiction)
  }

  @Test func shouldExpandAShortDraftTwiceAtMost() async throws {
    let words = { (count: Int) in (1...count).map { "word\($0)" }.joined(separator: " ") + "." }
    let world = try await GenerationWorld(
      calls: [
        GenerationWorld.draftReply(words(40)), GenerationWorld.reply(["body": .string(words(60))]), GenerationWorld.reply(["body": .string(words(80))]),
        GenerationWorld.judgeReply(),
      ], wordTarget: WordTarget(min: 100, max: 400))
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    #expect(try await world.saved(handle.job).first?.body.body?.body == words(80))
    #expect(world.provider.requests.count == 4)
    #expect(world.provider.requests[2].messages.last?.text.contains("Current draft (60 words):") == true)
  }

  @Test func shouldKeepTheDraftWhenAnExpansionComesBackShorter() async throws {
    let words = { (count: Int) in (1...count).map { "word\($0)" }.joined(separator: " ") + "." }
    let world = try await GenerationWorld(
      calls: [GenerationWorld.draftReply(words(40)), GenerationWorld.reply(["body": .string(words(30))]), GenerationWorld.judgeReply()],
      wordTarget: WordTarget(min: 100, max: 400))
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    #expect(try await world.saved(handle.job).first?.body.body?.body == words(40))
    #expect(world.provider.requests.count == 3)
  }

  @Test func shouldLeaveTheJudgedRevisionAsAVersionAndRecordNoPassWhenTheHeadMovedDuringTheRun() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    let old = try await world.handDraft()
    let handle = try await world.interrupted(at: .afterCommit(step: 2))
    #expect(try await world.lifecycle().review == .generating)
    #expect(try await world.history().head == old)
    let moved = try await world.handDraft("The author's own words.")
    try await world.resume()
    let saved = try #require(try await world.saved(handle.job).first)
    #expect(try await world.history().head == moved)
    #expect(saved.parent == old)
    #expect(try await world.passes().isEmpty)
    let report = try await world.store.generationReport(novel: world.novel, chapter: 1, job: handle.job)
    #expect(report.isHead == false && report.judged == saved.id && report.review == nil)
    #expect(try await world.lifecycle().review == .needsReview)
  }

  @Test func shouldKeepAContradictionOnTheAuthorsNewHeadWhenTheRunEndsUnderIt() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    try await world.handDraft()
    _ = try await world.interrupted(at: .afterCommit(step: 2))
    let body = "The author's own words."
    let moved = try await world.handDraft(body)
    let novel = world.novel
    let review = UUID()
    try await world.store.write { transaction in
      let finding = ReviewFinding(id: "f1", severity: .known(.blocking), category: .known(.continuity), text: "A contradiction.", fingerprint: "fp")
      _ = try ChapterReviewRecord(
        id: review, novel: novel, chapter: 1, reviewKind: .known(.judge), draftRevision: moved, bodyHash: hashReviewedBody(body), disposition: .known(.blocking),
        verdict: "contradiction", findings: [finding]
      ).append(in: &transaction)
    }
    try await world.resume()
    let held = try await world.lifecycle()
    #expect(held.review == .contradiction && held.openBlocking == 1 && held.judge == review)
  }

  @Test func shouldKeepTheAuthorsWorkingCopyAsAVersionBeforeMovingTheHead() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    let old = try await world.handDraft()
    let handle = try await world.interrupted(at: .afterCommit(step: 2))
    let novel = world.novel
    let typed = "Typed while the AI wrote."
    try await world.store.write { transaction in try ChapterDrafts.hold(novel: novel, chapter: 1, title: nil, body: typed, base: old, in: &transaction) }
    try await world.resume()
    let history = try await world.history()
    let saved = try #require(try await world.saved(handle.job).first)
    #expect(history.head == saved.id)
    #expect(history.revisions.contains { $0.body.body?.body == typed && $0.body.body?.source == .known(.handEdited) })
    #expect(try await world.store.read { transaction in try DraftWorkingCopy.read(novel: novel, chapter: 1, in: transaction.database) } == nil)
    #expect(try await world.passes().first?.draftRevision == saved.id)
  }

  @Test func shouldScrubAWithheldFactOutOfTheGuidanceTheWriterReads() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", revealChapter: 3).create(in: &transaction)
    }
    let engine = try world.engine()
    try await world.generate(engine, options: GenerationOptions(guidance: "Remember that Mara is the heir."))
    let sent = try #require(world.provider.requests.first?.messages.last?.text)
    let guidance = try #require(sent.components(separatedBy: "Additional guidance: ").last)
    #expect(!guidance.contains("Mara is the heir") && guidance.contains(withheldMarker))
  }

  @Test func shouldStartAFailedJobAfreshWithItsOwnSavesOnThePinnedHead() async throws {
    let refused: [ScriptedModelProvider.Step] = [.failure(.invalidRequest("refused"))]
    let world = try await GenerationWorld(calls: [
      GenerationWorld.draftReply(), refused, GenerationWorld.draftReply(GenerationWorld.rewrittenBody), GenerationWorld.judgeReply(),
    ])
    let old = try await world.handDraft()
    let engine = try world.engine()
    guard case .running(let failed) = try await engine.regenerateChapter(novel: world.novel, chapter: 1) else { throw EngineFixtureError(description: "not run here") }
    guard case .settled(.failed(let failure)) = await failed.result else {
      Issue.record("the first attempt did not fail")
      return
    }
    #expect(failure.code == "model.invalid_request")
    let again = try await engine.run(job: failed.job)
    #expect(await again.result == .settled(.succeeded))
    let saved = try await world.saved(failed.job)
    #expect(saved.count == 2 && saved.allSatisfy { $0.parent == old })
    #expect(Set(saved.compactMap { $0.body.body?.run }) == [failed.attempt.uuid.lowercasedString, again.attempt.uuid.lowercasedString])
    #expect(try await world.history().head == saved.last?.id)
    #expect(try await world.passes().map(\.draftRevision) == [saved.last?.id])
  }

  @Test func shouldKeepTheDraftWhenAnExpansionCallFails() async throws {
    let words = { (count: Int) in (1...count).map { "word\($0)" }.joined(separator: " ") + "." }
    let world = try await GenerationWorld(
      calls: [GenerationWorld.draftReply(words(40)), [.failure(.invalidRequest("refused"))], GenerationWorld.judgeReply()],
      wordTarget: WordTarget(min: 100, max: 400))
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    #expect(try await world.saved(handle.job).first?.body.body?.body == words(40))
    #expect(world.provider.requests.count == 3)
  }

  @Test func shouldAcceptAsIsOnceTheOnlyRepairIsSpentOnADifferentContradiction() async throws {
    let another = GenerationWorld.judgeReply(verdict: "contradiction", findings: [("hard", "The keeper is dead by chapter 0.")])
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.contradiction, GenerationWorld.patchReply(), another])
    let engine = try world.engine()
    let handle = try await world.generate(engine, options: GenerationOptions(maxFixes: 1))
    #expect(try await world.saved(handle.job).count == 2)
    #expect(try await world.passes().first?.verdict == "contradiction")
    #expect(try await world.lifecycle().review == .contradiction)
    #expect(world.provider.requests.count == 4)
  }

  @Test func shouldSaveTheRevisionWhenItsWriterAttemptCannotBeCaptured() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()])
    try await world.store.write { transaction in
      try transaction.database.execute(sql: "CREATE TABLE \(WriterSnapshots.table) (id BLOB NOT NULL PRIMARY KEY) STRICT, WITHOUT ROWID")
    }
    let engine = try world.engine()
    let handle = try await world.generate(engine)
    #expect(try await world.saved(handle.job).count == 1 && world.provider.requests.count == 2)
    #expect(try await world.passes().count == 1)
    let captured = try await world.store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM \(WriterSnapshots.table)") }
    #expect(captured == 0)
  }

  @Test func shouldWriteAnUnrestrictedChapterAsIsolatedProseAndWallOffItsWriterAttempts() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()], plan: GenerationWorld.plan(.unrestricted))
    let engine = try world.engine(unrestrictedAvailable: true)
    let handle = try await world.generate(engine)
    let content = try #require(try await world.saved(handle.job).first?.body.body)
    #expect(content.isolated && content.generator == .known(.unrestricted))
    #expect(try await world.passes().first?.isolated == true)
    #expect(world.provider.requests.allSatisfy { $0.model == CompactionWorld.unrestrictedModel })
    let snapshot = try #require(try await world.store.writerSnapshots(novel: world.novel, chapter: 1).first)
    #expect(snapshot.isolated)
    let view = try #require(try await world.store.writerSnapshot(snapshot.id, novel: world.novel, chapter: 1))
    #expect(view.messages == WriterSnapshots.walledOff && view.bibleHash == nil)
  }

  @Test func shouldRefuseAnUnrestrictedDraftWhoseGuidanceNamesAMinorBeforeAnythingIsSent() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply()], plan: GenerationWorld.plan(.unrestricted))
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try EntityRecord(novel: novel, entity: "pip", type: .known(.character), name: "Pip", age: 15).create(in: &transaction)
    }
    let engine = try world.engine(unrestrictedAvailable: true)
    guard case .running(let handle) = try await engine.regenerateChapter(novel: novel, chapter: 1, options: GenerationOptions(guidance: "Pip and the orgasm.")) else {
      throw EngineFixtureError(description: "not run here")
    }
    guard case .settled(.failed(let failure)) = await handle.result else {
      Issue.record("the run did not fail")
      return
    }
    #expect(failure.code == "AI_015")
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.store.generationReport(novel: novel, chapter: 1, job: handle.job) == GenerationReport(revisions: [], review: nil, judged: nil, isHead: false))
    #expect(try await world.passes().isEmpty)
  }

  @Test func shouldRunASecondGenerationOnceTheFirstHasSucceeded() async throws {
    let world = try await GenerationWorld(calls: [
      GenerationWorld.draftReply(), GenerationWorld.judgeReply(), GenerationWorld.draftReply(GenerationWorld.rewrittenBody), GenerationWorld.judgeReply(),
    ])
    let engine = try world.engine()
    let first = try await world.generate(engine)
    let second = try await world.generate(engine)
    #expect(first.job != second.job)
    let latest = try await world.saved(second.job).first?.id
    #expect(try await world.history().head == latest)
    #expect(try await world.passes().count == 2)
  }
}

@Suite("Generation pass", TestTimeLimit.quick)
struct GenerationPassTests {
  @Test func shouldCategoriseFindingsByTheirSourceAndKeepAJudgeFindingThatLooksLikeAPrefix() throws {
    let report = JudgeReport(
      verdict: .consistent, findings: [GenerationFinding(severity: .soft, text: "brief: an aside the judge wrote")],
      endingCompliance: JudgeCompliance(compliant: false, issues: []), briefCompliance: JudgeCompliance(compliant: false, issues: ["the storm never comes"]),
      readabilityCompliance: JudgeCompliance(compliant: false, issues: ["\"It was a verdict.\" — say what it is"]))
    let mechanical = [SourcedFinding(GenerationFinding(severity: .soft, text: "mechanical: 3 stock phrases"), source: .mechanics)]
    let pass = try GenerationJudgePass.compose(report, prose: "Prose.", hasContract: true, forbidden: [], mechanical: mechanical)
    #expect(pass.findings.map(\.source) == [.continuity, .brief, .readability, .mechanics])
    #expect(pass.silent == [.ending] && !pass.endingCompliant && !pass.briefCompliant && !pass.readabilityCompliant && pass.mechanicallyCompliant)
    let outcome = GenerationJudgePass.outcome(body: "Prose.", pass: pass)
    #expect(outcome.findings.map(\.category) == [.known(.continuity), .known(.brief), .known(.readability), .known(.mechanics), .known(.ending)])
    #expect(outcome.findings.map(\.text).prefix(4) == ["brief: an aside the judge wrote", "the storm never comes", "\"It was a verdict.\" — say what it is", "3 stock phrases"])
    #expect(outcome.findings.map(\.severity) == [.known(.warning), .known(.warning), .known(.warning), .known(.note), .known(.warning)])
    #expect(ChapterLifecycle.outcomeHolds(verdict: outcome.verdict, findings: outcome.findings))
  }

  @Test func shouldLeaveTheEndingOutWhenThePlanHasNoContract() throws {
    let report = JudgeReport(
      verdict: .consistent, findings: [], endingCompliance: JudgeCompliance(compliant: false, issues: ["ends early"]),
      briefCompliance: JudgeCompliance(compliant: true, issues: []))
    let pass = try GenerationJudgePass.compose(report, prose: "Prose.", hasContract: false, forbidden: [], mechanical: [])
    #expect(pass.findings.isEmpty && pass.endingCompliant && pass.readabilityCompliant)
    #expect(!ChapterLifecycle.outcomeHolds(verdict: "consistent", findings: GenerationJudgePass.outcome(body: "Prose.", pass: pass).findings))
  }
}
