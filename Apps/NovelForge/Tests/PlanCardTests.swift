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

private struct PlanCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

/// A novel with one character whose job runtime plans through a scripted model.
@MainActor
private struct PlanWorld {
  static let intent = "She sells the lamp, and regrets it by nightfall."

  // Packages/NovelForgeKit/Tests/NovelForgeCoreTests/PlanPipeline/PlanPipelineSupport.swift: a plan the chapter-plan schema takes
  static let plan = """
    {"title":"The Lamp","objective":"Mara tests the lamp.","scenes":[{"summary":"Mara lights the lamp.","pov":"mara","goal":"See what it shows",\
    "obstacle":"The wick will not catch","turn":"It shows a door","beats":["She strikes a match"],"estimatedWords":1100}],\
    "requiredContext":["entity:mara"],"endingContract":{"hookType":"turn","emotionalBeat":"unease","openQuestion":"Where does the door lead?",\
    "handoffState":"Mara at the door"},"chapterPurpose":"Open the lamp's mystery.","readerValue":["new_information"]}
    """

  let store: VaultStore
  let novel: UUID
  let provider: ScriptedModelProvider
  let runtime: JobRuntime

  var context: NovelContext { NovelContext(store: store, novel: novel) }

  static func make(plans: Int = 1, granted: Bool = true) async throws -> PlanWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    try await store.write { transaction in
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara").create(in: &transaction)
    }
    let provider = ScriptedModelProvider(calls: Array(repeating: ScriptedModelProvider.reply(plan), count: plans))
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let consent = ConsentDisclosure.novelText
    let clock = LeaseClock(trusted: nil)
    let runtime = JobRuntime(store: store, clock: clock, power: JobPowerAssertion(activity: JobPowerAssertion.Activity(begin: { NSObject() }, end: { _ in }))) {
      () throws(JobEngineError) -> JobEngine in
      try JobEngine(
        store: store,
        router: { requestGuard in
          TaskRouter(
            configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: PlanCredentials(), store: store,
            requestGuard: requestGuard)
        }, consent: consent.requirement, clock: clock)
    }
    if granted {
      try await store.write { transaction in
        try AIConsent.decide(.granted, provider: binding.host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
      }
    }
    await runtime.launch()
    return PlanWorld(store: store, novel: novel, provider: provider, runtime: runtime)
  }

  var requester: PlanStartModel.Requester? {
    guard let engine = runtime.engine else { return nil }
    return { request async throws(ChapterPlanError) in try await engine.requestPlan(request) }
  }

  /// Plans the next chapter from Plan next chapter with the author's line, and waits for the card the job stages.
  func stagedPlan() async throws -> (PlanStartModel, UUID) {
    let model = PlanStartModel(context: context)
    let task = observing { await model.observe(now: runtime.clock.now()) }
    defer { task.cancel() }
    try await ChatWait.until("the next chapter is read") { model.state.value?.next == 1 }
    model.open()
    model.direction = Self.intent
    await model.plan(using: requester)
    #expect(model.refusal == nil && !model.isOpen)
    try await ChatWait.until("the plan card is staged") { model.state.value?.cards.count == 1 }
    return (model, try #require(model.state.value?.cards.first))
  }

  func card(_ proposal: UUID) async throws -> (ChatProposalCardModel, Task<Void, Never>) {
    let model = ChatProposalCardModel(proposal: proposal, context: context, writer: CoreChatProposalWriter(store: store))
    let task = observing { await model.observe() }
    try await ChatWait.until("the plan card loads") { model.status == .pending }
    return (model, task)
  }
}

/// Records what Plan next chapter asks for and refuses it, as a running plan would.
private final class RecordingRequester: Sendable {
  private let requests = Mutex<[ChapterPlanJobRequest]>([])

  var asked: [ChapterPlanJobRequest] { requests.withLock { $0 } }

