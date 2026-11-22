import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import SwiftUI
import Synchronization
import Testing

@testable import NovelForge

private struct PendingCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

/// What the finalize review's continuity read answers: one unsure update and two routine ones (finalize-review.service.spec.ts:12-28).
nonisolated private enum PendingScript {
  static let prose = "Mira climbs the tower and the lamp burns cold."

  static let extraction: JSONValue = [
    "appeared": ["mira"], "newEntities": [], "threads": [["threadKey": "lamp_debt", "status": "closed", "summary": "Mira repays the keeper"]], "mysteries": [],
    "timeline": [], "relationships": [], "power": [], "characterStates": [["entityKey": "mira", "location": "the tower", "evidence": "Mira climbs the tower"]],
    "knowledgeChanges": [], "chapterSummary": "Mira climbs.", "milestones": [],
  ]
}

/// Records each start the runtime is asked for, by call, and refuses it, so nothing runs.
private final class StartLog: Sendable {
  private let calls = Mutex<[String]>([])

  var all: [String] { calls.withLock { $0 } }

  func starter(_ name: String) -> JobEngineCalls.Start {
    { [self] _, job throws(JobEngineError) in
      calls.withLock { $0.append("\(name) \(job.key.rawValue)") }
      throw .pipelineNotYetAvailable(.generate)
    }
  }
}

/// A novel with Mira in its Story Bible and, on a vault of its own, a job engine no runtime drains whose model answers one finalize review's read.
@MainActor
private struct PendingWorld {
  static let studio = ReplicaID(UUID(uuidString: "0192d5a0-0000-7000-8000-0000000000c1") ?? UUID())

  let store: VaultStore
  let novel: UUID
  let engine: JobEngine?
  let clock = LeaseClock(trusted: nil)

  var context: NovelContext { NovelContext(store: store, novel: novel) }

