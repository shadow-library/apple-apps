import Foundation
import Observation
import ShadowAI
import ShadowKeychain
import ShadowNetworking
import ShadowStore

public typealias CredentialValidation = @Sendable (ModelProviderKind, ProviderCredential) async throws(ModelError) -> CredentialStatus
public typealias ModelListing = @Sendable () async throws(ModelError) -> [RemoteModel]

public nonisolated struct AISettings: Equatable, Codable, Sendable {
  public var provider: ModelProviderKind = .anthropic
  public var assignments = OpenRouterAssignments()
  public var limits = SpendLimits()
}

public nonisolated struct AISettingsStore {
  public let key: String
  public let defaults: UserDefaults

  public init(identity: AppIdentity, defaults: UserDefaults) {
    key = identity.aiSettingsKey
    self.defaults = defaults
  }

  public func load() -> AISettings {
    guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
    return settings
  }

  public func save(_ settings: AISettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: key)
  }
}

public nonisolated struct ProviderKeys: ModelCredentialSource {
  private let store: any SecureStore
  private let origins: [ModelProviderKind: URL]

  public init(store: any SecureStore, origins: [ModelProviderKind: URL]) {
    self.store = store
    self.origins = origins
  }

  public static func standard(store: any SecureStore) -> ProviderKeys {
    ProviderKeys(store: store, origins: [.anthropic: AnthropicConfiguration.defaultOrigin, .openRouter: OpenRouterConfiguration.defaultOrigin])
  }

  public func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = origins[provider], let secret = try? store.string(forKey: Self.account(provider)) else { return nil }
    return ProviderCredential(origin: origin, secret: secret)
  }

  public func makeCredential(_ secret: String, for provider: ModelProviderKind) -> ProviderCredential? {
    guard let origin = origins[provider] else { return nil }
    return ProviderCredential(origin: origin, secret: secret)
  }

  public func contains(_ provider: ModelProviderKind) throws(SecureStoreError) -> Bool {
    try store.data(forKey: Self.account(provider)) != nil
  }

  public func save(_ credential: ProviderCredential, for provider: ModelProviderKind) throws(SecureStoreError) {
    try store.setString(credential.secret, forKey: Self.account(provider))
  }

  public func remove(_ provider: ModelProviderKind) throws(SecureStoreError) {
    try store.removeValue(forKey: Self.account(provider))
  }

  private static func account(_ provider: ModelProviderKind) -> String { "ai.\(provider.rawValue).api-key" }
}

public nonisolated struct GrantedConsent: Equatable, Identifiable, Sendable {
  public let provider: ModelProviderKind
  public let host: String
  public let disclosure: ConsentDisclosure

  public var id: String { "\(host)|\(disclosure.dataClass)" }
}

@MainActor
@Observable
public final class AIServices {
  public typealias RequestGuard = @Sendable (ModelRoute) -> ModelRequestGuard?

  public let identity: AppIdentity
  public let openRouterConfiguration: OpenRouterConfiguration
  /// The screens every route gets unless a caller names its own, such as an app's hard-line screens.
  public let requestGuard: RequestGuard
  /// The kinds of data the app asks consent to send, as granted consents are listed and revoked.
  public let disclosures: [ConsentDisclosure]
  public private(set) var settings: AISettings
  public private(set) var openRouterModels: [RemoteModel] = []

  public let keys: ProviderKeys
  private let settingsStore: AISettingsStore
  private let anthropic: ProviderBinding?
  private let openRouter: ProviderBinding?
  private let validation: CredentialValidation
  private let listing: ModelListing
  private let now: @Sendable () -> Date
  private let costLookup: OpenRouterGenerationLookup
  private var settlers: [ObjectIdentifier: CostSettler] = [:]

  public init(
    identity: AppIdentity, keys: ProviderKeys, settingsStore: AISettingsStore, transport: any HTTPTransport & HTTPStreamingTransport,
    disclosures: [ConsentDisclosure], requestGuard: @escaping RequestGuard, validation: CredentialValidation? = nil,
    listing: ModelListing? = nil, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let openRouterConfiguration = OpenRouterConfiguration(applicationTitle: identity.displayName)
    self.identity = identity
    self.openRouterConfiguration = openRouterConfiguration
    self.requestGuard = requestGuard
    self.disclosures = disclosures
    self.keys = keys
    self.settingsStore = settingsStore
    self.settings = settingsStore.load()
    self.now = now
    costLookup = OpenRouterGenerationLookup(
      configuration: openRouterConfiguration, credential: keys.credentialLoader(for: .openRouter), transport: transport)
    anthropic = ProviderBinding(anthropic: AnthropicProvider(credential: keys.credentialLoader(for: .anthropic), transport: transport))
    openRouter = ProviderBinding(
      openRouter: OpenRouterProvider(configuration: openRouterConfiguration, credential: keys.credentialLoader(for: .openRouter), transport: transport))
    self.validation = validation ?? Self.liveValidation(configuration: openRouterConfiguration, transport: transport)
    self.listing =
      listing ?? { () async throws(ModelError) -> [RemoteModel] in
        try await OpenRouterProvider(configuration: openRouterConfiguration, credential: keys.credentialLoader(for: .openRouter), transport: transport).models()
      }
  }