  var requester: PlanStartModel.Requester {
    { [self] request async throws(ChapterPlanError) in
      requests.withLock { $0.append(request) }
      throw .anotherPlanRunning(chapter: request.chapter ?? 0)
    }
  }
}

@MainActor
@Suite("Plan card", TestTimeLimit.standard)
struct PlanCardTests {
  @Test func shouldReadEveryFieldOfThePlanACardProposes() throws {
    let stored: JSONValue = [
      "op": "brief.update", "chapter": 4, "title": " The Lamp ", "chapterPurpose": "Open the lamp's mystery.", "pov": "mara",
      "scenes": [
        ["summary": "Mara lights the lamp.", "pov": "mara", "goal": "See what it shows", "beats": ["She strikes a match", " "], "estimatedWords": 1100],
        ["summary": "A stranger watches.", "pov": "ghost", "estimatedWords": 900],
      ],
      "endingContract": ["hookType": "quiet_dread", "emotionalBeat": "unease", "openQuestion": "Where does the door lead?", "handoffState": "Mara at the door"],
      "claimedMilestones": ["lamp_lit"], "contextRefs": ["entity:mara", "bible_doc:world/salt-roads", "thread:the_lamp", "chapter:3"],
      "rationale": "It pays off the lamp.", "direction": "She sells the lamp", "contentMode": nil, "readerValue": ["new_information"],
    ]
    let plan = try #require(PlanCardContent([ChatOp(index: 0, stored: stored, problems: [])]))

    #expect(plan.chapter == 4 && plan.title == "The Lamp" && plan.purpose == "Open the lamp's mystery." && plan.pov == "mara")
    #expect(plan.scenes.map(\.summary) == ["Mara lights the lamp.", "A stranger watches."] && plan.scenes.map(\.pov) == ["mara", "ghost"])
    #expect(plan.scenes[0].goal == "See what it shows" && plan.scenes[0].beats == ["She strikes a match"] && plan.scenes[0].detailCount == 2)
    #expect(plan.words == 2000 && plan.roundedWords == 2000)
    #expect(plan.ending == PlanCardContent.Ending(hook: "quiet_dread", handoff: "Mara at the door", beat: "unease", question: "Where does the door lead?"))
    #expect(PlanCardContent.hookLabel("quiet_dread") == "quiet dread" && PlanCardContent.hookLabel("twist") == nil)
    #expect(plan.milestones == ["lamp_lit"] && plan.rationale == "It pays off the lamp." && plan.direction == "She sells the lamp")
    #expect(plan.contentMode == .novel && !plan.startedEmpty && !plan.isBlank && !plan.isEnding)
    #expect(plan.keptBack(chapterIsEnding: false).count == 3 && plan.keptBack(chapterIsEnding: true).count == 2)

    let labels = PlanCardLabels(names: ["mara": "Mara"], pages: ["bible_doc:world/salt-roads": "The Salt Roads"], milestones: [:])
    #expect(plan.contextRefs.map(labels.ref) == ["Mara", "The Salt Roads", "Thread: The lamp", "Chapter 3"])
    #expect(plan.scenes.compactMap(\.pov).map(labels.name) == ["Mara", "ghost"])
    #expect(labels.milestone("lamp_lit") == "Lamp lit" && PlanCardLabels.title("--") == "--")
  }

  @Test func shouldReadAnEmptyPlanAsBlankAndCardsWithoutAPlanAsNone() throws {
    let empty: JSONValue = ["op": "brief.update", "chapter": 2, "body": "", "scenes": [], "claimedMilestones": [], "startedEmpty": true]
    let plan = try #require(PlanCardContent([ChatOp(index: 0, stored: empty, problems: [])]))
    #expect(plan.startedEmpty && plan.isBlank && plan.scenes.isEmpty && plan.words == nil && plan.contentMode == nil)
    #expect(PlanCardContent([ChatOp(index: 0, stored: ["op": "brief.update", "title": "No chapter"], problems: [])]) == nil)
  }

  // plan-card.ts:391-393, PlanCard.tsx:533
  @Test func shouldNotSaveAPlanWithoutATitleOrAScene() throws {
    let plan = { (stored: JSONValue) in PlanCardContent([ChatOp(index: 0, stored: stored, problems: [])]) }
    let titleOnly = try #require(plan(["op": "brief.update", "chapter": 1, "title": "The Lamp", "scenes": [["summary": " ", "pov": "mara"]]]))
    let scenesOnly = try #require(plan(["op": "brief.update", "chapter": 1, "title": "  ", "scenes": [["summary": "Mara lights the lamp."]]]))
    let blankSummary = try #require(plan(["op": "brief.update", "chapter": 1, "title": "The Lamp", "scenes": [["summary": "\n\t "]]]))
    let whole = try #require(plan(["op": "brief.update", "chapter": 1, "title": "The Lamp", "scenes": [["summary": "Mara lights the lamp."]]]))
    for blank in [titleOnly, scenesOnly, blankSummary] {
      #expect(blank.isBlank && !PlanCardContent.canSave(blank, canApply: true))
    }
    #expect(!whole.isBlank && PlanCardContent.canSave(whole, canApply: true) && !PlanCardContent.canSave(whole, canApply: false))
    #expect(!PlanCardContent.canSave(nil, canApply: true))
  }

