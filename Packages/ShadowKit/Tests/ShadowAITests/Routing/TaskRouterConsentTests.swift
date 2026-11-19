import Foundation
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("TaskRouter missing consent", TestTimeLimit.quick)
struct TaskRouterConsentTests {
  @Test func shouldNameTheHostEachContentModeSendsToUntilItsConsentIsGiven() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    let router = RoutingFixture.router(anthropic: ScriptedModelProvider(), openRouter: ScriptedModelProvider(), store: store, clock: clock)
    let consent = RoutingFixture.consent

    let standard = try await router.missingConsent(consent)
    #expect(standard == AIConsentRequest(provider: .anthropic, host: "api.example.com", dataClass: consent.dataClass, disclosure: consent.disclosure))
    let unrestricted = try await router.missingConsent(consent, contentMode: .unrestricted)
    #expect(unrestricted == AIConsentRequest(provider: .openRouter, host: "router.example.com", dataClass: consent.dataClass, disclosure: consent.disclosure))

    try await RoutingFixture.grantConsent(host: "api.example.com", in: store)
    #expect(try await router.missingConsent(consent) == nil)
    #expect(try await router.missingConsent(consent, contentMode: .unrestricted)?.host == "router.example.com")
    try await RoutingFixture.grantConsent(host: "router.example.com", in: store)
    #expect(try await router.missingConsent(consent, contentMode: .unrestricted) == nil)
  }

  @Test func shouldFollowTheConfiguredProviderForStandardCallsAndAskNothingWithoutABinding() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    let consent = RoutingFixture.consent
    let openRouterOnly = RoutingFixture.router(RoutingFixture.configuration(.openRouter), openRouter: ScriptedModelProvider(), store: store, clock: clock)
    #expect(try await openRouterOnly.missingConsent(consent)?.host == "router.example.com")
    let unbound = RoutingFixture.router(store: store, clock: clock)
    #expect(try await unbound.missingConsent(consent) == nil)
  }
}