  static func make(store existing: VaultStore? = nil, novel existingNovel: UUID? = nil) async throws -> PendingWorld {
    let store = try existing ?? NovelForgeStore.openInMemory()
    let novel: UUID
    if let existingNovel {
      novel = existingNovel
    } else {
      novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    }
    _ = try await store.writeDomain { transaction throws(DomainError) in
      try Entities.create(novel: novel, entity: "mira", type: .character, name: "Mira", in: &transaction)
    }
    guard existing == nil else { return PendingWorld(store: store, novel: novel, engine: nil) }
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(PendingScript.extraction), as: UTF8.self))])
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let consent = ConsentDisclosure.novelText
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: binding.host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
    }
    let engine = try JobEngine(
      store: store,
      router: { requestGuard in
        TaskRouter(
          configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: PendingCredentials(), store: store,
          requestGuard: requestGuard)
      }, consent: consent.requirement, clock: LeaseClock(trusted: nil))
    return PendingWorld(store: store, novel: novel, engine: engine)
  }

  @discardableResult
  func draft(_ chapter: Int, title: String? = nil) async throws -> String {
    let novel = novel
    let saved = try await store.write { transaction in
      try ChapterDrafts.save(
        novel: novel, chapter: chapter, DraftEdit(title: title, body: PendingScript.prose, summary: "Mira climbs."), base: nil, at: Date(), in: &transaction)
    }
    guard case .committed(let revision) = saved else { throw ChatFixtureError.noBinding }
    return revision
  }

  func approvedAndRead(_ chapter: Int) async throws {
    try await store.setFinalizeAutoKeep(novel: novel, categories: [])
    try await store.approveChapter(novel: novel, chapter: chapter, revision: try await draft(chapter))
    let job = try #require(try await store.finalizeReviewJob(novel: novel, chapter: chapter))
    #expect(try await #require(engine).run(job: job).result == .settled(.succeeded))
  }

  func request(_ kind: NovelJobKind, chapter: Int, by replica: ReplicaID? = nil, fingerprint: String = "pending-test") async throws -> EntityRef {
    let key = try JobKey(
      scope: NovelJobAddress.scope(of: novel), kind: kind.rawValue, target: NovelJobAddress.target(chapter: chapter), fingerprint: fingerprint, run: 1)
    let request = JobRequest(key: key, payload: .null, replica: replica ?? store.replica)
    return try await store.write { transaction in try JobRecords.request(request, in: &transaction) }.job.ref
  }

  @discardableResult
  func start(_ job: EntityRef, by replica: ReplicaID, ago: TimeInterval = 0) async throws -> AttemptID {
    let now = LeaseInstant(date: Date().addingTimeInterval(-ago), source: .device)
    let start = AttemptStart(job: job, replica: replica, started: now, byHand: false, pinned: .null)
    let id = try AttemptID(UUID.v7(at: now.date))
    _ = try await store.write { transaction in try AttemptRecords.start(id, start, step: AttemptStep(name: "draft", index: 1), in: &transaction) }
    return id
  }

  func fail(_ job: EntityRef) async throws {
    let (attempt, replica) = (try await start(job, by: store.replica), store.replica)
    let failure = AttemptFailure(code: "ai.timeout", message: "The call timed out.")
    _ = try await store.write { transaction in try AttemptRecords.update(attempt, AttemptUpdate(settlement: .failed(failure)), by: replica, in: &transaction) }
  }

  func list(_ platform: JobPlatform = .phone, later: TimeInterval = 0, consentNeeded: Bool = false, resumable: Set<EntityRef> = []) async throws -> PendingList {
    let now = LeaseInstant(date: clock.now().date.addingTimeInterval(later), source: .device)
    let query = PendingQuery(novel: novel, replica: store.replica, now: now)
    let snapshot = try await store.read { transaction in try PendingSnapshot.load(query, in: transaction) }
    let standing = JobsStanding(here: .running, platform: platform, consentNeeded: consentNeeded, resumable: resumable)
    return PendingItems.list(snapshot, replica: store.replica, standing: standing)
  }

  func stripLines(_ chapter: Int, _ platform: JobPlatform = .phone) async throws -> [ChapterJobLine] {
    let row = try await store.load(ChapterList.self, novel).rows.value?.first { $0.chapter == chapter }
    let board = try await store.load(ChapterJobBoard.self, ChapterJobBoardQuery(novel: novel, chapter: chapter, replica: store.replica, now: clock.now()))
    return ChapterWorkspaceStatus(row: row, board: board, replica: store.replica, standing: JobsStanding(here: .running, platform: platform)).lines
  }
}

extension PendingItem {
  fileprivate var line: ChapterJobLine? {
    guard case .job(let job) = kind else { return nil }
    return job.line
  }
}

@MainActor
@Suite("Waiting on you", TestTimeLimit.standard)
struct PendingTests {
  @Test func shouldListNothingForANovelWithNothingWaiting() async throws {
    let world = try await PendingWorld.make()
    let list = try await world.list()
    #expect(list == .empty && list.count == 0)
  }

  @Test func shouldListEachChapterInNumberOrderWithItsDraftBeforeItsJobsAndAJobOfAChapterWithNoDraft() async throws {
    let world = try await PendingWorld.make()
    try await world.draft(1)
    try await world.draft(2, title: "The Tower")
    let review = try await world.request(.review, chapter: 2)
    try await world.fail(review)
    let orphan = try await world.request(.generate, chapter: 9)

    let list = try await world.list()

    #expect(list.items.map(\.id) == ["review:1", "review:2", "job:\(review.kind):\(review.key.rawValue)", "job:\(orphan.kind):\(orphan.key.rawValue)"])
    #expect(list.count == 4 && list.chats.isEmpty && list.chapters.count == 4 && !list.isPartial)
    #expect(list.items[1].kind == .review(chapter: 2, contradiction: false) && list.items[1].heading == "The Tower")
    #expect(PendingDisplay.chapter(list.items[1]) == String(localized: "Chapter \(2): \("The Tower")", table: "Pending"))
    let failed = try #require(list.items[2].line)
    #expect(failed.actions == [.tryAgain] && PendingDisplay.actions(PendingJob(chapter: 2, line: failed)) == [.tryAgain])
    let strip = try await world.stripLines(2)
    #expect(failed == strip.first)
    let queued = try #require(list.items[3].line)
    #expect(list.items[3].chapter == 9 && queued.actions == [.runHere, .cancel] && PendingDisplay.actions(PendingJob(chapter: 9, line: queued)) == [.runHere])
    let orphanStrip = try await world.stripLines(9)
    #expect(queued == orphanStrip.first)
  }

