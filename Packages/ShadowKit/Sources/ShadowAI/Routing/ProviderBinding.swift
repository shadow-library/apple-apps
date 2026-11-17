import Foundation

public protocol ModelCredentialSource: Sendable {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential?
}

extension ModelCredentialSource {
  /// The loader an adapter takes; a missing key surfaces as `authentication`.
  public func credentialLoader(for provider: ModelProviderKind) -> @Sendable () async throws(ModelError) -> ProviderCredential {
    { () async throws(ModelError) -> ProviderCredential in
      guard let credential = await credential(for: provider) else { throw .authentication }
      return credential
    }
  }
}

public struct ProviderBinding: Sendable {
  public let origin: URL
  public let host: String
  public let provider: any ModelProvider

  /// For a provider other than the two adapters, or a test double; prefer `init?(anthropic:)` and `init?(openRouter:)`, which take the origin the adapter
  /// authorises and add retries. `provider` is used as given: wrap it in `RetryingProvider` so retried attempts reach the ledger as child entries.
  public init?(origin: URL, provider: any ModelProvider) {
    guard let host = origin.host(percentEncoded: false), let normalised = try? LedgerProvider.normalised(host) else { return nil }
    self.origin = origin
    self.host = normalised
    self.provider = provider
  }

  public init?(anthropic adapter: AnthropicProvider, retryPolicy: RetryPolicy = .init()) {
    self.init(origin: adapter.configuration.origin, provider: RetryingProvider(adapter, policy: retryPolicy))
  }

  public init?(openRouter adapter: OpenRouterProvider, retryPolicy: RetryPolicy = .init()) {
    self.init(origin: adapter.configuration.origin, provider: RetryingProvider(adapter, policy: retryPolicy))
  }
}
