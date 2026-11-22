import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Synchronization
import Testing

@testable import NovelForgeCore

/// A session upkeep that records what it was asked instead of naming sessions or clearing deleted chats.
final class RecordedUpkeep: Sendable {
  private let state = Mutex<(named: [UUID], forgot: Int, events: [String])>(([], 0, []))
  let titleCalls: [UUID]
  private let recorded: Signal?

  /// `recorded` is raised once each naming was recorded.
  init(titleCalls: [UUID] = [], recorded: Signal? = nil) {
    self.titleCalls = titleCalls
    self.recorded = recorded
  }

  var named: [UUID] { state.withLock { $0.named } }
  var forgot: Int { state.withLock { $0.forgot } }

  var seam: ChatSessionUpkeep {
    ChatSessionUpkeep(
      nameSession: { [self] _, _, opening, _, _ in
        state.withLock { $0.named.append(opening) }
        recorded?.raise()
        return titleCalls
      },
      forgetRemovedChats: { [self] () throws(StoreError) in state.withLock { $0.forgot += 1 } })
  }
}

/// A flag a test raises once something has happened, and a provider can wait on.
final class Signal: Sendable {
  private let raised = Mutex(false)

  func raise() {
    raised.withLock { $0 = true }
  }

  func wait() async {
    while !raised.withLock({ $0 }) {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

/// Sends a chat-title request to `titles` and every other request to `turns`, so the title naming that overlaps a turn takes its own script; a turn's
/// request waits for `turnsWait` first.
struct TitleSplittingProvider: ModelProvider {
  let titles: ScriptedModelProvider
  let turns: ScriptedModelProvider
  let turnsWait: Signal?

  func stream(_ request: ModelRequest) -> ModelStream {
    if request.system.contains(where: { $0.text == chatTitleSystem }) { return titles.stream(request) }
    let (turns, wait) = (turns, turnsWait)
    return ModelStream { continuation throws(ModelError) in
      await wait?.wait()
      for try await event in turns.stream(request) { try continuation.yield(event) }
    }
  }

  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    try await turns.validate(credential)
  }

  func models() async throws(ModelError) -> [RemoteModel] {
    try await turns.models()
  }
}

private struct EngineCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

enum EngineWorld {
  static let session = ChatWorld.session
  static let message = "Mara is a thief who works the Saltgate docks."
  static let maraThief = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","status":"thief","quote":"Mara is a thief who works the Saltgate docks"}"#
  static let removeRise = #"{"op":"milestone.remove","milestoneKey":"rise"}"#

  /// StagingWorld's novel with an active chat in `auto` mode.
  static func book(workspace: Bool = false) async throws -> ChapterBook {
    let book = workspace ? try await StagingWorld.workspace() : try await StagingWorld.book()
    let novel = book.novel
    try await book.run { transaction in _ = try ChatSessionRecord(id: session, novel: novel).create(in: &transaction) }
    return book
  }

  static func engine(
    _ store: VaultStore, provider: ScriptedModelProvider, upkeep: RecordedUpkeep = RecordedUpkeep(), now: @escaping @Sendable () -> Date = { Date() },
    faults: ChatTurnEngine.Faults = .none, unrestrictedAvailable: Bool = true, turnsWait: Signal? = nil,
    embedders: (any EmbedderProvider)? = nil
  ) async throws -> ChatTurnEngine {
    let gated: any ModelProvider = turnsWait.map { TitleSplittingProvider(titles: provider, turns: provider, turnsWait: $0) } ?? provider
    let router = try await CompactionWorld.router(gated, store: store)
    let timing = ChatTurnEngine.Timing(flushInterval: .seconds(3_600), monotonic: ChatTurnEngine.Timing.standard.monotonic, now: now)
    return ChatTurnEngine(
      store: store, router: { router }, consent: CompactionWorld.consent, upkeep: upkeep.seam, timing: timing, faults: faults,
      unrestrictedAvailable: unrestrictedAvailable, embedders: embedders)
  }

  /// `fault` at `point`, the first `times` times the run reaches it.
  static func faults(_ fault: ChatTurnEngine.Faults.Fault, at point: ChatTurnEngine.Faults.Point, times: Int = 1) -> ChatTurnEngine.Faults {
    let left = Mutex(times)
    return ChatTurnEngine.Faults { reached in
      guard reached == point else { return nil }
      return left.withLock { left in
        guard left > 0 else { return nil }
        left -= 1
        return fault
      }
    }
  }

  static func stepRows(in store: VaultStore) async throws -> Int {
    try await store.read { transaction in
      guard try transaction.database.tableExists(TurnStagingMarks.table) else { return 0 }
      return try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM \(TurnStagingMarks.table)") ?? 0
    }
  }

  static func steps(of reply: UUID, in store: VaultStore) async throws -> [TurnStagingStep]? {
    try await store.read { transaction in try TurnStagingMarks.steps(of: reply, in: transaction.database) }
  }

  static func proposalCount(in store: VaultStore) async throws -> Int {
    try await store.read { try ProposalRecord.listing(in: $0).entries.count }
  }

  /// The engine as the app builds it, its session upkeep the vault's own, over a provider of any kind.
  static func vaultEngine(_ store: VaultStore, provider: any ModelProvider, named: Signal? = nil) async throws -> ChatTurnEngine {
    guard let standard = ProviderBinding(origin: CompactionWorld.anthropic, provider: provider),
      let unrestricted = ProviderBinding(origin: CompactionWorld.openRouter, provider: provider)
    else { throw EngineTestError.noBinding }
    let consent = CompactionWorld.consent
    try await store.write { transaction in
      for host in [standard.host, unrestricted.host] {
        try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
      }
    }
    let router = TaskRouter(
      configuration: TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: CompactionWorld.unrestrictedModel)),
      anthropic: standard, openRouter: unrestricted, credentials: EngineCredentials(), store: store, requestGuard: { ModelRequestGuard.hardLine(for: $0) })
    guard let named else { return ChatTurnEngine(store: store, router: { router }, consent: consent) }
    let vault = ChatSessionUpkeep.vault(store)
    let upkeep = ChatSessionUpkeep(
      nameSession: { session, novel, opening, turn, router in
        let calls = await vault.nameSession(session, novel, opening, turn, router)
        named.raise()
        return calls
      }, forgetRemovedChats: vault.forgetRemovedChats)
    return ChatTurnEngine(store: store, router: { router }, consent: consent, upkeep: upkeep)
  }

