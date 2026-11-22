import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Plan pipeline", TestTimeLimit.standard)
struct PlanPipelineTests {
  // plan-job.service.ts:23-27 (PLN_006)
  @Test func shouldRefuseToPlanAChapterOtherThanTheNextWritableOne() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine()
    #expect(await world.refusal(engine, chapter: 2)?.code == "PLN_006")
    let receipt = try await world.request(engine)
    #expect(receipt.chapter == 1 && !receipt.deduped)
  }

  // plan-job.service.ts:106-114 (PLN_009); action-job.service.ts:104-110 dedupes the same target
  @Test func shouldAnswerTheSamePlanWithItsJobAndRefuseASecondPlanWhileOneIsOpen() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine()
    let first = try await world.request(engine, steer: .author(PlanJobWorld.intent))
    let again = try await world.request(engine, steer: .author(PlanJobWorld.intent))
    #expect(again.deduped && again.job == first.job)
    guard case .anotherPlanRunning(let chapter) = await world.refusal(engine, steer: .author("Mara burns the lamp.")) else {
      Issue.record("a second plan was requested while one is open")
      return
    }
    #expect(chapter == 1)
  }

  @Test func shouldRequestTheNextRunOfAPlanOnceItsJobSettled() async throws {
    let world = try await PlanJobWorld(calls: 2)
    let engine = try world.engine()
    let first = try await world.request(engine)
    #expect(try await engine.run(job: first.job.ref).result == .settled(.succeeded))
    let second = try await world.request(engine)
    #expect(!second.deduped && second.job.run == 2)
  }

  // chapter-plan.service.ts:46-49 (PLN_007)
  @Test func shouldRefuseAnEmptyPlanOverAPlanAlreadyThere() async throws {
    let world = try await PlanJobWorld { novel, transaction in
      _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: ChapterPlanContent(title: "Old", body: "Mara waits.")).create(in: &transaction)
    }
    let engine = try world.engine()
    #expect(await world.refusal(engine, empty: true)?.code == "PLN_007")
  }

  @Test func shouldStageAnEmptyPlanWithNoModelCall() async throws {
    let world = try await PlanJobWorld(calls: 0)
    let engine = try world.engine()
    let receipt = try await world.request(engine, steer: .author(PlanJobWorld.intent), empty: true)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    #expect(world.provider.requests.isEmpty)
    let op = try #require(try await world.card(of: receipt.job)?.card.changeSet.first?.stored.objectValue)
    #expect(op["startedEmpty"] == .bool(true) && op["direction"] == .string(PlanJobWorld.intent) && op["body"] == .string(""))
  }

  @Test func shouldPassTheAuthorsSteerIntoThePromptAndOntoTheCard() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine()
    let receipt = try await world.request(engine, steer: .author(PlanJobWorld.intent))
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    let prompt = try #require(world.userPrompt)
    #expect(prompt.contains("THE AUTHOR'S INTENT:\n\(PlanJobWorld.intent)\n\nTHE CHOSEN DIRECTION:\n(none)"))
    let op = try #require(try await world.card(of: receipt.job)?.card.changeSet.first?.stored.objectValue)
    #expect(op["direction"] == .string(PlanJobWorld.intent))
  }

  // plan-job.service.ts:43-72, 96-103: an intent the chat called intent holds only where the author's message states it
  @Test func shouldKeepAnIntentOnlyWhereTheAuthorsMessagesInTheChatStateIt() async throws {
    let session = SchemaFixture.uuid("00000000-0000-4000-8000-0000000000c1")
    let (stated, reply) = (SchemaFixture.uuid("00000000-0000-4000-8000-0000000000d1"), SchemaFixture.uuid("00000000-0000-4000-8000-0000000000d2"))
    let world = try await PlanJobWorld { novel, transaction in
      _ = try ChatSessionRecord(id: session, novel: novel).create(in: &transaction)
      _ = try ChatMessageRecord(id: stated, novel: novel, session: session, role: .user, content: PlanJobWorld.intent, passageContexts: []).append(in: &transaction)
      _ = try ChatMessageRecord(id: reply, novel: novel, session: session, role: .assistant, content: "Shall I plan it?", passageContexts: [], answers: stated).append(
        in: &transaction)
    }
    let engine = try world.engine()
    let origin = ChapterPlanOrigin(session: session, message: reply, proposal: SchemaFixture.uuid("00000000-0000-4000-8000-0000000000e1"), opIndex: 0)
    let held = try await world.request(engine, steer: .card(intent: "She sells the lamp", direction: nil, origin: origin))
    #expect(held.droppedIntent == nil)
    let payload = try await world.store.read { transaction in try JobRecords.read(held.job.ref, in: transaction).record?.request.payload }
    #expect(payload?["intent"] == .string("She sells the lamp"))
    _ = try await engine.cancel(job: held.job.ref)
    let dropped = try await world.request(engine, steer: .card(intent: "Mara burns the lamp", direction: "Kael returns", origin: origin))
    #expect(dropped.droppedIntent == "Mara burns the lamp")
    let steered = try await world.store.read { transaction in try JobRecords.read(dropped.job.ref, in: transaction).record?.request.payload }
    #expect(steered?["intent"] == nil && steered?["direction"] == .string("Kael returns"))
  }

  // chapter-plan.service.ts:116-124; plan-job.service.ts:163-167; context-ref-resolver.ts:195-202 drops `fact:heir` though the fact is revealed and resolves
  @Test func shouldStageTheVettedPlanAsOneSessionlessCardThatWaitsOnTheAuthorAndAppliesToTheBrief() async throws {
    let world = try await PlanJobWorld { novel, transaction in
      _ = try SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", revealChapter: 1).create(in: &transaction)
    }
    let engine = try world.engine()
    let receipt = try await world.request(engine)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    let proposal = try #require(try await world.card(of: receipt.job))
    #expect(proposal.card.kind == .known(.chapterPlan) && proposal.card.session == nil && proposal.card.summary == "Plan for chapter 1")
    let op = try #require(proposal.card.changeSet.first?.stored.objectValue)
    #expect(proposal.card.changeSet.count == 1 && op["op"] == .string("brief.update"))
    #expect(op["contextRefs"] == .array([.string("entity:mara")]))
    #expect(op["claimedMilestones"] == .array([]))
    #expect(op["scenes"]?.arrayValue?.compactMap { $0["pov"] } == [.string("mara"), .null])
    #expect(op["rationale"]?.stringValue?.contains("lamp") == true)
    #expect(try await world.proposals().count == 1)

    let novel = world.novel
    let waiting = try #require(try await world.store.read { transaction in try ChatWaitingOnYou.load(novel, in: transaction) }.contents.value)
    #expect(waiting.cards.map(\.state.proposal) == [proposal.id] && waiting.cards.first?.session == ChatProposalSession.none)

    let outcome = try await world.store.applyProposal(
      proposal.id, selection: .whole, context: ProposalApplyContext(novel: novel, now: world.engineWorld.clock.now, ageGate: AgeGate(passed: true)))
    guard case .applied = outcome else {
      Issue.record("the plan card did not apply: \(outcome)")
      return
    }
    let plan = try await world.store.read { transaction in
      try ChapterPlanRecord.readHead(try ChapterPlanRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record.content
    }
    #expect(plan?.title == "The Lamp" && plan?.contextRefs == ["entity:mara"])
  }

  // chapter-plan.service.ts:102 (planAdvice re-asks once), :116 (vetPlan keeps only claimable milestones)
  @Test func shouldAdviseThePlannerOnceAndKeepOnlyTheMilestonesTheChapterCanClaim() async throws {
    let world = try await PlanJobWorld(replies: [PlanJobWorld.overclaimingText, PlanJobWorld.overclaimingText])
    let engine = try world.engine()
    let receipt = try await world.request(engine)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    #expect(world.provider.requests.count == 2)
    let repair = try #require(world.provider.requests.last?.messages.map(\.text).joined(separator: "\n"))
    #expect(repair.contains("claimedMilestones names no_such_milestone"))
    let op = try #require(try await world.card(of: receipt.job)?.card.changeSet.first?.stored.objectValue)
    #expect(op["claimedMilestones"] == .array([]))
  }

  // plan-job.service.ts:159-161 (PLN_006 at run time)
  @Test func shouldRefuseAtRunTimeWhenADraftMovedTheStoryOnWhileTheJobWaited() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine()
    let receipt = try await world.request(engine)
    try await world.writeDraft(chapter: 1)
    #expect(world.failure(try await engine.run(job: receipt.job.ref).result)?.code == "PLN_006")
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.card(of: receipt.job) == nil)
  }

  // plan-job.service.ts:29-33, 164-166 (PLN_008)
  @Test func shouldStageNothingWhenADraftMovedTheStoryOnWhileThePlanWasMade() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let receipt = try await world.request(engine)
    let handle = try await engine.run(job: receipt.job.ref)
    #expect(await handle.result == .interrupted)
    engine.relinquish()
    try await world.writeDraft(chapter: 1)
    let relaunched = try world.engine()
    let resumed = try #require(try await relaunched.resumeInterruptedAttempts().first)
    #expect(world.failure(await resumed.result)?.code == "PLN_008")
    #expect(world.provider.requests.count == 1)
    #expect(try await world.card(of: receipt.job) == nil)
  }

  // context-assembler.service.ts:644 reads isolated chapters raw for a permissive planner (chapter 1 here is the isolated draft before chapter 2)
  @Test(arguments: [ContentMode.standard, .unrestricted])
  func shouldReadAnIsolatedChapterRawOnlyForAnUnrestrictedNovel(_ mode: ContentMode) async throws {
    let marker = "Quillfeather"
    let world = try await PlanJobWorld(mode: mode) { novel, transaction in
      let content = DraftContent(body: "Mara met \(marker) by the lamp.", summary: "Mara meets \(marker).", source: .known(.generated), isolated: true)
      _ = try DraftRecord(novel: novel, chapter: 1, content: content).create(in: &transaction)
    }
    let engine = try world.engine(unrestrictedAvailable: true)
    let receipt = try await world.request(engine)
    #expect(receipt.chapter == 2)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    let sent = world.provider.requests.flatMap { $0.system.map(\.text) + $0.messages.map(\.text) }.joined(separator: "\n")
    #expect(!sent.isEmpty)
    #expect(sent.contains(marker) == (mode == .unrestricted))
  }

  /// The pack screen (OutlineLoadError.hardLine) refuses before routing: where unrestricted writing is unavailable, routing alone would refuse AI_024 instead.
  @Test(arguments: [true, false])
  func shouldRefuseAnUnrestrictedNovelsPackThatCrossesTheHardLineAndSendNothing(_ unrestrictedAvailable: Bool) async throws {
    let world = try await PlanJobWorld(mode: .unrestricted) { novel, transaction in
      _ = try EntityRecord(novel: novel, entity: "pip", type: .known(.character), name: "Pippinella", age: 9).create(in: &transaction)
      _ = try ThreadRecord(novel: novel, thread: "t", summary: "Pippinella, orgasm", status: ThreadProgress(state: .known(.open))).create(in: &transaction)
    }
    let engine = try world.engine(unrestrictedAvailable: unrestrictedAvailable)
    let receipt = try await world.request(engine)
    #expect(world.failure(try await engine.run(job: receipt.job.ref).result)?.code == "AI_015")
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.card(of: receipt.job) == nil)
  }

  @Test func shouldRefuseAnUnrestrictedNovelsPlanWhereUnrestrictedWritingIsUnavailable() async throws {
    let world = try await PlanJobWorld(mode: .unrestricted)
    let engine = try world.engine(unrestrictedAvailable: false)
    let receipt = try await world.request(engine)
    #expect(world.failure(try await engine.run(job: receipt.job.ref).result)?.code == "AI_024")
    #expect(world.provider.requests.isEmpty)
  }

  // job.service.ts:144 (JOB_002): a plan is refused while the chapter is being generated, when asked and again when it runs
  @Test func shouldRefuseAPlanWhileAGenerateJobIsOpenForTheChapter() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine()
    let receipt = try await world.request(engine)
    let generate = NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "g")
    _ = try await engine.request(generate)
    #expect(world.failure(try await engine.run(job: receipt.job.ref).result)?.code == "JOB_002")
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.card(of: receipt.job) == nil)
    #expect(await world.refusal(engine)?.code == "JOB_002")
  }

  // chapter-plan.service.ts:71-79: a plan head that became unreadable after the attempt started (the engine's pin refuses one before) reads as a plan, as
  // PlanRequests.planExists reads it
  @Test(arguments: [false, true])
  func shouldFailClosedOnAPlanHeadThatBecameUnreadableAfterTheStart(_ empty: Bool) async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine(.once(at: .committed(write: 0)))
    let receipt = try await world.request(engine, empty: empty)
    #expect(try await engine.run(job: receipt.job.ref).result == .interrupted)
    engine.relinquish()
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: ChapterPlanContent(body: "Mara waits.")).create(in: &transaction)
    }
    try await world.store.write { transaction in _ = try transaction.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 1), body: .object(["body": .int(1)])) }
    let resumed = try #require(try await world.engine().resumeInterruptedAttempts().first)
    #expect(world.failure(await resumed.result)?.code == (empty ? "PLN_007" : "plan.existing_plan_unreadable"))
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.card(of: receipt.job) == nil)
  }

  @Test func shouldDeriveOneCardIdPerJob() throws {
    let first = try JobKey(scope: "s", kind: "plan", target: "chapter:1", fingerprint: "f", run: 1)
    let second = try JobKey(scope: "s", kind: "plan", target: "chapter:1", fingerprint: "f", run: 2)
    #expect(PlanCards.id(of: first.ref) == PlanCards.id(of: first.ref))
    #expect(PlanCards.id(of: first.ref) != PlanCards.id(of: second.ref))
  }
}