  public nonisolated static func keychain(identity: AppIdentity) -> KeychainStore { KeychainStore(service: identity.aiKeychainService, scope: .synced()) }

  public static func live(
    identity: AppIdentity, disclosures: [ConsentDisclosure], requestGuard: @escaping RequestGuard, defaults: UserDefaults = .standard
  ) -> AIServices {
    AIServices(
      identity: identity, keys: .standard(store: keychain(identity: identity)), settingsStore: AISettingsStore(identity: identity, defaults: defaults),
      transport: URLSessionTransport(), disclosures: disclosures, requestGuard: requestGuard)
  }

  public func router(store: VaultStore) -> TaskRouter {
    router(store: store, requestGuard: requestGuard)
  }

  public func router(store: VaultStore, requestGuard: @escaping RequestGuard) -> TaskRouter {
    let configuration = TaskRouterConfiguration(
      provider: settings.provider, assignments: settings.assignments, openRouterModels: openRouterModels, spendLimits: settings.limits)
    return TaskRouter(configuration: configuration, anthropic: anthropic, openRouter: openRouter, credentials: keys, store: store, requestGuard: requestGuard)
  }

  public func settler(for store: VaultStore) -> CostSettler {
    let key = ObjectIdentifier(store)
    if let existing = settlers[key] { return existing }
    for stale in settlers.values { stale.shutDown() }
    let created = CostSettler(store: store, lookup: costLookup)
    settlers = [key: created]
    return created
  }

  public func update(_ change: (inout AISettings) -> Void) {
    var updated = settings
    change(&updated)
    guard updated != settings else { return }
    settings = updated
    settingsStore.save(updated)
  }

  public func validate(_ credential: ProviderCredential, for provider: ModelProviderKind) async throws(ModelError) -> CredentialStatus {
    try await validation(provider, credential)
  }

  public func refreshOpenRouterModels() async throws(ModelError) {
    openRouterModels = try await listing()
  }

  public func loadOpenRouterModelsIfKeyed() async {
    guard (try? keys.contains(.openRouter)) == true else { return }
    try? await refreshOpenRouterModels()
  }

  public func forgetOpenRouterModels() {
    openRouterModels = []
  }

  public func grant(_ request: AIConsentRequest, in store: VaultStore) async throws(StoreError) {
    try await decide(.granted, provider: request.host, dataClass: request.dataClass, disclosure: request.disclosure, in: store)
  }

  public func revoke(_ consent: GrantedConsent, in store: VaultStore) async throws(StoreError) {
    try await decide(.revoked, provider: consent.host, dataClass: consent.disclosure.dataClass, disclosure: consent.disclosure.id, in: store)
  }

  public func grantedConsents(in store: VaultStore) async throws(StoreError) -> [GrantedConsent] {
    let hosts = bindings.map { (provider: $0.provider, host: $0.binding.host) }
    let disclosures = disclosures
    return try await store.read { transaction in
      var granted: [GrantedConsent] = []
      for (provider, host) in hosts {
        for disclosure in disclosures where try AIConsent.isGranted(provider: host, dataClass: disclosure.dataClass, currentSummary: disclosure.id, in: transaction) {
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

  private static func liveValidation(configuration: OpenRouterConfiguration, transport: any HTTPTransport & HTTPStreamingTransport) -> CredentialValidation {
    { (provider, credential) async throws(ModelError) -> CredentialStatus in
      let loader: @Sendable () async throws(ModelError) -> ProviderCredential = { credential }
      switch provider {
      case .anthropic: return try await AnthropicProvider(credential: loader, transport: transport).validate(credential)
      case .openRouter: return try await OpenRouterProvider(configuration: configuration, credential: loader, transport: transport).validate(credential)
      }
    }
  }
}
