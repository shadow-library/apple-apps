import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

private struct CompactionCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

enum CompactionWorld {
  static let anthropic = url("https://api.example.com")
  static let openRouter = url("https://router.example.com")
  static let consent = AIConsentRequirement(dataClass: "novel", disclosure: "novel-text/v1")
  static let unrestrictedModel = "or/unrestricted"

  static func url(_ text: String) -> URL {
    guard let url = URL(string: text) else { preconditionFailure("valid URL \(text)") }
    return url
  }

  static func turn(_ mode: ContentMode = .standard, novel: ContentMode = .standard) -> ChatCompactionTurn {
    ChatCompactionTurn(contentMode: mode, novelMode: novel, pace: .steady, consent: consent, unrestrictedAvailable: true)
  }

  /// Both providers answer from one script; a request for `unrestrictedModel` went the unrestricted route.
  static func router(_ provider: any ModelProvider, store: VaultStore) async throws -> TaskRouter {
    guard let standard = ProviderBinding(origin: anthropic, provider: provider), let unrestricted = ProviderBinding(origin: openRouter, provider: provider) else {
      preconditionFailure("valid bindings")
    }
    try await store.write { transaction in
      for host in [standard.host, unrestricted.host] {
        try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
      }
    }
    let configuration = TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: unrestrictedModel))
    return TaskRouter(
      configuration: configuration, anthropic: standard, openRouter: unrestricted, credentials: CompactionCredentials(), store: store,
      requestGuard: { ModelRequestGuard.hardLine(for: $0) })
  }

  static func reply(_ summary: String) -> [ScriptedModelProvider.Step] {
    let json = String(decoding: CanonicalJSON.encode(.object(["summary": .string(summary)])), as: UTF8.self)
    return ScriptedModelProvider.reply(json)
  }

  /// The fold's user text as sent: in prompt mode the structured call appends the schema instruction to it.
  static func sent(_ text: String, in request: ModelRequest) -> String {
    guard case .text = request.format else { return text }
    return text + "\n\n" + StructuredPrompt.schemaInstruction(name: "chat-compact", schema: JSONValue(schema: chatCompactSchema))
  }

  static func id(_ ordinal: Int) -> UUID {
    SchemaFixture.uuid(String(format: "6f0c4d1e-0000-4000-8000-%012d", ordinal))
  }

  static func window(_ session: UUID = ChatWorld.session, in store: VaultStore) async throws -> ChatConversationWindow {
    try await store.read { transaction in try ChatConversationWindow.load(session, in: transaction) }
  }

  static func compact(
    _ session: UUID = ChatWorld.session, turn: ChatCompactionTurn = turn(), store: VaultStore, provider: ScriptedModelProvider
  ) async throws -> ChatCompactionResult {
    let router = try await router(provider, store: store)
    return try await ChatCompaction.compactIfNeeded(session: session, turn: turn, store: store, router: router)
  }

  static func summaries(_ session: UUID = ChatWorld.session, in store: VaultStore) async throws -> [ChatSummaryRecord] {
    try await store.read { transaction in
      try ChatSummaryRecord.listing(session: session, novel: ChatWorld.novel, in: transaction).entries.map(\.record)
    }
  }

  /// Messages in order, one write: clocks rise with each append, so the transcript keeps the given order.
  static func write(_ messages: [ChatMessageRecord], summary: ChatSummaryRecord? = nil, in store: VaultStore) async throws {
    try await Projection.write(store) { transaction in
      _ = try ChatSessionRecord(id: ChatWorld.session, novel: ChatWorld.novel).create(in: &transaction)
      for message in messages { _ = try message.append(in: &transaction) }
      if let summary { _ = try summary.append(in: &transaction) }
    }
  }

  static func turns(_ count: Int, from first: Int = 1, mode: ContentMode = .standard, tokens: Int? = nil) throws -> [ChatMessageRecord] {
    try (first..<(first + count)).map { ordinal in
      try ChatMessageRecord(
        id: id(ordinal), novel: ChatWorld.novel, session: ChatWorld.session, role: ordinal.isMultiple(of: 2) ? .assistant : .user, content: "Message \(ordinal).",
        contentMode: mode, tokens: tokens)
    }
  }
}
