import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore

/// A vault in a file that the tests open again as a relaunched app does: a crash leaves the file as its last committed transaction left it.
struct CrashVault: Sendable {
  let url: URL
  let clock = OperationClock()

  /// StagingWorld's novel (and with `workspace`, its chapters 1-2 final and chapter 3 drafted) with an active chat in `auto` mode.
  static func make(workspace: Bool = false, sessions: [UUID] = [EngineWorld.session]) async throws -> CrashVault {
    let vault = CrashVault(url: FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)").appending(path: "vault.sqlite"))
    let book = try vault.open()
    let novel = book.novel
    try await book.run { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "tide", revealChapter: 5, in: &transaction)
      try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
    }
    if workspace {
      try await book.finalized(through: 2)
      try await book.draft(3, StagingText.body)
    }
    try await book.run { transaction in
      for session in sessions { _ = try ChatSessionRecord(id: session, novel: novel).create(in: &transaction) }
    }
    return vault
  }

  func open() throws -> ChapterBook {
    ChapterBook(store: try NovelForgeStore.open(at: url, wallClock: clock.function), clock: clock)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}

/// A model provider a crash can stop mid-call: a frozen call yields its steps and then never answers, as a request in flight when the process ended, so
/// the run that sent it writes nothing more. Title requests take their own script, so the title call beside a turn can be frozen or answered on its own.
final class KillableProvider: ModelProvider {
  enum Call: Sendable {
    case answer([ScriptedModelProvider.Step])
    case freeze([ScriptedModelProvider.Step])
  }

  private struct State {
    var turns: [Call]
    var titles: [Call]
    var turnRequests: [ModelRequest] = []
    var titleRequests: [ModelRequest] = []
    var frozen = 0
  }

  private let state: Mutex<State>
  private let turnsWait: Signal?

  init(turns: [Call], titles: [Call] = [], turnsWait: Signal? = nil) {
    state = Mutex(State(turns: turns, titles: titles))
    self.turnsWait = turnsWait
  }

  var turnRequests: [ModelRequest] { state.withLock { $0.turnRequests } }
  var titleRequests: [ModelRequest] { state.withLock { $0.titleRequests } }
  var frozen: Int { state.withLock { $0.frozen } }

  func waitFrozen(_ count: Int = 1) async throws {
    try await EngineWorld.eventually("\(count) model calls are in flight") { [self] in frozen >= count }
  }

  func stream(_ request: ModelRequest) -> ModelStream {
    let title = request.system.contains { $0.text == chatTitleSystem }
    return ModelStream { [self] continuation throws(ModelError) in
      if !title { await turnsWait?.wait() }
      let call = state.withLock { state -> Call? in
        if title {
          state.titleRequests.append(request)
          return state.titles.isEmpty ? nil : state.titles.removeFirst()
        }
        state.turnRequests.append(request)
        return state.turns.isEmpty ? nil : state.turns.removeFirst()
      }
      guard let call else { throw .invalidRequest("KillableProvider: no script for this \(title ? "title" : "turn") call") }
      switch call {
      case .answer(let steps):
        for try await event in ScriptedModelProvider(calls: [steps]).stream(request) { try continuation.yield(event) }
      case .freeze(let steps):
        for try await event in ScriptedModelProvider(calls: [steps]).stream(request) { try continuation.yield(event) }
        state.withLock { $0.frozen += 1 }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
      }
    }
  }

  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    .valid(label: nil)
  }

  func models() async throws(ModelError) -> [RemoteModel] {
    []
  }
}

private struct CrashCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

/// What a session's chat left in the vault, without ids: the transcript, the proposals and their change records, and the content hashes of the records the
/// turns touch. A turn resumed after a crash leaves the same footprint as one that never stopped.
struct ChatFootprint: Equatable, CustomStringConvertible {
  let transcript: [String]
  let proposals: [String]
  let changeRows: Int
  let hashes: [String]

  var description: String {
    "transcript=\(transcript) proposals=\(proposals) changeRows=\(changeRows) hashes=\(hashes)"
  }
}

enum CrashWorld {
  static let refs = ["entity:mara", "milestone:rise"]

