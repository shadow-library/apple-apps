import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// The job engine's world with one drafted chapter and the real review pipeline.
struct ReviewWorld {
  static let body =
    "Mara climbed the lighthouse stairs at dusk. She found teh logbook open on the desk, its last page torn away. Outside, the gulls wheeled over the black water."

  let base: JobEngineWorld

  var novel: UUID { base.novel }
  var store: VaultStore { base.store }
  var provider: ScriptedModelProvider { base.provider }

  init(calls: [[ScriptedModelProvider.Step]] = [], body: String = ReviewWorld.body, isolated: Bool = false) async throws {
    base = try await JobEngineWorld(provider: ScriptedModelProvider(calls: calls))
    try await draft(body, isolated: isolated)
  }

  @discardableResult
  func draft(_ body: String, isolated: Bool = false) async throws -> String {
    let novel = novel
    return try await store.write { transaction in
      let ref = try DraftRecord.ref(novel: novel, chapter: 1)
      var content = DraftContent(body: body, source: .known(.generated), isolated: isolated)
      content.upstream = try DraftUpstream.current(novel: novel, chapter: 1, in: transaction)
      if case .absent = try DraftRecord.read(ref, in: transaction) {
        _ = try DraftRecord(novel: novel, chapter: 1, content: content).create(in: &transaction)
      } else {
        _ = try DraftRecord.revise(ref, content, in: &transaction)
      }
      return try #require(try ChapterWrites.head(novel: novel, chapter: 1, in: transaction))
    }
  }

  func engine(_ faults: AttemptRunner.Faults = .none, unrestrictedAvailable: Bool = false) throws -> JobEngine {
    let (base, rereads) = (base, base.rereads)
    return try JobEngine(
      store: store, router: { base.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil, device: base.clock.function), runner: base.runner(faults),
      timing: JobEngine.Timing { _ in try await rereads.sleep() }, unrestrictedAvailable: unrestrictedAvailable)
  }

  func reviews() async throws -> ChapterReviewList {
    try await store.chapterReviews(novel: novel, chapter: 1)
  }

  func latest(_ kind: ChapterReviewKind) async throws -> ChapterReviewView {
    try #require(try await reviews().latest.first { $0.review.reviewKind == .known(kind) })
  }

  /// Runs a model review to its end on this device.
  func review(_ engine: JobEngine, _ kind: ChapterReviewKind, unrestricted: Bool = false) async throws -> AttemptID {
    guard case .running(let handle) = try await engine.requestReview(novel: novel, chapter: 1, kind: kind, unrestricted: unrestricted) else {
      throw EngineFixtureError(description: "the review did not run here")
    }
    let result = await handle.result
    if result != .settled(.succeeded) { Issue.record("the review job ended \(result): \(String(describing: try await base.attempt(handle.attempt).error))") }
    return handle.attempt
  }

  /// The chapter as the lifecycle derives it from the latest judge review and its remedies.
  func lifecycle() async throws -> ChapterLifecycleEntry {
    try #require(try await ChapterTables.lifecycle(novel, in: store)[1])
  }

  static func judgeReply(verdict: String = "contradiction", findings: [(severity: String, text: String)]) -> [ScriptedModelProvider.Step] {
    let items: [JSONValue] = findings.map { ["severity": .string($0.severity), "text": .string($0.text)] }
    let compliant: JSONValue = ["compliant": true, "issues": []]
    let reply: JSONValue = [
      "verdict": .string(verdict), "findings": .array(items), "knowledgeCompliance": compliant, "readabilityCompliance": compliant,
    ]
    return ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(reply), as: UTF8.self))
  }

  static let contradiction = judgeReply(findings: [("hard", "Mara climbs the stairs, but her leg was broken in chapter 0.")])

  static func reply(_ json: JSONValue) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(json), as: UTF8.self))
  }
}