  @Test func shouldLeaveOutAJobThisDeviceStartsItselfAndOfferRunHereWhereItDoesNot() async throws {
    let world = try await PendingWorld.make()
    try await world.request(.generate, chapter: 1)

    #expect(try await world.list(.mac).items.isEmpty)
    let phone = try await world.list(.phone)
    #expect(phone.count == 1 && phone.items.first?.line?.actions == [.runHere, .cancel])
    let consenting = try await world.list(.mac, consentNeeded: true)
    #expect(consenting.items.first?.line?.state == .waitingForConsent && consenting.items.first?.line?.actions == [.allow, .cancel])
  }

  @Test func shouldLeaveOutARunGoingOnAnotherDeviceUntilItsLeaseLapses() async throws {
    let world = try await PendingWorld.make()
    let job = try await world.request(.generate, chapter: 1)
    try await world.start(job, by: PendingWorld.studio)

    #expect(try await world.list(.phone).items.isEmpty)
    #expect(try await world.list(.mac).items.isEmpty)
    let lapsed = try await world.list(.phone, later: 400)
    guard case .queued(let wait)? = lapsed.items.first?.line?.state else {
      Issue.record("a lapsed run should read as queued")
      return
    }
    #expect(wait.stopped?.step == AttemptStep(name: "draft", index: 1) && lapsed.items.first?.line?.actions == [.runHere, .cancel])
  }

  @Test func shouldOfferResumeForARunStoppedHereWhileTheEngineListsIt() async throws {
    let world = try await PendingWorld.make()
    let job = try await world.request(.generate, chapter: 1)
    try await world.start(job, by: world.store.replica, ago: 400)

    let listed = try await world.list(.phone, resumable: [job])
    guard case .interrupted? = listed.items.first?.line?.state else {
      Issue.record("the run should read as stopped here")
      return
    }
    #expect(listed.items.first?.line?.actions == [.resume, .cancel])
  }

  @Test func shouldListAnApprovedChapterOnceItsStoryBibleUpdatesAreReadWithHowManyNeedACall() async throws {
    let world = try await PendingWorld.make()
    try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: try await world.draft(1))
    #expect(try await world.list(.phone).items.map(\.id).allSatisfy { !$0.hasPrefix("finalize:") })

