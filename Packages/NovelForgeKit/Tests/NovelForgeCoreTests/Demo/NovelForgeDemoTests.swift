import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Novel Forge demo", TestTimeLimit.standard)
struct NovelForgeDemoTests {
  private static let consent = AIConsentRequirement(dataClass: "novel", disclosure: "novel-text/v1")

  private static let schemas: [String: OrderedJSON] = [
    chapterPlanSchemaName: chapterPlanCallSchema, chapterGenerationSchemaName: chapterGenerationSchema, chapterExpandSchemaName: chapterExpandSchema,
    chapterTitleSchemaName: chapterTitleSchema,
    editorialReviewSchemaName: editorialReviewSchema, continuitySchemaName: continuitySchema, canonRefreshSchemaName: canonRefreshConstrainedSchema,
    chapterSummarizeSchemaName: chapterSummarizeSchema, chatTitleSchemaName: chatTitleSchema, chatCompactSchemaName: chatCompactSchema,
    chatRefineSchemaName: chatRefineSchema,
  ]

  @Test("should seed the sample novel with its Story Bible, outline and chapter 1 brief once")
  func shouldSeedTheSampleNovelOnce() async throws {
    let store = try NovelForgeStore.openInMemory()

    try await NovelForgeDemo.seed(in: store)
    try await NovelForgeDemo.seed(in: store)

    let novel = NovelForgeDemo.novel
    let (novels, entities, plan) = try await store.read { transaction in
      (
        try LibraryList.load((), in: transaction).novels.map(\.novel.id),
        try transaction.states(ofKind: EntityRecord.kind.entityKind).count,
        try ChapterPlanRecord.history(try ChapterPlanRecord(novel: novel, chapter: 1, content: NovelForgeDemo.firstBrief).key.ref, in: transaction).history?.head
      )
    }
    #expect(novels == [novel])
    #expect(entities == 4)
    #expect(plan != nil)
  }

  @Test("should script a reply its real schema accepts for every structured call the demo answers")
  func shouldScriptValidStructuredReplies() throws {
    for rule in NovelForgeDemo.script.rules {
      guard let name = rule.match.schema else { continue }
      let schema = try #require(Self.schemas[name], "no schema known for \(name)")
      for case .json(let reply) in rule.replies {
        let issues = StructuredSchema.validate(CanonicalJSON.encode(reply), against: JSONValue(schema: schema))
        #expect(issues.isEmpty, "\(name): \(issues)")
      }
      #expect(!rule.replies.isEmpty)
    }
  }

  @Test("should answer the text-mode judge with a report the judge schema and parser accept")
  func shouldScriptAValidJudgeReport() throws {
    guard case .json(let reply)? = NovelForgeDemo.judgeRule.replies.first else { throw DemoTestError.missing("the judge reply") }
    let text = String(decoding: CanonicalJSON.encode(reply), as: UTF8.self)

    #expect(StructuredSchema.validate(Data(text.utf8), against: JSONValue(schema: chapterJudgeSchema)).isEmpty)
    #expect(throws: Never.self) { try JudgeReport.parse(text) }
  }

  @Test("should answer a chat message by what it asks, and anything else with the next general reply")
  func shouldAnswerChatFromTheScript() async throws {
    let world = try await DemoWorld()
    let session = try await world.store.createChatSession(novel: NovelForgeDemo.novel)
    let engine = ChatTurnEngine(store: world.store, router: { world.router(nil) }, consent: Self.consent, ageGate: AgeGate(passed: false))

    let general = try await world.reply(to: "Hello there", in: session.id, engine: engine)
    #expect(general.hasPrefix("Happy to help with The Salt Clock."), "\(general)")

    for (message, opening) in [
      ("What should happen next?", "Chapter 1 is briefed"), ("Tell me about the cast", "Ines is the heart of it"),
      ("Should the reader know the culprit yet?", "Keep the answer off the page"), ("Let us brainstorm the middle of the book", "Three directions"),
    ] {
      let reply = try await world.reply(to: message, in: session.id, engine: engine)
      #expect(reply.hasPrefix(opening), "\(message): \(reply)")
    }
  }

