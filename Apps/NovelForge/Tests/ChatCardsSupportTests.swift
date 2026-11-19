import Foundation
import NovelForgeCore
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForge

/// Replies whose structured answer carries a change set or a question, as the turn engine reads them.
enum ChatCardsScript {
  static let quotedMessage = "Mara is a smuggler who works the Saltgate docks."
  static let approveFirst = #"{"op":"action.approve_draft","chapter":1}"#

  static func reply(_ text: String, ops: [String] = [], question: String? = nil) -> [ScriptedModelProvider.Step] {
    var members = [#""reply":\#(quoted(text))"#]
    if !ops.isEmpty { members.append(#""changeSet":[\#(ops.joined(separator: ","))]"#) }
    if let question { members.append(#""question":\#(question)"#) }
    return ScriptedModelProvider.reply("{\(members.joined(separator: ","))}")
  }

  /// A place is Forge's idea, so it waits on a card.
  static func idea(_ key: String, _ name: String) -> String {
    #"{"op":"entity.upsert","entityKey":"\#(key)","type":"location","name":"\#(name)"}"#
  }

  /// A character quoted from `quotedMessage` goes straight in.
  static func quotedCharacter(_ key: String, _ name: String) -> String {
    #"{"op":"entity.upsert","entityKey":"\#(key)","type":"character","name":"\#(name)","status":"smuggler","quote":"\#(name) is a smuggler who works the Saltgate docks"}"#
  }

  private static func quoted(_ text: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data()
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
  }
}

/// One novel, one titled chat (so no turn names it with a model call) and the core-backed writer.
@MainActor
struct ChatCardsWorld {
  let chat: ChatWorld
  let session: UUID
  let writer: CoreChatProposalWriter

  var store: VaultStore { chat.store }
  var novel: UUID { chat.novel }
  var context: NovelContext { chat.context }

  /// `manual` (ask first) cards every change a reply suggests; `auto` applies what the author's words support.
  static func make(_ calls: [[ScriptedModelProvider.Step]], mode: ChatSessionMode = .manual) async throws -> ChatCardsWorld {
    let chat = try await ChatWorld.make(calls)
    let session = try await chat.store.createChatSession(novel: chat.novel, mode: mode).id
    try await chat.store.renameChatSession(session, novel: chat.novel, title: "Cards")
    return ChatCardsWorld(chat: chat, session: session, writer: CoreChatProposalWriter(store: chat.store))
  }

  func reply(to message: String) async throws -> ChatMessageRecord {
    try await ChatCardsTurns.reply(to: message, engine: chat.engine, store: store, session: session, novel: novel)
  }

  func card(_ proposal: UUID, writer: (any ChatProposalWriting)? = nil) -> ChatProposalCardModel {
    ChatProposalCardModel(proposal: proposal, context: context, writer: writer ?? self.writer)
  }

  func receipt(_ reply: ChatMessageRecord, writer: (any ChatProposalWriting)? = nil) throws -> ChatReceiptModel {
    ChatReceiptModel(proposal: try #require(reply.appliedProposal), reply: reply, context: context, writer: writer ?? self.writer)
  }
}

enum ChatCardsTurns {
  static func reply(to message: String, engine: ChatTurnEngine, store: VaultStore, session: UUID, novel: UUID) async throws -> ChatMessageRecord {
    let handle = try await engine.send(message, session: session, novel: novel)
    guard case .answered(let id) = await handle.outcome() else { throw ChatFixtureError.noBinding }
    return try await record(id, in: store)
  }

  static func record(_ id: UUID, in store: VaultStore) async throws -> ChatMessageRecord {
    try await store.read { transaction in try #require(try ChatMessageRecord.read(id: id, in: transaction).entry?.record) }
  }
}

/// Starts observing; the returned task is cancelled when the test is done with the model.
@MainActor
func observing(_ observe: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
  Task { await observe() }
}

private struct CardsCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

/// Two devices on one vault, each with its own scripted model and turn engine; a write reaches the other device once flushed and settled.
@MainActor
struct ChatCardsReplicas {
  let replicas: CausalReplicas
  let novel: UUID
  let session: UUID
  let stores: [VaultStore]
  let engines: [ChatTurnEngine]

  static func make(_ calls: [[[ScriptedModelProvider.Step]]], mode: ChatSessionMode) async throws -> ChatCardsReplicas {
    let reconciler = try NovelForgeReconciler(registry: NovelForgeStore.registry)
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: calls.count, registry: NovelForgeStore.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0xF31))
    let novel = try await replicas.write(0) { transaction in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    let first = await replicas.store(0)
    let session = try await first.createChatSession(novel: novel, mode: mode).id
    try await first.renameChatSession(session, novel: novel, title: "Cards")
    _ = try await replicas.write(0) { _ in }
    var stores = [VaultStore]()
    var engines = [ChatTurnEngine]()
    for (index, script) in calls.enumerated() {
      let store = await replicas.store(index)
      stores.append(store)
      engines.append(try await engine(store: store, provider: ScriptedModelProvider(calls: script)))
      _ = try await replicas.write(index) { _ in }
    }
    try await replicas.settle()
    return ChatCardsReplicas(replicas: replicas, novel: novel, session: session, stores: stores, engines: engines)
  }

  func flush(_ device: Int) async throws {
    _ = try await replicas.write(device) { _ in }
  }

  func settle() async throws {
    for device in stores.indices { try await flush(device) }
    try await replicas.settle()
  }

  func context(_ device: Int) -> NovelContext { NovelContext(store: stores[device], novel: novel) }

  func writer(_ device: Int) -> CoreChatProposalWriter { CoreChatProposalWriter(store: stores[device]) }

  private static func engine(store: VaultStore, provider: ScriptedModelProvider) async throws -> ChatTurnEngine {
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let router = TaskRouter(
      configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: CardsCredentials(), store: store,
      requestGuard: { ModelRequestGuard.hardLine(for: $0) })
    let consent = ConsentDisclosure.novelText
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: binding.host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
    }
    return ChatTurnEngine(store: store, router: { router }, consent: consent.requirement)
  }
}

/// A writer that answers from a script where one is queued and passes everything else to `base`, recording what the cards sent.
final class ScriptedProposalWriter: ChatProposalWriting {
  struct Undo: Equatable {
    let index: Int
    let idea: LedgerRejectionScope?
  }

  struct Revert: Equatable {
    let proposal: UUID
    let accepting: Set<Int>
  }

  private struct Script {
    var applies: [ChatApplyResult] = []
    var undoRefusals: [Int: [ChatCardRefusal]] = [:]
    var revertRefusals: [ChatCardRefusal] = []
    var rollbacks: [ChatRollbackResult] = []
    var undos: [Undo] = []
    var reverts: [Revert] = []
  }

  private let base: (any ChatProposalWriting)?
  private let script = Mutex(Script())

  init(base: (any ChatProposalWriting)? = nil) {
    self.base = base
  }

  var undos: [Undo] { script.withLock { $0.undos } }
  var reverts: [Revert] { script.withLock { $0.reverts } }

  func queueApply(_ result: ChatApplyResult) { script.withLock { $0.applies.append(result) } }
  func refuseUndo(of index: Int, _ refusal: ChatCardRefusal) { script.withLock { $0.undoRefusals[index, default: []].append(refusal) } }
  func refuseRevert(_ refusal: ChatCardRefusal) { script.withLock { $0.revertRefusals.append(refusal) } }
  func queueRollback(_ result: ChatRollbackResult) { script.withLock { $0.rollbacks.append(result) } }

  func apply(_ proposal: UUID, indexes: [Int], novel: UUID) async throws(ChatCardRefusal) -> ChatApplyResult {
    if let queued = script.withLock({ $0.applies.isEmpty ? nil : $0.applies.removeFirst() }) { return queued }
    return try await base?.apply(proposal, indexes: indexes, novel: novel) ?? .applied([])
  }

  func discard(_ proposal: UUID, novel: UUID) async throws(ChatCardRefusal) {
    try await base?.discard(proposal, novel: novel)
  }

  func undo(_ proposal: UUID, index: Int, idea: LedgerRejectionScope?, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> Bool {
    let refusal = script.withLock { state -> ChatCardRefusal? in
      state.undos.append(Undo(index: index, idea: idea))
      guard var queued = state.undoRefusals[index], !queued.isEmpty else { return nil }
      let first = queued.removeFirst()
      state.undoRefusals[index] = queued
      return first
    }
    if let refusal { throw refusal }
    return try await base?.undo(proposal, index: index, idea: idea, accepting: accepting, novel: novel) ?? true
  }

  func redo(_ proposal: UUID, index: Int, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> Bool {
    try await base?.redo(proposal, index: index, accepting: accepting, novel: novel) ?? true
  }

  func revert(_ proposal: UUID, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> [Int] {
    let refusal = script.withLock { state -> ChatCardRefusal? in
      state.reverts.append(Revert(proposal: proposal, accepting: accepting))
      return state.revertRefusals.isEmpty ? nil : state.revertRefusals.removeFirst()
    }
    if let refusal { throw refusal }
    return try await base?.revert(proposal, accepting: accepting, novel: novel) ?? []
  }

  func rollback(after anchor: UUID, novel: UUID) async throws(ChatCardRefusal) -> ChatRollbackResult {
    if let queued = script.withLock({ $0.rollbacks.isEmpty ? nil : $0.rollbacks.removeFirst() }) { return queued }
    return try await base?.rollback(after: anchor, novel: novel) ?? ChatRollbackResult(reverted: [], skipped: [])
  }

  func impact(of proposal: UUID, index: Int?, novel: UUID) async throws(ChatCardRefusal) -> ChatUndoImpact {
    try await base?.impact(of: proposal, index: index, novel: novel) ?? .none
  }
}

enum TestTimeLimit {
  static let standard = TimeLimitTrait.timeLimit(.minutes(10))
}