  /// The engine as a relaunched app builds it, over `provider`. Its session upkeep records the naming it is asked for unless `upkeep` is given; `routing`
  /// runs each time a turn asks for its router.
  static func engine(
    _ store: VaultStore, provider: any ModelProvider, faults: ChatTurnEngine.Faults = .none, flush: Duration = .seconds(3_600), upkeep: ChatSessionUpkeep? = nil,
    routing: @escaping @Sendable () async -> Void = {}
  ) async throws -> ChatTurnEngine {
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
      anthropic: standard, openRouter: unrestricted, credentials: CrashCredentials(), store: store, requestGuard: { ModelRequestGuard.hardLine(for: $0) })
    let timing = ChatTurnEngine.Timing(flushInterval: flush, monotonic: { ProcessInfo.processInfo.systemUptime * 1000 }, now: { Date() })
    return ChatTurnEngine(
      store: store,
      router: {
        await routing()
        return router
      }, consent: consent, upkeep: upkeep ?? RecordedUpkeep().seam, timing: timing, faults: faults,
      unrestrictedAvailable: true)
  }

  /// The session upkeep of the vault, raising `named` once a naming finished.
  static func naming(_ store: VaultStore, named: Signal) -> ChatSessionUpkeep {
    let vault = ChatSessionUpkeep.vault(store)
    return ChatSessionUpkeep(
      nameSession: { session, novel, opening, turn, router in
        let calls = await vault.nameSession(session, novel, opening, turn, router)
        named.raise()
        return calls
      }, forgetRemovedChats: vault.forgetRemovedChats)
  }

  static func split() -> [ScriptedModelProvider.Step] {
    EngineWorld.reply(("reply", EngineWorld.text("Done — I noted it.")), ("changeSet", "[\(EngineWorld.maraThief),\(EngineWorld.removeRise)]"))
  }

  static func lookup() -> [ScriptedModelProvider.Step] {
    EngineWorld.reply(("reply", EngineWorld.text("Checking.")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#))
  }

  static func titled(_ text: String) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(.object(["title": .string(text)])), as: UTF8.self))
  }

  static let shown: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thinking it over. "#)]

  static func footprint(_ session: UUID = EngineWorld.session, novel: UUID = SchemaFixture.novel, in store: VaultStore) async throws -> ChatFootprint {
    let messages = try await EngineWorld.messages(session, in: store)
    let transcript = messages.map { message in
      let role = message.role.known.map { "\($0)" } ?? "?"
      let answers = message.answers.flatMap { id in messages.firstIndex { $0.id == id } }.map { " answers #\($0)" } ?? ""
      let links = "\(message.appliedProposal == nil ? "" : " applied")\(message.cardProposal == nil ? "" : " card")"
      return "\(role)\(answers): \(message.content)\(links)\(message.applyNote.map { " note: \($0)" } ?? "")"
    }
    return try await store.read { transaction in
      let proposals = try ProposalRecord.listing(in: transaction).entries.map(\.record).map { proposal in
        let ops = proposal.card.changeSet.compactMap(\.op).map(\.type.rawValue).joined(separator: ",")
        return "\(proposal.decision.known.map { "\($0)" } ?? "unknown") automatic=\(proposal.application?.automatic.description ?? "-") ops=\(ops)"
      }
      let rows = try ProposalChangeRow.fetchCount(transaction.database)
      let states = try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction)
      let hashes = refs.map { "\($0)=\(states[JSString($0)]?.contentHash ?? "none")" }
      return ChatFootprint(transcript: transcript, proposals: proposals.sorted(), changeRows: rows, hashes: hashes)
    }
  }

  /// The footprint of the same conversation run once, without a crash, on a vault of its own.
  static func uncrashed(
    _ script: [[ScriptedModelProvider.Step]], message: String = EngineWorld.message, workspace: Bool = false, prepare: @Sendable (ChapterBook) async throws -> Void = { _ in }
  ) async throws -> ChatFootprint {
    let book = try await EngineWorld.book(workspace: workspace)
    try await prepare(book)
    let engine = try await EngineWorld.engine(book.store, provider: ScriptedModelProvider(calls: script))
    _ = try EngineWorld.reply(of: await engine.send(message, session: EngineWorld.session, novel: book.novel).outcome())
    return try await footprint(in: book.store)
  }

  static func sequences(_ frames: [TurnFrame]) -> [Int] {
    frames.map(\.sequence)
  }

  static func contiguous(_ count: Int) -> [Int] {
    (0..<count).map { $0 + 1 }
  }

  static func hasDelta(_ frames: [TurnFrame]) -> Bool {
    frames.contains { $0.event == .delta }
  }

  /// What a launch would resume of the applies stopped between their content and their actions: the applied cards with an action still pending.
  static func interruptedApplies(in store: VaultStore) async throws -> [UUID] {
    try await store.read { transaction in
      let pending = StoredEnum<ProposalChangeStatus>.known(.pending).rawValue
      let ids = try ProposalChangeRow.filter(Column("outcome") == pending).fetchAll(transaction.database).map(\.proposal)
      return try Array(Set(ids)).filter { id in
        guard case .readable(let entry) = try ProposalRecord.read(id: id, in: transaction) else { return false }
        return entry.record.decision == .known(.applied)
      }
    }
  }

  static func turnRows(in store: VaultStore) async throws -> Int {
    try await store.read { transaction in
      guard try transaction.database.tableExists(ChatTurnRecords.table) else { return 0 }
      return try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM \(ChatTurnRecords.table)") ?? 0
    }
  }

  /// Every trace of one finished turn: no pending turn, no turn record or staging step, and the transcript idle.
  static func expectSettled(_ engine: ChatTurnEngine, _ store: VaultStore, session: UUID = EngineWorld.session, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    #expect(try await store.pendingLocalTurns().isEmpty, sourceLocation: sourceLocation)
    #expect(try await turnRows(in: store) == 0, sourceLocation: sourceLocation)
    #expect(try await EngineWorld.stepRows(in: store) == 0, sourceLocation: sourceLocation)
    #expect(try await engine.activity(session: session) == .idle, sourceLocation: sourceLocation)
  }

  /// One reply for each author message, and no other message.
  static func expectOneReplyPerMessage(_ store: VaultStore, session: UUID = EngineWorld.session, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let messages = try await EngineWorld.messages(session, in: store)
    let users = messages.filter { $0.role == .known(.user) }
    for user in users {
      #expect(messages.count { $0.answers == user.id } == 1, "replies to \(user.content)", sourceLocation: sourceLocation)
    }
    #expect(messages.count == users.count * 2, sourceLocation: sourceLocation)
  }
}
