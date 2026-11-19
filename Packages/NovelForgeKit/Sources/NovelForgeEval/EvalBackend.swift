import Foundation
import ShadowAI
import ShadowCore
import ShadowNetworking
import ShadowStore

struct EvalBackend: Sendable {
  static let consent = AIConsentRequirement(dataClass: "novel", disclosure: "novel-text/v1")

  private struct Credentials: ModelCredentialSource {
    let origin: URL
    let secret: String

    func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
      guard provider == .anthropic else { return nil }
      return ProviderCredential(origin: origin, secret: secret)
    }
  }

  let binding: ProviderBinding
  private let credentials: any ModelCredentialSource

  init(provider: any ModelProvider, origin: URL, secret: String) throws(EvalError) {
    guard let binding = ProviderBinding(origin: origin, provider: provider) else { throw .setup("The provider origin \(origin.absoluteString) has no host.") }
    self.binding = binding
    credentials = Credentials(origin: origin, secret: secret)
  }

  static func live(environment: [String: String]) throws(EvalError) -> EvalBackend {
    guard let name = environment[EvalEnvironment.provider], let secret = environment[EvalEnvironment.apiKey], !name.isEmpty, !secret.isEmpty else { throw .providerNotConfigured }
    guard name == "anthropic" else { throw .unsupportedProvider(name) }
    let configuration = AnthropicConfiguration()
    let origin = configuration.origin
    guard let credential = ProviderCredential(origin: origin, secret: secret) else { throw .setup("The Anthropic key cannot be used with \(origin.absoluteString).") }
    let provider = AnthropicProvider(configuration: configuration, credential: { credential }, transport: URLSessionTransport())
    return try EvalBackend(provider: provider, origin: origin, secret: secret)
  }

  func router(store: VaultStore, requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard?) -> TaskRouter {
    TaskRouter(configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, credentials: credentials, store: store, requestGuard: requestGuard)
  }

  func grantConsent(in store: VaultStore) async throws(EvalError) {
    let host = binding.host
    do {
      try await store.write { transaction in
        try AIConsent.decide(.granted, provider: host, dataClass: Self.consent.dataClass, summary: Self.consent.disclosure, atMillis: 1, in: &transaction)
      }
    } catch {
      throw .setup("Consent could not be recorded: \(error.code)")
    }
  }

  func requireConsent(in store: VaultStore) async throws(EvalError) {
    let host = binding.host
    let granted: Bool
    do {
      granted = try await store.read { transaction in
        try AIConsent.isGranted(provider: host, dataClass: Self.consent.dataClass, currentSummary: Self.consent.disclosure, in: transaction)
      }
    } catch {
      throw .setup("Consent could not be read: \(error.code)")
    }
    guard granted else { throw .consentMissing(host) }
  }
}
