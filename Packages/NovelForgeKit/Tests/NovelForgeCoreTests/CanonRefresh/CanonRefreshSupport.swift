import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A novel whose chapter 1 is final, with one Story Bible page, one character and one secret, refreshed through the real pipeline on the engine's scripted router.
struct RefreshWorld {
  static let prose = "Mara took the iron crown from the harbour vault and crowned herself queen of the salt road before the bells rang."
  static let maraStatus = "A smuggler who runs the salt road."
  static let crowned = "Queen of the salt road, crowned with the iron crown."

  /// The update chapter 1 calls for: Mara's status, standing on the chapter's own words.
  static var crowning: OrderedJSON {
    update(
      "Mara is now queen; her record still calls her a smuggler.", quotes: [("chapter:1", "crowned herself queen of the salt road")],
      ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("mara")), ("type", .string("character")), ("status", .string(crowned))])])
  }

  let engineWorld: JobEngineWorld

  var novel: UUID { engineWorld.novel }
  var store: VaultStore { engineWorld.store }
  var provider: ScriptedModelProvider { engineWorld.provider }

  init(
    replies: [OrderedJSON] = [], mode: ContentMode = .standard, canon: Canon = Canon(title: "The Crown", body: RefreshWorld.prose),
    seed: @escaping @Sendable (UUID, inout WriteTransaction) throws -> Void = { _, _ in }
  ) async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await Self.seed(store, mode: mode, canon: canon, seed)
    try await self.init(replies: replies, seeded: store)
  }

  /// Over a store `seed` already wrote, as a replica that received the novel does.
  init(replies: [OrderedJSON], seeded store: VaultStore) async throws {
    engineWorld = try await JobEngineWorld(store: store, provider: ScriptedModelProvider(calls: replies.map { ScriptedModelProvider.reply(Self.text($0)) }))
  }

  /// A nil canon leaves chapter 1 unfinalized.
  static func seed(
    _ store: VaultStore, mode: ContentMode = .standard, canon: Canon? = Canon(title: "The Crown", body: RefreshWorld.prose),
    _ seed: @escaping @Sendable (UUID, inout WriteTransaction) throws -> Void = { _, _ in }
  ) async throws {
    let novel = SchemaFixture.novel
    try await store.write { transaction in
      _ = try NovelRecord(id: novel, name: "Ember", contentMode: .known(mode)).create(in: &transaction)
      _ = try PageRecord(novel: novel, section: .world, slug: "places", content: PageContent(body: "The harbour vault is sealed, and nobody has opened it in a century."))
        .create(in: &transaction)
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", status: maraStatus).create(in: &transaction)
      _ = try SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", revealChapter: 3).create(in: &transaction)
      try seed(novel, &transaction)
      if let canon { _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: canon).finalize(in: &transaction) }
    }
  }

  static func update(_ finding: String, quotes: [(String, String)], ops: [OrderedJSON]) -> OrderedJSON {
    jsonObject([
      ("finding", .string(finding)), ("evidence", .array(quotes.map { jsonObject([("ref", .string($0.0)), ("quote", .string($0.1))]) })), ("changeSet", .array(ops)),
    ])
  }

  static func reply(_ updates: [OrderedJSON]) -> OrderedJSON { jsonObject([("updates", .array(updates))]) }

  static func text(_ json: OrderedJSON) -> String { String(decoding: CanonicalJSON.encode(JSONValue(schema: json)), as: UTF8.self) }

  func engine(_ faults: AttemptRunner.Faults = .none, unrestrictedAvailable: Bool = false) throws -> JobEngine {
    let world = engineWorld
    let rereads = world.rereads
    return try JobEngine(
      store: store, router: { world.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil, device: world.clock.function), runner: world.runner(faults),
      catalog: PipelineCatalog.definition(for:), timing: JobEngine.Timing { _ in try await rereads.sleep() }, unrestrictedAvailable: unrestrictedAvailable)
  }

  func canonDigest(chapter: Int = 1) async throws -> String {
    let novel = novel
    return try #require(try await store.read { transaction in try RefreshRecords.canonDigest(novel: novel, chapter: chapter, in: transaction) })
  }

  func reports(chapter: Int = 1) async throws -> [RefreshReportRecord] {
    let novel = novel
    return try await store.read { transaction in try RefreshReportRecord.listing(novel: novel, chapter: chapter, in: transaction).records }
  }

  func card(of job: JobKey) async throws -> ProposalRecord? {
    let id = RefreshRecords.card(of: job.ref)
    return try await store.read { transaction in try ProposalRecord.read(id: id, in: transaction).entry?.record }
  }

  func proposals() async throws -> [ProposalState] {
    let novel = novel
    return try await store.read { transaction in try transaction.query { database in try ProposalState.filter(Column("novel") == novel).fetchAll(database) } }
  }

  /// The changes the unsent log holds for the job's card and report: one each per write.
  func writes(of job: JobKey) async throws -> (card: Int, report: Int) {
    let (card, report) = (NovelForgeKey.proposal(RefreshRecords.card(of: job.ref)), RefreshReportRecord.ref(RefreshRecords.report(of: job.ref)))
    let refs = try await store.pendingChanges(limit: Int.max).compactMap { change in (try? ChangeRecord(json: try CanonicalJSON.decode(change.line)))?.ref }
    return (refs.count { $0 == card }, refs.count { $0 == report })
  }

  func mara() async throws -> EntityRecord? {
    let novel = novel
    return try await store.read { transaction in try EntityRecord.read(novel: novel, entity: "mara", in: transaction).entry?.record }
  }

  func failure(_ result: AttemptResult) -> AttemptFailure? {
    guard case .settled(.failed(let failure)) = result else { return nil }
    return failure
  }

  var userPrompts: [String] { provider.requests.first?.messages.filter { $0.role == .user }.map(\.text) ?? [] }
}
