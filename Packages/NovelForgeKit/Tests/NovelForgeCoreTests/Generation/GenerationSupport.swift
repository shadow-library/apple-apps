import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// The job engine's world with a planned chapter 1, a word target the scripted drafts meet, and the real generation pipeline.
struct GenerationWorld {
  static let body =
    "Mara climbed the lighthouse stairs at dusk with the lamp in her hand. She found the logbook open on the desk and its last page torn away. Outside the gulls wheeled over the black water and the tide came in fast."
  static let patchedBody =
    "Mara climbed the lighthouse stairs at dawn with the lamp in her hand. She found the logbook open on the desk and its last page torn away. Outside the gulls wheeled over the black water and the tide came in fast."
  static let rewrittenBody =
    "Mara waited at the foot of the lighthouse until the keeper came down. He carried the logbook under his arm and would not say who had torn the last page. Behind them the tide crept over the rocks and the gulls went quiet."

  let base: JobEngineWorld

  var novel: UUID { base.novel }
  var store: VaultStore { base.store }
  var provider: ScriptedModelProvider { base.provider }

  init(calls: [[ScriptedModelProvider.Step]] = [], wordTarget: WordTarget = WordTarget(min: 20, max: 400), plan: ChapterPlanContent? = GenerationWorld.plan()) async throws {
    let store = try Projection.store(try Projection.reconciler())
    let novel = SchemaFixture.novel
    try await store.write { transaction in
      _ = try NovelRecord(id: novel, name: "Ember", wordTarget: wordTarget).create(in: &transaction)
      if let plan { _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: plan).create(in: &transaction) }
    }
    base = try await JobEngineWorld(store: store, provider: ScriptedModelProvider(calls: calls))
  }

  static func plan(_ mode: ContentMode? = nil, writeMode: BriefWriteMode = .standard) -> ChapterPlanContent {
    ChapterPlanContent(body: "Mara climbs the lighthouse and finds the torn logbook.", contentMode: mode.map { .known($0) }, writeMode: .known(writeMode))
  }

  func engine(_ faults: AttemptRunner.Faults = .none, unrestrictedAvailable: Bool = false) throws -> JobEngine {
    let (base, rereads) = (base, base.rereads)
    return try JobEngine(
      store: store, router: { base.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil, device: base.clock.function), runner: base.runner(faults),
      packs: base.packs.builder(store), timing: JobEngine.Timing { _ in try await rereads.sleep() }, unrestrictedAvailable: unrestrictedAvailable)
  }

  /// Requests a regenerate here and waits for its run to end.
  @discardableResult
  func generate(
    _ engine: JobEngine, chapter: Int = 1, options: GenerationOptions = GenerationOptions(), expecting expected: AttemptResult = .settled(.succeeded)
  ) async throws -> JobRunHandle {
    guard case .running(let handle) = try await engine.regenerateChapter(novel: novel, chapter: chapter, options: options) else {
      throw EngineFixtureError(description: "the generation did not run here")
    }
    let result = await handle.result
    if result != expected { Issue.record("the generate job ended \(result): \(String(describing: try await base.attempt(handle.attempt).error))") }
    return handle
  }

  /// A regenerate ended at `point` as a process ends there; `resume` relaunches the engine as a launch does.
  func interrupted(at point: AttemptRunner.Faults.Point) async throws -> JobRunHandle {
    let engine = try engine(.once(at: point))
    guard case .running(let handle) = try await engine.regenerateChapter(novel: novel, chapter: 1) else { throw EngineFixtureError(description: "not run here") }
    #expect(await handle.result == .interrupted)
    engine.relinquish()
    return handle
  }

  func resume() async throws {
    base.clock.advance(5)
    let relaunched = try engine()
    for resumed in try await relaunched.resumeInterruptedAttempts() { #expect(await resumed.result == .settled(.succeeded)) }
  }

  @discardableResult
  func handDraft(_ body: String = "Hand-written.", chapter: Int = 1) async throws -> String {
    let novel = novel
    return try await store.write { transaction in try ChapterWrites.draft(novel: novel, chapter: chapter, body: body, source: .handEdited, in: &transaction) }
  }

  func lifecycle(_ chapter: Int = 1) async throws -> ChapterLifecycleEntry {
    try #require(try await ChapterTables.lifecycle(novel, in: store)[chapter])
  }

  func history(_ chapter: Int = 1) async throws -> RevisionHistory<DraftContent, DraftMark> {
    let novel = novel
    return try #require(try await store.read { transaction in try DraftRecord.history(try DraftRecord.ref(novel: novel, chapter: chapter), in: transaction) }.history)
  }

  /// The revisions the job saved, oldest first.
  func saved(_ job: EntityRef, chapter: Int = 1) async throws -> [RevisionEntry<DraftContent>] {
    try await history(chapter).revisions.filter { $0.body.body?.job == job.key }.reversed()
  }

  func passes(_ chapter: Int = 1) async throws -> [ChapterReviewRecord] {
    try await store.chapterReviews(novel: novel, chapter: chapter).history.map(\.review).filter(\.generationPass)
  }

  static func draftReply(_ body: String = body, title: String = "The Torn Page", summary: String = "Mara finds the logbook torn.") -> [ScriptedModelProvider.Step] {
    reply(["title": .string(title), "body": .string(body), "summary": .string(summary), "state": ["lastBeat": "The tide comes in.", "openConflict": "Who tore the page?"]])
  }

  static func judgeReply(
    verdict: String = "consistent", findings: [(severity: String, text: String)] = [], brief: JSONValue? = ["compliant": true, "issues": []],
    ending: JSONValue? = nil
  ) -> [ScriptedModelProvider.Step] {
    var reply: JSONValue = [
      "verdict": .string(verdict), "findings": .array(findings.map { ["severity": .string($0.severity), "text": .string($0.text)] }),
      "readabilityCompliance": ["compliant": true, "issues": []],
    ]
    if case .object(var members) = reply {
      if let brief { members["briefCompliance"] = brief }
      if let ending { members["endingCompliance"] = ending }
      reply = .object(members)
    }
    return Self.reply(reply)
  }

  static let contradiction = judgeReply(verdict: "contradiction", findings: [("hard", "Mara climbs at dusk, but chapter 0 ends at dawn.")])

  static func patchReply(find: String = "at dusk", replace: String = "at dawn") -> [ScriptedModelProvider.Step] {
    reply(["action": "patch", "patches": [["find": .string(find), "replace": .string(replace)]]])
  }

  static func reply(_ json: JSONValue) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(json), as: UTF8.self))
  }
}
