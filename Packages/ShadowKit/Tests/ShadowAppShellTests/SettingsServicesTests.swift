import Foundation
import ShadowAI
import ShadowKeychain
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("AIServices", TestTimeLimit.standard)
struct SettingsServicesTests {
  @Test("should keep provider keys in the synced keychain scope")
  func shouldKeepProviderKeysInTheSyncedKeychainScope() {
    guard case .synced = AIServices.keychain(identity: .fixture).scope else {
      Issue.record("The key store is not in the synced scope.")
      return
    }
  }

  @Test("should read a stored key as a credential bound to the provider's origin")
  func shouldReadAStoredKeyAsACredentialBoundToTheProviderOrigin() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let credential = try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic))
    try world.services.keys.save(credential, for: .anthropic)

    let read = try #require(await world.services.keys.credential(for: .anthropic))

    #expect(read.secret == SettingsFixtures.secret)
    #expect(read.origin == AnthropicConfiguration.defaultOrigin)
    #expect(await world.services.keys.credential(for: .openRouter) == nil)
    #expect(world.secure.accounts == ["ai.anthropic.api-key"])
  }

  @Test("should never put the key in a credential's description")
  func shouldNeverPutTheKeyInACredentialDescription() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let credential = try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .openRouter))

    #expect(!String(describing: credential).contains(SettingsFixtures.secret))
    #expect(!String(reflecting: credential).contains(SettingsFixtures.secret))
  }

  @Test("should persist settings across a restart and fall back to defaults when they cannot be read")
  func shouldPersistSettingsAndFallBackToDefaultsWhenUnreadable() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    world.services.update {
      $0.provider = .openRouter
      $0.assignments.models[.steady] = "vendor/model"
      $0.limits = SpendLimits(daily: Cost(nanoUSD: 2 * Cost.nanoUSDPerUSD), monthly: nil)
    }

    let restored = AISettingsStore(identity: .fixture, defaults: world.defaults).load()
    #expect(restored.provider == .openRouter)
    #expect(restored.assignments.models[.steady] == "vendor/model")
    #expect(restored.limits.daily == Cost(nanoUSD: 2 * Cost.nanoUSDPerUSD))

    world.defaults.set(Data("not json".utf8), forKey: AppIdentity.fixture.aiSettingsKey)
    #expect(AISettingsStore(identity: .fixture, defaults: world.defaults).load() == AISettings())
  }

  @Test("should hand the router the saved provider, models and caps")
  func shouldHandTheRouterTheSavedProviderModelsAndCaps() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    world.services.update {
      $0.provider = .openRouter
      $0.assignments.models[.swift] = "vendor/fast"
      $0.limits = SpendLimits(daily: nil, monthly: Cost(nanoUSD: 9 * Cost.nanoUSDPerUSD))
    }

    let configuration = world.services.router(store: world.store).configuration

    #expect(configuration.provider == .openRouter)
    #expect(configuration.assignments.models[.swift] == "vendor/fast")
    #expect(configuration.spendLimits.monthly == Cost(nanoUSD: 9 * Cost.nanoUSDPerUSD))
  }

  @Test("should refuse a call without a key, then without consent, then admit it once allowed")
  func shouldRefuseACallWithoutAKeyThenWithoutConsentThenAdmitItOnceAllowed() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let router = { world.services.router(store: world.store) }
    let call = TaskCall(task: .chat, pace: .steady, consent: ConsentDisclosure.fixtureText.requirement)

    #expect(await refusal(router, call)?.code == "routing.credential_missing")

    try world.services.keys.save(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    let request = try #require(await consentRequest(router, call))
    #expect(request.provider == .anthropic)
    #expect(request.host == "api.anthropic.com")
    #expect(request.disclosure == "fixture-text/v2")

    try await world.services.grant(request, in: world.store)
    let routed = try await router().prepare(call)
    #expect(routed.host == "api.anthropic.com")
  }

  @Test("should load the OpenRouter model list at launch only when a key is stored, and swallow a failure")
  func shouldLoadOpenRouterModelsAtLaunchOnlyWhenAKeyIsStored() async throws {
    let listed = try SettingsFixtures.world(listing: { [RemoteModel(id: "vendor/model")] })
    defer { listed.tearDown() }
    await listed.services.loadOpenRouterModelsIfKeyed()
    #expect(listed.services.openRouterModels.isEmpty)

    try listed.services.keys.save(try #require(listed.services.keys.makeCredential(SettingsFixtures.secret, for: .openRouter)), for: .openRouter)
    await listed.services.loadOpenRouterModelsIfKeyed()
    #expect(listed.services.openRouterModels.map(\.id) == ["vendor/model"])

    let failing = try SettingsFixtures.world(listing: SettingsFixtures.failingListing(.server(status: 500)))
    defer { failing.tearDown() }
    try failing.services.keys.save(try #require(failing.services.keys.makeCredential(SettingsFixtures.secret, for: .openRouter)), for: .openRouter)
    await failing.services.loadOpenRouterModelsIfKeyed()
    #expect(failing.services.openRouterModels.isEmpty)
  }

  private func refusal(_ router: () -> TaskRouter, _ call: TaskCall) async -> TaskRouterError? {
    do {
      _ = try await router().prepare(call)
      return nil
    } catch {
      return error
    }
  }

  private func consentRequest(_ router: () -> TaskRouter, _ call: TaskCall) async -> AIConsentRequest? {
    guard case .consentRequired(let request)? = await refusal(router, call) else { return nil }
    return request
  }
}