  @Test func shouldRoundTheLengthToTheNearestHundred() throws {
    let plan = { (words: Int64) in
      PlanCardContent([ChatOp(index: 0, stored: ["op": "brief.update", "chapter": 1, "scenes": [["summary": "A", "estimatedWords": .int(words)]]], problems: [])])
    }
    let (down, up) = (try #require(plan(1149)), try #require(plan(1150)))
    #expect(down.roundedWords == 1100 && up.roundedWords == 1200)
  }

  @Test func shouldNameKeysItCannotReadFromTheKeyAndNothingWhileNamesAreUnavailable() {
    let labels = PlanCardLabels(names: ["mara": "Mara"], pages: ["entity:hall": "Saltgate Hall"])
    #expect(labels.ref("entity:old_friend") == "Old friend" && labels.ref("entity:hall") == "Saltgate Hall" && labels.name("hall") == "hall")
    #expect(PlanCardLabels.title("  the__salt -.roads \n inn ") == "The salt roads inn")
    let unavailable = PlanCardLabels(names: ["mara": "Mara"], isUnavailable: true)
    let shown = [unavailable.name("mara"), unavailable.ref("entity:mara"), unavailable.milestone("lamp_lit")]
    #expect(shown == Array(repeating: PlanCardLabels.unavailable, count: 3))
  }

  // chat-view.ts:625-629
  @Test func shouldWaitForAnAnswerOnlyWhileForgesNewestReplyAsksAndTheAuthorHasNotWrittenSince() {
    let author = { (position: Int) in ChatTurnMark(position: position, isAuthor: true, asks: nil) }
    let reply = { (position: Int, asks: Bool) in ChatTurnMark(position: position, isAuthor: false, asks: asks) }
    #expect(PlanStart.awaitsAnswer(marks: [author(1), reply(2, true)]))
    #expect(!PlanStart.awaitsAnswer(marks: [author(1), reply(2, true), author(3)]))
    #expect(!PlanStart.awaitsAnswer(marks: [reply(1, true), reply(2, false)]))
    #expect(!PlanStart.awaitsAnswer(marks: [author(1)]) && !PlanStart.awaitsAnswer(marks: []))
  }

  @Test func shouldHideTheChipWhileTheNextChapterIsBeingPlanned() async throws {
    let world = try await PlanWorld.make(plans: 0, granted: false)
    let model = PlanStartModel(context: world.context)
    let task = observing { await model.observe(now: world.runtime.clock.now()) }
    defer { task.cancel() }
    try await ChatWait.until("the next chapter is read") { model.state.value?.next == 1 }
    let idle = try #require(model.state.value)
    #expect(idle.offersChip(isBusy: false) && !idle.offersChip(isBusy: true))

    await model.plan(using: world.requester)
    #expect(model.refusal == nil)
    try await ChatWait.until("the plan waits to start") { model.state.value?.isPlanning == true }
    let planning = try #require(model.state.value)
    #expect(!planning.offersChip(isBusy: false) && planning.jobs.count == 1 && !planning.jobsUnavailable)
  }

  // ChatPlanCard.tsx:60
  @Test func shouldKeepTheEndingBackUnlessTheChaptersSavedPlanIsTheEnding() async throws {
    let world = try await PlanWorld.make(plans: 0)
    let novel = world.novel
    try await world.store.write { transaction in
      let content = ChapterPlanContent(body: "The last night.", contract: ChapterContract(isEnding: true))
      _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: content).create(in: &transaction)
    }
    let (ending, other) = try await world.store.read { transaction in
      (try PlanCardLabels.load(novel: novel, chapter: 1, in: transaction), try PlanCardLabels.load(novel: novel, chapter: 2, in: transaction))
    }
    #expect(ending.chapterIsEnding && !other.chapterIsEnding && ending.names == ["mara": "Mara"] && !ending.isUnavailable)
    let plan = try #require(PlanCardContent([ChatOp(index: 0, stored: ["op": "brief.update", "chapter": 1, "title": "The Last Night"], problems: [])]))
    #expect(plan.keptBack(chapterIsEnding: ending.chapterIsEnding).count == 2 && plan.keptBack(chapterIsEnding: other.chapterIsEnding).count == 3)
  }

  @Test func shouldOpenOnlyAPlanCardThatHasNoChatFromWaitingOnYou() {
    let (withChat, withoutChat, chat) = (UUID(), UUID(), UUID())
    let cards = ChatTrayCards(
      cards: [
        ChatTrayCard(proposal: withChat, session: .live(chat), title: "Plan for chapter 1", conflicts: nil, isPlan: true),
        ChatTrayCard(proposal: withoutChat, session: .none, title: "Plan for chapter 1", conflicts: nil, isPlan: true),
      ], actions: [])
    let items = ChatTrayItem.items(ChatTraySnapshot(cards: .available(cards), lasts: []), activities: [:])
    #expect(items.map(\.isPlan) == [false, true])
  }

