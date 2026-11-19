import Foundation
import NovelForgeCore
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

private struct ChatCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

enum ChatFixtureError: Error {
  case noBinding
}

/// A vault with one novel and a turn engine whose model is scripted. Messages stay under fifteen characters, so no session is named beside a turn and
/// every scripted call belongs to the turn.
@MainActor
struct ChatWorld {
  let store: VaultStore
  let novel: UUID
  let provider: ScriptedModelProvider
  let engine: ChatTurnEngine

  var context: NovelContext { NovelContext(store: store, novel: novel) }

  static func make(_ calls: [[ScriptedModelProvider.Step]] = [], granted: Bool = true, contentMode: ContentMode = .standard) async throws -> ChatWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in
      try Library.create(NewNovel(title: "Ashfall", contentMode: contentMode), in: &transaction)
    }
    let provider = ScriptedModelProvider(calls: calls)
    return ChatWorld(store: store, novel: novel, provider: provider, engine: try await engine(store: store, provider: provider, granted: granted))
  }

  /// A second engine over the same vault and model, as the app has after a restart.
  func relaunched() async throws -> ChatTurnEngine {
    try await Self.engine(store: store, provider: provider, granted: true)
  }

  func session() async throws -> UUID {
    try await store.createChatSession(novel: novel).id
  }

  func model(of session: UUID) -> ChatSessionModel {
    ChatSessionModel(session: session, context: context, engine: engine)
  }

  func grantConsent(host: String) async throws {
    let consent = ConsentDisclosure.novelText
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
    }
  }

  private static func engine(store: VaultStore, provider: ScriptedModelProvider, granted: Bool) async throws -> ChatTurnEngine {
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let router = TaskRouter(
      configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: ChatCredentials(), store: store,
      requestGuard: { ModelRequestGuard.hardLine(for: $0) })
    if granted {
      let consent = ConsentDisclosure.novelText
      try await store.write { transaction in
        try AIConsent.decide(.granted, provider: binding.host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
      }
    }
    return ChatTurnEngine(store: store, router: { router }, consent: ConsentDisclosure.novelText.requirement)
  }
}

enum ChatScript {
  static func reply(_ text: String) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(json(text))
  }

  /// A reply that shows `opening`, then waits `pause` before it finishes.
  static func paused(_ opening: String, then rest: String, for pause: Duration) -> [ScriptedModelProvider.Step] {
    let whole = json(opening + rest)
    let cut = whole.range(of: rest)?.lowerBound ?? whole.endIndex
    return [
      .event(.started(requestID: "req_scripted", generationID: nil)), .text(String(whole[..<cut])), .delay(pause), .text(String(whole[cut...])),
      .event(.finished(usage: TokenUsage(input: 10, output: 5), reportedCost: nil, stop: .endTurn)),
    ]
  }

  static func failing(_ error: ModelError) -> [ScriptedModelProvider.Step] {
    [.failure(error)]
  }

  private static func json(_ reply: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: ["reply": reply])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

@MainActor
enum ChatWait {
  static func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<12_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
  }
}

extension ChatSessionModel {
  var transcriptRoles: [StoredEnum<ChatRole>] { messages.compactMap(\.record?.role) }

  var lastReply: ChatMessageRecord? { messages.last { $0.record?.role == .known(.assistant) }?.record }

  var streamedText: String? {
    guard case .running(let turn) = display else { return nil }
    return turn.text
  }
}