  /// One model reply holding the JSON object of `fields`, in order.
  static func reply(_ fields: (String, String)...) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply("{" + fields.map { "\(OrderedJSON.string($0.0).jsonText):\($0.1)" }.joined(separator: ",") + "}")
  }

  static func text(_ value: String) -> String {
    OrderedJSON.string(value).jsonText
  }

  static func messages(_ session: UUID = session, in store: VaultStore) async throws -> [ChatMessageRecord] {
    try await store.read { transaction in try ChatTranscript.messages(of: session, in: transaction).compactMap(\.record) }
  }

  static func events(_ handle: ChatTurnHandle) async -> [TurnStreamEvent] {
    var events = [TurnStreamEvent]()
    for await event in handle.events { events.append(event) }
    return events
  }

  static func localTurn(_ id: UUID, in store: VaultStore) async throws -> LocalTurn? {
    try await store.localTurn(id)
  }

  static func record(_ turn: UUID, in store: VaultStore) async throws -> ChatTurnRecord? {
    try await store.read { transaction in try ChatTurnRecords.load(turn, in: transaction.database) }
  }

  static func proposals(of reply: UUID, in store: VaultStore) async throws -> [ProposalRecord] {
    try await store.read { transaction in try ProposalRecord.listing(in: transaction).entries.map(\.record).filter { $0.card.message == reply } }
  }

  /// Waits for `condition` on the store, polling; a turn that never gets there fails the test at the deadline.
  static func eventually(_ what: String, _ condition: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<6_000 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("never: \(what)")
  }

  static func reply(of outcome: ChatTurnOutcome) throws -> UUID {
    guard case .answered(let reply) = outcome else { throw EngineTestError.notAnswered(outcome) }
    return reply
  }
}

enum EngineTestError: Error {
  case notAnswered(ChatTurnOutcome)
  case noBinding
}
