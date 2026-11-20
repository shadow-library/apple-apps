import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A novel with one character and one open thread, planned through the real plan pipeline on the engine's scripted router.
struct PlanJobWorld {
  static let intent = "She sells the lamp, and regrets it by nightfall."

  static let plan: OrderedJSON = jsonObject([
    ("title", .string("The Lamp")), ("objective", .string("Mara tests the lamp.")),
    (
      "scenes",
      .array([
        jsonObject([
          ("summary", .string("Mara lights the lamp.")), ("pov", .string("mara")), ("goal", .string("See what it shows")), ("obstacle", .string("The wick will not catch")),
          ("turn", .string("It shows a door")), ("beats", .array([.string("She strikes a match")])), ("estimatedWords", .int(1100)),
        ]),
        jsonObject([
          ("summary", .string("A stranger watches.")), ("pov", .string("ghost")), ("goal", .string("Stay unseen")), ("obstacle", .string("The light")),
          ("turn", .string("He is seen")), ("beats", .array([.string("He steps back")])), ("estimatedWords", .int(1100)),
        ]),
      ])
    ),
    ("requiredContext", .array([.string("entity:mara"), .string("fact:heir"), .string("entity:nobody")])),
    (
      "endingContract",
      jsonObject([
        ("hookType", .string("turn")), ("emotionalBeat", .string("unease")), ("openQuestion", .string("Where does the door lead?")),
        ("handoffState", .string("Mara at the door")),
      ])
    ),
    ("chapterPurpose", .string("Open the lamp's mystery.")),
    ("readerValue", .array([.string("new_information")])),
  ])

  let engineWorld: JobEngineWorld

  var novel: UUID { engineWorld.novel }
  var store: VaultStore { engineWorld.store }
  var provider: ScriptedModelProvider { engineWorld.provider }

  init(
    calls: Int = 1, replies: [String]? = nil, mode: ContentMode = .standard, seed: @escaping @Sendable (UUID, inout WriteTransaction) throws -> Void = { _, _ in }
  ) async throws {
    let store = try Projection.store(try Projection.reconciler())
    let novel = SchemaFixture.novel
    try await store.write { transaction in
      _ = try NovelRecord(id: novel, name: "Ember", contentMode: .known(mode)).create(in: &transaction)
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara").create(in: &transaction)
      _ = try ThreadRecord(novel: novel, thread: "lamp", summary: "What the lamp shows", openedChapter: 1, status: ThreadProgress(state: .known(.open))).create(
        in: &transaction)
      try seed(novel, &transaction)
    }
    let scripts = (replies ?? Array(repeating: Self.planText, count: calls)).map { ScriptedModelProvider.reply($0) }
    engineWorld = try await JobEngineWorld(store: store, provider: ScriptedModelProvider(calls: scripts))
  }

  static var planText: String { text(plan) }

  static func text(_ json: OrderedJSON) -> String { String(decoding: CanonicalJSON.encode(JSONValue(schema: json)), as: UTF8.self) }

  /// The plan claiming a milestone the chapter cannot claim, which the plan's advice sends back once.
  static var overclaimingText: String {
    let fields = plan.objectValue?.entries.map { (key: $0.key, value: $0.value) } ?? []
    return text(.object(OrderedJSONObject(fields + [(key: "claimedMilestones", value: .array([.string("no_such_milestone")]))])))
  }

  func engine(_ faults: AttemptRunner.Faults = .none, unrestrictedAvailable: Bool = false) throws -> JobEngine {
    let world = engineWorld
    let rereads = world.rereads
    return try JobEngine(
      store: store, router: { world.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil, device: world.clock.function), runner: world.runner(faults),
      catalog: PipelineCatalog.definition(for:), timing: JobEngine.Timing { _ in try await rereads.sleep() }, unrestrictedAvailable: unrestrictedAvailable)
  }

  func request(_ engine: JobEngine, chapter: Int? = nil, steer: ChapterPlanSteer = .none, empty: Bool = false) async throws(ChapterPlanError) -> ChapterPlanReceipt {
    try await engine.requestPlan(ChapterPlanJobRequest(novel: novel, chapter: chapter, steer: steer, empty: empty))
  }

  func refusal(_ engine: JobEngine, chapter: Int? = nil, steer: ChapterPlanSteer = .none, empty: Bool = false) async -> ChapterPlanError? {
    do {
      _ = try await request(engine, chapter: chapter, steer: steer, empty: empty)
      return nil
    } catch {
      return error
    }
  }

  func card(of job: JobKey) async throws -> ProposalRecord? {
    let id = PlanCards.id(of: job.ref)
    return try await store.read { transaction in try ProposalRecord.read(id: id, in: transaction).entry?.record }
  }

  func proposals() async throws -> [ProposalState] {
    let novel = novel
    return try await store.read { transaction in try transaction.query { database in try ProposalState.filter(Column("novel") == novel).fetchAll(database) } }
  }

  /// The changes the unsent log holds for the job's card: one per staging.
  func cardWrites(of job: JobKey) async throws -> Int {
    let ref = NovelForgeKey.proposal(PlanCards.id(of: job.ref))
    return try await store.pendingChanges(limit: Int.max).count { change in (try? ChangeRecord(json: try CanonicalJSON.decode(change.line)))?.ref == ref }
  }

  func writeDraft(chapter: Int) async throws {
    let novel = novel
    try await store.write { transaction in
      _ = try DraftRecord(novel: novel, chapter: chapter, content: DraftContent(body: "Mara lit the lamp.", source: .known(.generated))).create(in: &transaction)
    }
  }

  func failure(_ result: AttemptResult) -> AttemptFailure? {
    guard case .settled(.failed(let failure)) = result else { return nil }
    return failure
  }

  var userPrompt: String? { provider.requests.first?.messages.first { $0.role == .user }?.text }
}
