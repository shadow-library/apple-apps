import Foundation
import Observation
import ShadowAI
import ShadowKeychain
import ShadowNetworking
import ShadowStore

typealias CredentialValidation = @Sendable (ModelProviderKind, ProviderCredential) async throws(ModelError) -> CredentialStatus
typealias ModelListing = @Sendable () async throws(ModelError) -> [RemoteModel]

nonisolated struct AISettings: Equatable, Codable, Sendable {
  var provider: ModelProviderKind = .anthropic
  var assignments = OpenRouterAssignments()
  var limits = SpendLimits()
}

nonisolated struct AISettingsStore {
  private static let key = "novelforge.ai.settings.v1"

  let defaults: UserDefaults

  func load() -> AISettings {
    guard let data = defaults.data(forKey: Self.key), let settings = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
    return settings
  }

  func save(_ settings: AISettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

nonisolated struct ProviderKeys: ModelCredentialSource {
  private let store: any SecureStore
  private let origins: [ModelProviderKind: URL]

  init(store: any SecureStore, origins: [ModelProviderKind: URL]) {
    self.store = store
    self.origins = origins
  }

  static func standard(store: any SecureStore) -> ProviderKeys {
    ProviderKeys(store: store, origins: [.anthropic: AnthropicConfiguration.defaultOrigin, .openRouter: AIServices.openRouterConfiguration.origin])
  }

  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = origins[provider], let secret = try? store.string(forKey: Self.account(provider)) else { return nil }
    return ProviderCredential(origin: origin, secret: secret)
  }

  func makeCredential(_ secret: String, for provider: ModelProviderKind) -> ProviderCredential? {
    guard let origin = origins[provider] else { return nil }
    return ProviderCredential(origin: origin, secret: secret)
  }

  func contains(_ provider: ModelProviderKind) throws(SecureStoreError) -> Bool {
    try store.data(forKey: Self.account(provider)) != nil
  }

  func save(_ credential: ProviderCredential, for provider: ModelProviderKind) throws(SecureStoreError) {
    try store.setString(credential.secret, forKey: Self.account(provider))
  }

  func remove(_ provider: ModelProviderKind) throws(SecureStoreError) {
    try store.removeValue(forKey: Self.account(provider))
  }

  private static func account(_ provider: ModelProviderKind) -> String { "ai.\(provider.rawValue).api-key" }
}

nonisolated struct GrantedConsent: Equatable, Identifiable, Sendable {
  let provider: ModelProviderKind
  let host: String
  let disclosure: ConsentDisclosure

  var id: String { "\(host)|\(disclosure.dataClass)" }
}

@MainActor
@Observable
final class AIServices {
  nonisolated static let openRouterConfiguration = OpenRouterConfiguration(applicationTitle: "Novel Forge")
  nonisolated static let keychainService = "shadow.novelforge.ai"

  private(set) var settings: AISettings
  private(set) var openRouterModels: [RemoteModel] = []

  let keys: ProviderKeys
  private let settingsStore: AISettingsStore
  private let anthropic: ProviderBinding?
  private let openRouter: ProviderBinding?
  private let validation: CredentialValidation
  private let listing: ModelListing
  private let now: @Sendable () -> Date

  init(
    keys: ProviderKeys, settingsStore: AISettingsStore, transport: any HTTPTransport & HTTPStreamingTransport, validation: CredentialValidation? = nil,
    listing: ModelListing? = nil, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.keys = keys
    self.settingsStore = settingsStore
    self.settings = settingsStore.load()
    self.now = now
    anthropic = ProviderBinding(anthropic: AnthropicProvider(credential: keys.credentialLoader(for: .anthropic), transport: transport))
    openRouter = ProviderBinding(
      openRouter: OpenRouterProvider(configuration: Self.openRouterConfiguration, credential: keys.credentialLoader(for: .openRouter), transport: transport))
    self.validation = validation ?? Self.liveValidation(transport: transport)
    self.listing =
      listing ?? { () async throws(ModelError) -> [RemoteModel] in
        try await OpenRouterProvider(configuration: Self.openRouterConfiguration, credential: keys.credentialLoader(for: .openRouter), transport: transport).models()
      }
  }

  nonisolated static func keychain() -> KeychainStore { KeychainStore(service: keychainService, scope: .synced()) }

  static func live(defaults: UserDefaults = .standard) -> AIServices {
    AIServices(keys: .standard(store: keychain()), settingsStore: AISettingsStore(defaults: defaults), transport: URLSessionTransport())
  }

  func router(store: VaultStore) -> TaskRouter {
    let configuration = TaskRouterConfiguration(
      provider: settings.provider, assignments: settings.assignments, openRouterModels: openRouterModels, spendLimits: settings.limits)
    return TaskRouter(configuration: configuration, anthropic: anthropic, openRouter: openRouter, credentials: keys, store: store)
  }

  func update(_ change: (inout AISettings) -> Void) {
    var updated = settings
    change(&updated)
    guard updated != settings else { return }
    settings = updated
    settingsStore.save(updated)
  }

  func validate(_ credential: ProviderCredential, for provider: ModelProviderKind) async throws(ModelError) -> CredentialStatus {
    try await validation(provider, credential)
  }

  func refreshOpenRouterModels() async throws(ModelError) {
    openRouterModels = try await listing()
  }

  func loadOpenRouterModelsIfKeyed() async {
    guard (try? keys.contains(.openRouter)) == true else { return }
    try? await refreshOpenRouterModels()
  }

  func forgetOpenRouterModels() {
    openRouterModels = []
  }

  func grant(_ request: AIConsentRequest, in store: VaultStore) async throws(StoreError) {
    try await decide(.granted, provider: request.host, dataClass: request.dataClass, disclosure: request.disclosure, in: store)
  }

  func revoke(_ consent: GrantedConsent, in store: VaultStore) async throws(StoreError) {
    try await decide(.revoked, provider: consent.host, dataClass: consent.disclosure.dataClass, disclosure: consent.disclosure.id, in: store)
  }

  func grantedConsents(in store: VaultStore) async throws(StoreError) -> [GrantedConsent] {
    let hosts = bindings.map { (provider: $0.provider, host: $0.binding.host) }
    return try await store.read { transaction in
      var granted: [GrantedConsent] = []
      for (provider, host) in hosts {
        for disclosure in ConsentDisclosure.allCases where try AIConsent.isGranted(provider: host, dataClass: disclosure.dataClass, currentSummary: disclosure.id, in: transaction)
        {
          granted.append(GrantedConsent(provider: provider, host: host, disclosure: disclosure))
        }
      }
      return granted
    }
  }

  private var bindings: [(provider: ModelProviderKind, binding: ProviderBinding)] {
    [(ModelProviderKind.anthropic, anthropic), (.openRouter, openRouter)].compactMap { provider, binding in binding.map { (provider, $0) } }
  }

  private func decide(_ state: AIConsentState, provider: String, dataClass: String, disclosure: String, in store: VaultStore) async throws(StoreError) {
    let millis = Int64((now().timeIntervalSince1970 * 1_000).rounded())
    try await store.write { transaction in
      try AIConsent.decide(state, provider: provider, dataClass: dataClass, summary: disclosure, atMillis: millis, in: &transaction)
    }
  }

  private static func liveValidation(transport: any HTTPTransport & HTTPStreamingTransport) -> CredentialValidation {
    { (provider, credential) async throws(ModelError) -> CredentialStatus in
      let loader: @Sendable () async throws(ModelError) -> ProviderCredential = { credential }
      switch provider {
      case .anthropic: return try await AnthropicProvider(credential: loader, transport: transport).validate(credential)
      case .openRouter: return try await OpenRouterProvider(configuration: openRouterConfiguration, credential: loader, transport: transport).validate(credential)
      }
    }
  }
}