    let again = try await PendingWorld.make()
    try await again.approvedAndRead(1)
    let list = try await again.list(.phone)
    guard case .finalize(1, let open)? = list.items.first?.kind else {
      Issue.record("the approved chapter should wait for its Story Bible updates")
      return
    }
    #expect(open > 0 && list.count == 1)
    #expect(PendingDestination.of(try #require(list.items.first)) { _ in true } == .finalize(1))
  }

  @Test func shouldListWaitingCardsBeforeChaptersAndKeepEachNovelApart() async throws {
    let cards = try await ChatCardsWorld.make([ChatCardsScript.reply("A place.", ops: [ChatCardsScript.idea("hall", "Saltgate Hall")])])
    let card = try #require(try await cards.reply(to: "Add a place.").cardProposal)
    let world = try await PendingWorld.make(store: cards.store, novel: cards.novel)
    try await world.draft(1)
    let other = try await cards.store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Tidewater"), in: &transaction) }
    let elsewhere = try await PendingWorld.make(store: cards.store, novel: other)
    try await elsewhere.draft(1)

    let list = try await world.list()
    #expect(list.items.map(\.id) == ["card:\(card)", "review:1"])
    #expect(list.chats.count == 1 && list.chapters.count == 1)
    #expect(try await elsewhere.list().items.map(\.id) == ["review:1"])
    #expect(PendingDestination.of(try #require(list.items.first)) { $0 == cards.session } == .chat(cards.session, .proposal(card)))
    #expect(PendingDestination.of(try #require(list.items.first)) { _ in false } == nil)
  }

  @Test func shouldCountForTheBadgeWhatTheHomeListsAndFollowWrites() async throws {
    let world = try await PendingWorld.make()
    try await world.request(.generate, chapter: 4)
    let model = PendingModel()
    let task = observing { await model.observe(world.context, now: world.clock.now()) }
    defer { task.cancel() }
    let standing = JobsStanding(here: .running, platform: .phone)

    try await ChatWait.until("the job is listed") { model.list(replica: world.store.replica, standing: standing).count == 1 }
    try await world.draft(1)
    try await ChatWait.until("the draft joins the list") { model.list(replica: world.store.replica, standing: standing).count == 2 }
    let home = model.list(replica: world.store.replica, standing: standing)
    let read = try await world.list(.phone)
    #expect(home.items.map(\.chapter) == [1, 4] && home == read)
    #expect(model.list(replica: world.store.replica, standing: JobsStanding(here: .running, platform: .mac)).count == 1)
  }

  @Test func shouldTakeEachRowWhereItIsSettledThroughTheNavigator() {
    let navigator = NovelNavigator(layout: .compact)
    let actions = PendingActions()
    navigator.push(CompactStop.pending)

    actions.open(.finalize(3), navigator: navigator, chats: nil)
    #expect(actions.finalizing == 3 && navigator.compactPath.count == 1)

    actions.open(.chapter(3), navigator: navigator, chats: nil)
    #expect(navigator.section == .reader && navigator.compactPath.count == 3 && !navigator.isAtRoot(.reader))

    navigator.pop(.reader)
    navigator.compactBinding.wrappedValue.removeLast()
    #expect(navigator.section == .chat && navigator.compactPath.count == 1)

    actions.open(.plans, navigator: navigator, chats: nil)
    #expect(navigator.section == .chat && navigator.compactPath.isEmpty)

    let regular = NovelNavigator()
    regular.show(.chat)
    actions.open(.chapter(5), navigator: regular, chats: nil)
    #expect(regular.section == .reader && regular.path(for: .reader).wrappedValue.count == 1)
  }

  @Test func shouldRunEachJobActionOnTheRuntimeInPlace() async throws {
    let world = try await PendingWorld.make()
    let log = StartLog()
    let calls = JobEngineCalls(run: log.starter("run"), runHere: log.starter("runHere"), resumeHere: log.starter("resumeHere"))
    let engine = try #require(world.engine)
    let runtime = JobRuntime(store: world.store, clock: world.clock, platform: .phone, calls: calls) { () throws(JobEngineError) in engine }
    let actions = PendingActions()
    await actions.perform(.runHere, on: PendingJob(chapter: 1, line: try await queuedLine(world)), novel: world.novel, runtime: nil)
    #expect(actions.failure == JobsErrors.notRunningHere && log.all.isEmpty)

    await runtime.launch()
    defer { runtime.shutDown() }
    let job = PendingJob(chapter: 1, line: try await queuedLine(world))
    let key = job.line.job.key.rawValue
    for action in [ChapterJobLine.Action.runHere, .resume, .tryAgain] {
      actions.failure = nil
      await actions.perform(action, on: job, novel: world.novel, runtime: runtime)
      #expect(actions.failure != nil)
    }
    #expect(log.all == ["runHere \(key)", "resumeHere \(key)", "run \(key)"])

    await actions.perform(.allow, on: job, novel: world.novel, runtime: runtime)
    #expect(actions.consent == nil)
    await actions.perform(.cancel, on: job, novel: world.novel, runtime: runtime)
    #expect(actions.stopping == job && log.all.count == 3)
    await actions.stop(job, runtime: runtime)
    #expect(actions.stopping == nil && actions.failure == nil)
    #expect(try await world.list(.phone).items.isEmpty)
  }

  private func queuedLine(_ world: PendingWorld) async throws -> ChapterJobLine {
    if let line = try await world.list(.phone).items.first?.line { return line }
    try await world.request(.generate, chapter: 1)
    return try #require(try await world.list(.phone).items.first?.line)
  }
}
