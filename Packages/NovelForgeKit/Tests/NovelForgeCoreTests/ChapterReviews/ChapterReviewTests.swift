import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Chapter reviews", TestTimeLimit.standard)
struct ChapterReviewTests {
  @Test func shouldStoreAJudgeContradictionThatHoldsTheChapterUntilTheAuthorAnswersIt() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction])
    let engine = try world.engine()
    let attempt = try await world.review(engine, .judge)

    let latest = try await world.latest(.judge)
    let review = latest.review
    #expect(review.id == attempt.uuid && review.attempt == attempt)
    #expect(review.disposition == .known(.blocking) && review.verdict == "contradiction")
    #expect(review.findings.map(\.id) == ["f1"] && review.findings.first?.severity == .known(.blocking))
    #expect(review.checked.contains("continuity with the Story Bible") && review.checked.contains("1 secret kept from the reader"))
    #expect(!review.isolated && !latest.stale)
    #expect(Set(review.calls ?? []) == Set(try await world.base.ledgerIDs()))
    #expect(review.bodyHash == hashReviewedBody(ReviewWorld.body))
    #expect(latest.openBlocking == 1)
    let held = try await world.lifecycle()
    #expect(held.review == .contradiction && held.judge == review.id && held.openBlocking == 1)
    let sent = try #require(world.provider.requests.first)
    let task = try #require(sent.messages.last?.text)
    #expect(task.hasPrefix("---\nDraft prose to evaluate:\n\(ReviewWorld.body)"))
    #expect(task.hasSuffix("Return a JSON object with verdict (\"consistent\" or \"contradiction\") and findings array."))
    #expect(!sent.messages.contains { $0.text.contains("matching this JSON schema") })
    #expect(sent.messages.contains { $0.text.hasPrefix("Context:\n") })
    switch sent.format {
    case .text: break
    case .json(let name, _): #expect(name == "judge")
    }

    try await world.store.setReviewRemedy(novel: world.novel, chapter: 1, review: review.id, finding: "f1", action: .overridden)
    let answered = try await world.lifecycle()
    #expect(answered.review == .needsReview && answered.openBlocking == 0)
    #expect(try await world.latest(.judge).openBlocking == 0)
  }

  @Test func shouldTakeAnApprovalOutOfForceWhenABlockingJudgeReviewHoldsTheChapter() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction])
    let engine = try world.engine()
    let novel = world.novel
    let head = try #require(try await world.lifecycle().draft)
    try await world.store.approveChapter(novel: novel, chapter: 1, revision: head)
    #expect(try await world.lifecycle().review == .approved)

    let attempt = try await world.review(engine, .judge)
    let held = try await world.lifecycle()
    #expect(held.review == .contradiction && held.approval == nil)

    try await world.store.setReviewRemedy(novel: novel, chapter: 1, review: attempt.uuid, finding: "f1", action: .dismissed, reason: "her leg healed off-page")
    let dismissed = try await world.lifecycle()
    #expect(dismissed.review == .needsReview && dismissed.approval == nil && dismissed.openBlocking == 0)
  }

  @Test func shouldAskOnceMoreWithTheSameRequestThenStoreAFailedReview() async throws {
    let world = try await ReviewWorld(
      calls: [ScriptedModelProvider.reply("no verdict here"), ScriptedModelProvider.reply("still nothing"), ReviewWorld.contradiction])
    let engine = try world.engine()
    _ = try await world.review(engine, .judge)
    let review = try await world.latest(.judge).review
    #expect(review.disposition == .known(.failed) && review.verdict == "evaluation_failed")
    #expect(review.findings.first?.text == "The judge’s answer could not be read, so nothing was checked — run the review again.")
    #expect(review.calls?.count == 2 && world.provider.requests.count == 2)
    #expect(world.provider.requests[0] == world.provider.requests[1])
  }

  @Test func shouldReAskWhenAContradictionNamesNoHardFinding() async throws {
    let soft = ReviewWorld.judgeReply(findings: [("soft", "A small wrinkle.")])
    let world = try await ReviewWorld(calls: [soft, ReviewWorld.contradiction])
    let engine = try world.engine()
    _ = try await world.review(engine, .judge)
    let review = try await world.latest(.judge).review
    #expect(review.verdict == "contradiction" && review.disposition == .known(.blocking))
    #expect(world.provider.requests.count == 2)
  }

  @Test func shouldStoreEditorialFindingsWithEvidenceFoundInTheProse() async throws {
    let reply: JSONValue = [
      "disposition": "revision_requested", "note": " Tighten the ending. ",
      "findings": [["severity": "blocking", "text": "The torn page is never explained.", "evidence": "its last page torn away"]],
      "proofreading": [["kind": "spelling", "quote": "found teh logbook", "fix": "found the logbook"]],
    ]
    let world = try await ReviewWorld(calls: [ReviewWorld.reply(reply)])
    let engine = try world.engine()
    _ = try await world.review(engine, .editorial)
    let review = try await world.latest(.editorial).review
    #expect(review.verdict == "revision_requested" && review.note == "Tighten the ending.")
    #expect(review.disposition == .known(.blocking))
    #expect(review.findings.map(\.category) == [.known(.editorial), .known(.proofreading)])
    #expect(review.findings.first?.evidence == "its last page torn away")
    #expect(review.findings.last?.text == "Spelling: “found teh logbook” → “found the logbook”")
    #expect(review.checked == ["canon", "prose against the established style", "grammar, spelling, punctuation, tense, point of view, names and references"])
    let sent = try #require(world.provider.requests.first?.messages.last?.text)
    #expect(sent.contains("Chapter brief:\n(no plan was written for this chapter)\n\nChapter draft:\n\(ReviewWorld.body)"))
  }

  @Test func shouldRunMechanicsAndReadabilityWithoutAModel() async throws {
    let world = try await ReviewWorld()
    let engine = try world.engine()
    guard case .reviewed(let mechanics) = try await engine.requestReview(novel: world.novel, chapter: 1, kind: .mechanics) else {
      Issue.record("mechanics ran as a job")
      return
    }
    let readability = try await world.store.reviewChapter(novel: world.novel, chapter: 1, kind: .readability)
    #expect(world.provider.requests.isEmpty)
    let list = try await world.reviews()
    #expect(list.latest.map(\.review.id) == [mechanics, readability])
    let stored = try #require(list.latest.first?.review)
    #expect(stored.reviewKind == .known(.mechanics) && stored.checked.contains("stock phrases") && stored.calls == nil && stored.job == nil)
    #expect(list.latest.last?.review.findings.first?.text == "The chapter is under 400 words — too short to measure readability.")
    await #expect(throws: ChapterReviewError.runsAsJob(.judge)) {
      _ = try await world.store.reviewChapter(novel: world.novel, chapter: 1, kind: .judge)
    }
  }

  @Test func shouldRefuseAReviewOfAChapterWithNoProseOrOneBeingGenerated() async throws {
    let world = try await ReviewWorld(body: "  ")
    let engine = try world.engine()
    await #expect(throws: ChapterReviewError.nothingToReview(1)) {
      _ = try await world.store.reviewChapter(novel: world.novel, chapter: 1, kind: .mechanics)
    }
    try await world.draft(ReviewWorld.body)
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "g"))
    do {
      _ = try await engine.requestReview(novel: world.novel, chapter: 1, kind: .judge)
      Issue.record("a review started while the chapter was being generated")
    } catch {
      #expect(error.code == "REV_007")
    }
    #expect(world.provider.requests.isEmpty)
  }

  @Test func shouldMarkAReviewIsolatedWhenItRanUnrestrictedOrReadIsolatedProse() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction])
    let engine = try world.engine(unrestrictedAvailable: true)
    _ = try await world.review(engine, .judge, unrestricted: true)
    #expect(try await world.latest(.judge).review.isolated)
    #expect(world.provider.requests.first?.model == CompactionWorld.unrestrictedModel)

    let standard = try await world.store.reviewChapter(novel: world.novel, chapter: 1, kind: .readability)
    let raised = try await world.store.reviewChapter(novel: world.novel, chapter: 1, kind: .mechanics, unrestricted: true)
    try await world.draft(ReviewWorld.body + " The lamp went out.", isolated: true)
    let walled = try await world.store.reviewChapter(novel: world.novel, chapter: 1, kind: .readability)
    let isolated = Dictionary(uniqueKeysWithValues: try await world.reviews().history.map { ($0.review.id, $0.review.isolated) })
    #expect(isolated[standard] == false && isolated[raised] == true && isolated[walled] == true)
  }

  @Test func shouldRefuseAnUnrestrictedReviewWhereThisBuildCannotRouteIt() async throws {
    let world = try await ReviewWorld()
    let engine = try world.engine()
    do {
      _ = try await engine.requestReview(novel: world.novel, chapter: 1, kind: .judge, unrestricted: true)
      Issue.record("an unrestricted review was requested in a build without unrestricted writing")
    } catch {
      #expect(error.code == "AI_024")
    }
  }

  @Test func shouldFingerprintTheBodyTheRaiseAndThePaceUnderOneRevision() {
    let one = ReviewSource(draftRevision: "r1", body: "One.", isolated: false, final: true)
    let two = ReviewSource(draftRevision: "r1", body: "Two.", isolated: false, final: true)
    let standard = ReviewJobPayload(kind: "judge", revision: "r1", unrestricted: false, pace: nil)
    let prints = [
      standard.fingerprint(source: one), standard.fingerprint(source: two),
      ReviewJobPayload(kind: "judge", revision: "r1", unrestricted: true, pace: nil).fingerprint(source: one),
      ReviewJobPayload(kind: "judge", revision: "r1", unrestricted: false, pace: .meticulous).fingerprint(source: one),
      ReviewJobPayload(kind: "editorial", revision: "r1", unrestricted: false, pace: nil).fingerprint(source: one),
    ]
    #expect(Set(prints).count == prints.count)
  }

  @Test func shouldReviewAFinalChapterAgainAfterItIsAmendedUnderTheSameRevision() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction, ReviewWorld.contradiction])
    let engine = try world.engine()
    let novel = world.novel
    try await world.store.write { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    let first = try await world.review(engine, .judge)
    try await world.store.writeDomain { transaction throws(DomainError) in
      try FinalChapters.amend(novel: novel, chapter: 1, ChapterAmendment(content: "Final 1, amended."), in: &transaction)
    }
    let second = try await world.review(engine, .judge)
    let history = try await world.reviews().history.map(\.review)
    #expect(history.map(\.id) == [second.uuid, first.uuid])
    #expect(history[0].job != history[1].job && history[0].draftRevision == history[1].draftRevision)
    #expect(history[0].bodyHash == hashReviewedBody("Final 1, amended.") && history[1].bodyHash == hashReviewedBody("Final 1."))
    #expect(world.provider.requests.count == 2)
  }

  @Test func shouldFailAReviewJobWhoseChapterStartedGeneratingBeforeItRan() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction])
    let engine = try world.engine()
    let novel = world.novel
    let read = try await world.store.reviewRead { transaction throws(ChapterReviewError) in try ChapterReviews.source(novel: novel, chapter: 1, in: transaction) }
    let source = try #require(read)
    let payload = ReviewJobPayload(kind: ChapterReviewKind.judge.rawValue, revision: source.draftRevision, unrestricted: false, pace: nil)
    let job = try await engine.request(
      NovelJobRequest(kind: .review, novel: novel, chapter: 1, fingerprint: payload.fingerprint(source: source), payload: payload.json))
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: novel, chapter: 1, fingerprint: "g"))
    let handle = try await engine.run(job: job.ref)
    guard case .settled(.failed(let failure)) = await handle.result else {
      Issue.record("the review job did not fail")
      return
    }
    #expect(failure.code == "REV_007")
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.reviews().history.isEmpty)
  }

  @Test func shouldRunOneJobOneReviewAndOneRequestWhenAskedTwiceAtOnce() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction, ReviewWorld.contradiction])
    let engine = try world.engine()
    async let first = engine.requestReview(novel: world.novel, chapter: 1, kind: .judge)
    async let second = engine.requestReview(novel: world.novel, chapter: 1, kind: .judge)
    let (one, two) = try await (first, second)
    guard case .running(let a) = one, case .running(let b) = two else {
      Issue.record("not both running here: \(one) \(two)")
      return
    }
    #expect(await a.result == .settled(.succeeded))
    _ = await b.result
    #expect(a.job == b.job && a.attempt == b.attempt)
    #expect(try await world.reviews().history.count == 1)
    #expect(world.provider.requests.count == 1)
  }

  @Test func shouldStartOneNewRunWhenAStoredReviewIsAskedForTwiceAtOnce() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction, ReviewWorld.contradiction, ReviewWorld.contradiction])
    let engine = try world.engine()
    let stored = try await world.review(engine, .judge)
    async let first = engine.requestReview(novel: world.novel, chapter: 1, kind: .judge)
    async let second = engine.requestReview(novel: world.novel, chapter: 1, kind: .judge)
    let (one, two) = try await (first, second)
    guard case .running(let a) = one, case .running(let b) = two else {
      Issue.record("not both running here: \(one) \(two)")
      return
    }
    #expect(await a.result == .settled(.succeeded))
    _ = await b.result
    #expect(a.job == b.job && a.attempt == b.attempt && a.attempt != stored)
    let job = a.job
    let snapshot = try #require(try await world.store.read { transaction in try JobSnapshot.load(job, in: transaction) })
    #expect(snapshot.job.request.key.run == 2 && snapshot.attempts.count == 1)
    #expect(try await world.reviews().history.count == 2)
    #expect(world.provider.requests.count == 2)
  }
}