  @Test func shouldAskForTheNextChapterWithTheAuthorsLineAsTheSteer() async throws {
    let world = try await PlanWorld.make(plans: 0)
    let model = PlanStartModel(context: world.context)
    let task = observing { await model.observe(now: world.runtime.clock.now()) }
    defer { task.cancel() }
    try await ChatWait.until("the next chapter is read") { model.state.value?.next == 1 }
    let recording = RecordingRequester()

    model.open()
    model.direction = "  \(PlanWorld.intent)\n"
    await model.plan(using: recording.requester)
    model.direction = " \n"
    await model.plan(using: recording.requester)

    #expect(
      recording.asked == [
        ChapterPlanJobRequest(novel: world.novel, chapter: 1, steer: .author(PlanWorld.intent)),
        ChapterPlanJobRequest(novel: world.novel, chapter: 1, steer: .none),
      ])
    #expect(model.isOpen && model.direction == " \n")
    #expect(model.refusal == PresentedError(headline: try #require(JobsErrors.headline(code: "PLN_009")), detail: "PLN_009"))

    await model.plan(using: nil)
    #expect(model.refusal == JobsErrors.notRunningHere)
  }

  @Test func shouldGiveEveryRefusalOfAPlanAHeadline() {
    let generic = String(localized: "Something went wrong.", table: "PlanCard")
    let refusals: [ChapterPlanError] = [
      .notNextChapter(chapter: 3, next: 2), .alreadyPlanned(chapter: 2), .anotherPlanRunning(chapter: 2), .chapterBeingWritten(chapter: 2), .chaptersUnavailable,
      .jobsUnavailable, .steeringUnavailable,
    ]
    for refusal in refusals {
      let presented = PlanCardErrors.presented(refusal)
      #expect(presented.headline != generic && presented.detail == refusal.code, "\(refusal.code)")
    }
    #expect(refusals.prefix(4).map(\.code) == ["PLN_006", "PLN_007", "PLN_009", "JOB_002"])
    let unrestricted = JobsErrors.failure(AttemptFailure(code: "AI_024", message: "Unrestricted writing is unavailable"))
    #expect(unrestricted == PlanCardErrors.headline(code: "AI_024") && unrestricted != String(localized: "The job didn't finish.", table: "Jobs"))
  }

  @Test func shouldPlanTheNextChapterThenSaveTheCardAsItsBrief() async throws {
    let world = try await PlanWorld.make()
    let (start, proposal) = try await world.stagedPlan()
    let prompt = try #require(world.provider.requests.first?.messages.first { $0.role == .user }?.text)
    #expect(prompt.contains("THE AUTHOR'S INTENT:\n\(PlanWorld.intent)"))

    let tray = try await world.store.read { transaction in try ChatTraySnapshot.load(novel: world.novel, in: transaction) }
    let waiting = ChatTrayItem.items(tray, activities: [:]).first { $0.target == .proposal(proposal) }
    #expect(waiting?.session == ChatProposalSession.none && waiting?.title == "Plan for chapter 1" && waiting?.isPlan == true)

    let (card, task) = try await world.card(proposal)
    defer { task.cancel() }
    let plan = try #require(PlanCardContent(card.ops))
    #expect(plan.title == "The Lamp" && plan.direction == PlanWorld.intent && plan.scenes.first?.pov == "mara" && plan.contextRefs.contains("entity:mara"))
    #expect(card.canSavePlan)

    await card.apply()
    try await ChatWait.until("the plan is saved") { card.status == .applied }
    let ref = try ChapterPlanRecord.ref(novel: world.novel, chapter: 1)
    let saved = try await world.store.read { transaction in try ChapterPlanRecord.readHead(ref, in: transaction).entry?.record.content }
    #expect(saved?.title == "The Lamp" && saved?.chapterPurpose == "Open the lamp's mystery.")

    let reading = observing { await start.observe(now: world.runtime.clock.now()) }
    defer { reading.cancel() }
    try await ChatWait.until("the saved plan leaves the waiting cards") { start.state.value?.cards == [] }
    #expect(start.cards == [proposal])
  }

  @Test func shouldRefuseAPlanCardTheStoryMovedPastWithItsHeadline() async throws {
    let world = try await PlanWorld.make()
    let (_, proposal) = try await world.stagedPlan()
    let novel = world.novel
    _ = try await world.store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "The tide came in."), base: nil, at: Date(), in: &transaction)
    }
    let (card, task) = try await world.card(proposal)
    defer { task.cancel() }

    await card.apply()

    let notice = try #require(card.notice)
    #expect(notice.error.detail == "PLN_008" && card.status == .pending)
    #expect(PlanCardErrors.notice(notice).title == String(localized: "The story has moved on", table: "PlanCard"))
  }

  @Test func shouldSayAnActionThatCannotRunIsNotYetAvailable() {
    let bundle = Bundle(for: JobRuntime.self)
    let read = { (key: String) in bundle.localizedString(forKey: key, value: "missing", table: "ChatCards") }
    #expect(read("Not yet available.") == "Not yet available." && read("This step isn't available yet.") == "This step isn't available yet.")
    #expect(read("Available with chapters.") == "missing" && read("This step becomes available with chapters.") == "missing")
  }
}
