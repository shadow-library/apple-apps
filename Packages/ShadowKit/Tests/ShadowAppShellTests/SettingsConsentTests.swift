import Foundation
import ShadowAI
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("Consent", TestTimeLimit.standard)
struct SettingsConsentTests {
  private let request = AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "fixture-text", disclosure: "fixture-text/v2")

  @Test("should find the app's disclosure for a request by its id and data class")
  func shouldFindTheAppsDisclosureForARequest() throws {
    let disclosure = try #require(ConsentDisclosure(request, among: [.fixtureText]))

    #expect(disclosure == .fixtureText)
    #expect(disclosure.explanation(provider: "Anthropic").contains("Anthropic"))
    #expect(disclosure.title == "Your text")
    #expect(disclosure.requirement == AIConsentRequirement(dataClass: "fixture-text", disclosure: "fixture-text/v2"))
  }

  @Test("should not find a disclosure for an unknown id, a mismatched data class or an app that supplies none")
  func shouldNotFindAnUnknownDisclosureOrMismatchedDataClass() {
    #expect(
      ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "fixture-text", disclosure: "fixture-text/v9"), among: [.fixtureText]) == nil)
    #expect(ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "other", disclosure: "fixture-text/v2"), among: [.fixtureText]) == nil)
    #expect(ConsentDisclosure(request, among: []) == nil)
  }

  @Test("should record consent, list it, and revoke it")
  func shouldRecordListAndRevokeConsent() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    #expect(try await world.services.grantedConsents(in: world.store).isEmpty)

    try await world.services.grant(request, in: world.store)
    let granted = try await world.services.grantedConsents(in: world.store)
    #expect(granted == [GrantedConsent(provider: .anthropic, host: "api.anthropic.com", disclosure: .fixtureText)])

    try await world.services.revoke(try #require(granted.first), in: world.store)
    #expect(try await world.services.grantedConsents(in: world.store).isEmpty)
  }

  @Test("should ask again after consent is revoked")
  func shouldAskAgainAfterConsentIsRevoked() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    try world.services.keys.save(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    let call = TaskCall(task: .chat, pace: .steady, consent: ConsentDisclosure.fixtureText.requirement)
    try await world.services.grant(request, in: world.store)
    _ = try await world.services.router(store: world.store).prepare(call)

    let model = AISettingsModel(services: world.services, store: world.store)
    await model.refreshConsents()
    await model.revoke(try #require(model.consents.first))

    #expect(model.consents.isEmpty)
    do {
      _ = try await world.services.router(store: world.store).prepare(call)
      Issue.record("The call was admitted after consent was revoked.")
    } catch {
      guard case .consentRequired = error else {
        Issue.record("The call was refused for another reason.")
        return
      }
    }
  }

  @Test("should record consent through the prompt and leave the store untouched when declined or unknown")
  func shouldRecordConsentThroughThePromptAndRefuseAnUnknownDisclosure() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let unknown = AIConsentRequest(provider: .openRouter, host: "openrouter.ai", dataClass: "fixture-text", disclosure: "fixture-text/v9")
    let refused = ConsentPromptModel(request: unknown, services: world.services, store: world.store)
    #expect(!refused.canAllow)
    #expect(await refused.allow() == false)
    #expect(try await world.services.grantedConsents(in: world.store).isEmpty)

    let prompt = ConsentPromptModel(request: request, services: world.services, store: world.store)
    #expect(prompt.canAllow)
    #expect(await prompt.allow())
    #expect(try await world.services.grantedConsents(in: world.store).count == 1)
  }
}
