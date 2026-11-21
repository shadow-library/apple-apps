import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

private struct GenerationCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

@MainActor
final class GenerationPowerLog {
  var begun = 0
  var ended = 0

  var activity: JobPowerAssertion.Activity {
    JobPowerAssertion.Activity(
      begin: { [self] in
        begun += 1
        return NSObject()
      },
      end: { [self] _ in ended += 1 })
  }
}

enum GenerationScripts {
  static let body =
    "Mara climbed the lighthouse stairs at dusk with the lamp in her hand. She found the logbook open on the desk and its last page torn away. Outside the gulls wheeled over the black water and the tide came in fast."
  static let other =
    "Mara waited at the foot of the lighthouse until the keeper came down. He carried the logbook under his arm and would not say who had torn the last page. Behind them the tide crept over the rocks and the gulls went quiet."

  static func draft(_ text: String = body) -> [ScriptedModelProvider.Step] {
    reply([
      "title": "The Torn Page", "body": .string(text), "summary": "Mara finds the logbook torn.",
      "state": ["lastBeat": "The tide comes in.", "openConflict": "Who tore the page?"],
    ])
  }

  static func judge() -> [ScriptedModelProvider.Step] {
    reply([
      "verdict": "consistent", "findings": [], "readabilityCompliance": ["compliant": true, "issues": []], "briefCompliance": ["compliant": true, "issues": []],
    ])
  }

  private static func reply(_ json: JSONValue) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(json), as: UTF8.self))
  }
}

enum GenerationStarters {
  static let refusing: JobEngineCalls.Start = { _, _ throws(JobEngineError) in throw .pipelineNotYetAvailable(.generate) }
}

@MainActor
struct GenerationWorld {
  let store: VaultStore
  let novel: UUID
  let provider: ScriptedModelProvider
  let power: GenerationPowerLog
  let makeEngine: JobRuntime.EngineFactory
  let runtime: JobRuntime

  static func make(_ calls: [[ScriptedModelProvider.Step]] = [], plan: Bool = true, starter: JobEngineCalls.Start? = nil, platform: JobPlatform = .mac) async throws
    -> GenerationWorld
  {
    let store = try NovelForgeStore.openInMemory()
    let novel = UUID()
    try await store.write { transaction in
      _ = try NovelRecord(id: novel, name: "Ember", wordTarget: WordTarget(min: 20, max: 400)).create(in: &transaction)
      if plan {
        _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: ChapterPlanContent(body: "Mara climbs the lighthouse and finds the torn logbook.")).create(in: &transaction)
      }
    }
    let provider = ScriptedModelProvider(calls: calls)
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let consent = ConsentDisclosure.novelText
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: binding.host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
    }
    let clock = LeaseClock(trusted: nil)
    let power = GenerationPowerLog()
    let makeEngine: JobRuntime.EngineFactory = { () throws(JobEngineError) -> JobEngine in
      try JobEngine(
        store: store,
        router: { requestGuard in
          TaskRouter(
            configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: GenerationCredentials(), store: store,
            requestGuard: requestGuard)
        }, consent: consent.requirement, clock: clock)
    }
    let assertion = JobPowerAssertion(activity: power.activity)
    let calls = starter.map { JobEngineCalls(run: $0) } ?? JobEngineCalls()
    let runtime = JobRuntime(store: store, clock: clock, platform: platform, power: assertion, takeOverDelay: .milliseconds(20), calls: calls, makeEngine: makeEngine)
    return GenerationWorld(store: store, novel: novel, provider: provider, power: power, makeEngine: makeEngine, runtime: runtime)
  }

  func handDraft(_ body: String) async throws -> String {
    let novel = novel
    let saved = try await store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: body), base: nil, at: Date(), in: &transaction)
    }
    guard case .committed(let revision) = saved else { throw ChatFixtureError.noBinding }
    return revision
  }

  func jobs() async throws -> [ChapterJob] {
    try await store.load(ChapterJobs.self, ChapterJobsQuery(novel: novel, chapter: 1, now: runtime.clock.now())).jobs.value ?? []
  }

  func status() async throws -> ChapterWorkspaceStatus {
    let row = try await store.load(ChapterList.self, novel).rows.value?.first { $0.chapter == 1 }
    let board = try await store.load(ChapterJobBoard.self, ChapterJobBoardQuery(novel: novel, chapter: 1, replica: store.replica, now: runtime.clock.now()))
    return ChapterWorkspaceStatus(row: row, board: board, replica: store.replica, standing: runtime.standing)
  }

  func engineCancel(_ job: EntityRef) async throws -> JobCancelOutcome {
    try await #require(runtime.engine).cancel(job: job)
  }

  func versions() async throws -> GenerationVersions {
    try await store.load(GenerationVersions.self, ChapterLocator(novel: novel, chapter: 1))
  }

  func waitForRun(_ count: Int) async throws {
    try await JobsWait.until("generate run \(count) has succeeded") {
      guard let job = try await jobs().first(where: { $0.kind == .known(.generate) }), case .succeeded = job.status else { return false }
      return job.run == count
    }
  }
}
