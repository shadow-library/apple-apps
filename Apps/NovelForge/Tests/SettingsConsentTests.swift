import Foundation
import ShadowAI
import Testing

@testable import NovelForge

@MainActor
@Suite("Consent")
struct SettingsConsentTests {
  private let request = AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "novel-text", disclosure: "novel-text/v1")

  @Test("should map a stable disclosure id to localised text naming the provider")
  func shouldMapTheNovelTextDisclosureToItsText() throws {
    let disclosure = try #require(ConsentDisclosure(request))

    #expect(disclosure == .novelText)
    #expect(disclosure.explanation(provider: "Anthropic").contains("Anthropic"))
    #expect(!disclosure.title.isEmpty)
    #expect(disclosure.requirement == AIConsentRequirement(dataClass: "novel-text", disclosure: "novel-text/v1"))
  }

  @Test("should not map an unknown disclosure id or a mismatched data class")
  func shouldNotMapAnUnknownDisclosureOrMismatchedDataClass() {
    #expect(ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "novel-text", disclosure: "novel-text/v9")) == nil)
    #expect(ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "other", disclosure: "novel-text/v1")) == nil)
  }

  @Test("should record consent, list it, and revoke it")
  func shouldRecordListAndRevokeConsent() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    #expect(try await world.services.grantedConsents(in: world.store).isEmpty)

    try await world.services.grant(request, in: world.store)
    let granted = try await world.services.grantedConsents(in: world.store)
    #expect(granted == [GrantedConsent(provider: .anthropic, host: "api.anthropic.com", disclosure: .novelText)])

    try await world.services.revoke(try #require(granted.first), in: world.store)
    #expect(try await world.services.grantedConsents(in: world.store).isEmpty)
  }

  @Test("should ask again after consent is revoked")
  func shouldAskAgainAfterConsentIsRevoked() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    try world.services.keys.save(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    let call = TaskCall(task: .chat, pace: .steady, consent: ConsentDisclosure.novelText.requirement)
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
    let unknown = AIConsentRequest(provider: .openRouter, host: "openrouter.ai", dataClass: "novel-text", disclosure: "novel-text/v9")
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