  @Test("should plan chapter 2, write and check chapter 1 and take it through approval, finalize and the Story Bible refresh with the demo model alone")
  func shouldWriteAFirstChapterEndToEnd() async throws {
    let world = try await DemoWorld()

    let generated = try await world.engine.generateChapter(novel: NovelForgeDemo.novel, chapter: 1)
    guard case .running(let handle) = generated else { throw DemoTestError.missing("a generation run here") }
    #expect(await handle.result == .settled(.succeeded))
    let draft = try #require(try await world.draftHead())
    #expect(draft.body.body?.body == NovelForgeDemo.firstChapter)
    #expect(draft.body.body?.title == NovelForgeDemo.firstChapterTitle)

    for kind in [ChapterReviewKind.judge, .editorial] {
      guard case .running(let review) = try await world.engine.requestReview(novel: NovelForgeDemo.novel, chapter: 1, kind: kind) else {
        throw DemoTestError.missing("a \(kind.rawValue) review run here")
      }
      #expect(await review.result == .settled(.succeeded))
    }

    _ = try await world.store.approveChapter(novel: NovelForgeDemo.novel, chapter: 1, revision: draft.id)
    #expect(try await world.chapter()?.approved == true)

    try await world.settle(try #require(try await world.store.finalizeReviewJob(novel: NovelForgeDemo.novel, chapter: 1)))
    #expect(try await world.chapter()?.status == "final", "the scripted continuity read leaves only routine updates, so the finalize review finalizes the chapter")
    try await world.settle(try #require(try await world.job(.canonRefresh)))
    #expect(try await world.proposals() == 1)

    let receipt = try await world.engine.requestPlan(ChapterPlanJobRequest(novel: NovelForgeDemo.novel))
    try await world.settle(receipt.job.ref)
    #expect(try await NovelEvaluation.applyPlanCard(of: receipt.job.ref, novel: NovelForgeDemo.novel, in: world.store, now: Date()))
    let plan = try #require(try await world.planHead(chapter: 2))
    #expect(plan.body.body?.title == NovelForgeDemo.secondChapterTitle)
    #expect(try await world.ledgerIsDemoOnly())
  }
}

private enum DemoTestError: Error {
  case missing(String)
}

private struct DemoWorld {
  let store: VaultStore
  let engine: JobEngine
  let router: @Sendable ((@Sendable (ModelRoute) -> ModelRequestGuard?)?) -> TaskRouter

  init() async throws {
    let store = try NovelForgeStore.openInMemory()
    try await NovelForgeDemo.seed(in: store)
    let consent = AIConsentRequirement(dataClass: "novel", disclosure: "novel-text/v1")
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: DemoModelProvider.host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
    }
    let provider = DemoModelProvider(script: NovelForgeDemo.script, pace: .zero)
    let router: @Sendable ((@Sendable (ModelRoute) -> ModelRequestGuard?)?) -> TaskRouter = { requestGuard in
      TaskRouter(
        configuration: TaskRouterConfiguration(provider: .demo), demo: provider, credentials: NoDemoCredentials(), store: store,
        requestGuard: requestGuard ?? { _ in nil })
    }
    engine = try JobEngine(store: store, router: { router($0) }, consent: consent, clock: LeaseClock(trusted: nil), ageGate: AgeGate(passed: false))
    self.store = store
    self.router = router
  }

  func reply(to message: String, in session: UUID, engine: ChatTurnEngine) async throws -> String {
    let handle = try await engine.send(message, session: session, novel: NovelForgeDemo.novel)
    guard case .answered(let reply) = await handle.outcome() else { throw DemoTestError.missing("a reply to \(message)") }
    return try await store.read { transaction in try #require(try ChatMessageRecord.read(id: reply, in: transaction).entry?.record.content) }
  }

  func settle(_ job: EntityRef) async throws {
    let handle = try await engine.run(job: job)
    let result = await handle.result
    #expect(result == .settled(.succeeded), "\(job.key.rawValue) ended \(result)")
  }

  func draftHead() async throws -> RevisionEntry<DraftContent>? {
    let ref = try DraftRecord.ref(novel: NovelForgeDemo.novel, chapter: 1)
    return try await store.read { transaction in try DraftRecord.history(ref, in: transaction).history.flatMap { history in history.revisions.first { $0.id == history.head } } }
  }

  func planHead(chapter: Int) async throws -> RevisionEntry<ChapterPlanContent>? {
    let ref = try ChapterPlanRecord(novel: NovelForgeDemo.novel, chapter: chapter, content: ChapterPlanContent(body: "")).key.ref
    return try await store.read { transaction in
      try ChapterPlanRecord.history(ref, in: transaction).history.flatMap { history in history.revisions.first { $0.id == history.head } }
    }
  }

  func chapter() async throws -> EvaluationChapter? {
    try await NovelEvaluation.chapters(novel: NovelForgeDemo.novel, in: store).chapters.first { $0.chapter == 1 }
  }

  func job(_ kind: NovelJobKind) async throws -> EntityRef? {
    let scope = NovelJobAddress.scope(of: NovelForgeDemo.novel)
    return try await store.read { transaction in
      try transaction.states(ofKind: JobSchema.jobKind).compactMap { JobRecords.reading($0.state, of: $0.ref).record }
        .first { $0.request.key.scope == scope && $0.request.key.kind == kind.rawValue }?.ref
    }
  }

  func proposals() async throws -> Int {
    try await store.read { transaction in try transaction.states(ofKind: ProposalRecord.kind.entityKind).count }
  }

  func ledgerIsDemoOnly() async throws -> Bool {
    let entries = try await store.read { transaction in try Ledger.entries(in: transaction) }
    return !entries.isEmpty && entries.allSatisfy(\.isDemo)
  }
}

private struct NoDemoCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? { nil }
}
