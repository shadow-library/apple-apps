import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import NovelForgeEval
@testable import ShadowJobs

/// How a device's ask to run a stage ended: running here, answered with the job another device runs, or refused before any job was asked for.
enum StageStart: Sendable {
  case running(JobRunHandle)
  case elsewhere(EntityRef)
  case refused(String)

  var handle: JobRunHandle? {
    guard case .running(let handle) = self else { return nil }
    return handle
  }
}

/// One job of the chain the evaluation tool drives, started through the API the app calls; variant 1 is the other device's model, answering differently.
enum ChapterStage: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case plan
  case generate
  case review
  case finalizeReview
  case canonRefresh

  static let chapter = 1
  static let otherBody =
    "Mara waited at the foot of the lighthouse until the keeper came down. He carried the logbook under his arm and would not say who had torn the last page. Behind them the tide crept over the rocks and the gulls went quiet."

  var testDescription: String { rawValue }

  var ordinal: Int { Self.allCases.firstIndex(of: self) ?? 0 }

  var earlier: [ChapterStage] { Array(Self.allCases.prefix { $0 != self }) }

  func calls(variant: Int = 0) -> [[ScriptedModelProvider.Step]] {
    let script = EvalScript.calls
    guard variant != 0 else {
      switch self {
      case .plan: return [script[0]]
      case .generate: return [script[1], script[2]]
      case .review: return [script[3]]
      case .finalizeReview: return [script[4]]
      case .canonRefresh: return [Self.refreshReply(status: "The keeper of the lighthouse.")]
      }
    }
    switch self {
    case .plan:
      guard case .object(var plan) = EvalScript.plan else { return [script[0]] }
      plan["title"] = "The Dark Stair"
      return [EvalScript.reply(.object(plan))]
    case .generate:
      let draft: JSONValue = [
        "title": "The Keeper", "body": .string(Self.otherBody), "summary": "The keeper keeps the logbook.",
        "state": ["lastBeat": "The gulls go quiet.", "openConflict": "Who tore the page?"],
      ]
      return [EvalScript.reply(draft), script[2]]
    case .review:
      return [script[3]]
    case .finalizeReview:
      return [Self.continuity(location: "the lamp room")]
    case .canonRefresh:
      return [Self.refreshReply(status: "A keeper who found the torn logbook.")]
    }
  }

  private static func continuity(location: String) -> [ScriptedModelProvider.Step] {
    EvalScript.reply([
      "appeared": ["mara"], "newEntities": [], "threads": [], "mysteries": [], "timeline": [], "relationships": [], "power": [],
      "characterStates": [["entityKey": "mara", "location": .string(location), "evidence": "Mara climbed the lighthouse stairs at dusk"]], "knowledgeChanges": [],
      "chapterSummary": "Mara finds the logbook torn.", "milestones": [],
    ])
  }

  /// A refresh that updates Mara's record on the chapter's own words, so it stages a card.
  private static func refreshReply(status: String) -> [ScriptedModelProvider.Step] {
    let update = RefreshWorld.update(
      "Mara's record does not say she found the logbook.", quotes: [("chapter:1", "She found the logbook open on the desk")],
      ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("mara")), ("type", .string("character")), ("status", .string(status))])])
    return ScriptedModelProvider.reply(RefreshWorld.text(RefreshWorld.reply([update])))
  }

  /// A refresh whose one update would create a record, which the report withholds, so it stages no card.
  static var withholdingRefresh: [ScriptedModelProvider.Step] {
    let update = RefreshWorld.update(
      "The keeper appears for the first time.", quotes: [("chapter:1", "She found the logbook open on the desk")],
      ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("keeper")), ("type", .string("character")), ("status", .string("The keeper."))])])
    return ScriptedModelProvider.reply(RefreshWorld.text(RefreshWorld.reply([update])))
  }

  /// Asks to run the stage on the device as the app does.
  func start(on device: ChapterDevice, calls: [[ScriptedModelProvider.Step]]) async throws -> StageStart {
    device.model.queue(calls)
    let (engine, novel, chapter) = (try device.engine, ChapterReplicas.novel, Self.chapter)
    do {
      switch self {
      case .plan:
        return try await Self.run(try await engine.requestPlan(ChapterPlanJobRequest(novel: novel)).job.ref, on: engine)
      case .generate:
        switch try await engine.generateChapter(novel: novel, chapter: chapter) {
        case .running(let handle): return .running(handle)
        case .elsewhere(let job): return .elsewhere(job)
        }
      case .review:
        switch try await engine.requestReview(novel: novel, chapter: chapter, kind: .judge) {
        case .running(let handle): return .running(handle)
        case .elsewhere(let job): return .elsewhere(job)
        case .reviewed: return .refused("reviewed_at_once")
        }
      case .finalizeReview:
        let head = try await device.head()
        _ = try await device.store.approveChapter(novel: novel, chapter: chapter, revision: head)
        guard let job = try await device.store.finalizeReviewJob(novel: novel, chapter: chapter) else { return .refused("finalize_review_missing") }
        return try await Self.run(job, on: engine)
      case .canonRefresh:
        return try await Self.run(try await engine.requestCanonRefresh(novel: novel, chapter: chapter).ref, on: engine)
      }
    } catch let error as any ShadowError {
      return .refused(error.code)
    }
  }

  private static func run(_ job: EntityRef, on engine: JobEngine) async throws -> StageStart {
    do throws(JobEngineError) {
      return .running(try await engine.run(job: job))
    } catch .runningElsewhere {
      return .elsewhere(job)
    }
  }

  /// What the author does once the job ran, so the next stage can start: the plan card applied, the chapter finalized when approval left it waiting.
  func complete(on device: ChapterDevice, job: EntityRef) async throws {
    let (store, novel, chapter) = (device.store, ChapterReplicas.novel, Self.chapter)
    switch self {
    case .plan:
      #expect(try await NovelEvaluation.applyPlanCard(of: job, novel: novel, in: store, now: device.clock.now))
    case .finalizeReview:
      guard try await !device.isFinal() else { return }
      _ = try await store.keepRoutineFinalizeItems(novel: novel, chapter: chapter)
      try await store.write { transaction in _ = try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction) }
    case .generate, .review, .canonRefresh:
      return
    }
  }
}

extension ChapterDevice {
  /// Runs the stage here to its end and completes it as the author does, returning its job.
  @discardableResult
  func run(_ stage: ChapterStage, completing: Bool = true) async throws -> EntityRef {
    guard case .running(let handle) = try await stage.start(on: self, calls: stage.calls()) else {
      throw EngineFixtureError(description: "\(stage) did not run on replica \(index)")
    }
    let result = await handle.result
    #expect(result == .settled(.succeeded), "\(stage) on replica \(index) ended \(result)")
    if completing { try await stage.complete(on: self, job: handle.job) }
    return handle.job
  }

  func head() async throws -> String {
    let ref = try DraftRecord.ref(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter)
    return try #require(try await store.read { transaction in try DraftRecord.history(ref, in: transaction).history?.head })
  }

  func isFinal() async throws -> Bool {
    let (novel, chapter) = (ChapterReplicas.novel, ChapterStage.chapter)
    return try await store.read { transaction in try transaction.state(of: try FinalChapterRecord.ref(novel: novel, chapter: chapter)) != nil }
  }
}

extension ChapterReplicas {
  /// Brings the chapter to where `stage` starts, every earlier stage run on replica 0 alone, and syncs both replicas.
  func prepare(for stage: ChapterStage) async throws {
    for earlier in stage.earlier { try await self[0].run(earlier) }
    try await sync()
  }
}
