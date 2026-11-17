import Foundation
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("TaskRouter admission", .timeLimit(.minutes(1)))
struct TaskRouterAdmissionTests {
  private struct Setup {
    let clock = LedgerTestClock()
    let store: VaultStore
    let anthropic = ScriptedModelProvider()
    let openRouter = ScriptedModelProvider()

    init() throws {
      store = try LedgerFixture.store(clock)
    }

    func router(
      _ configuration: TaskRouterConfiguration = RoutingFixture.configuration(), kinds: [ModelProviderKind] = ModelProviderKind.allCases,
      credentials: StaticCredentials = RoutingFixture.allCredentials
    ) -> TaskRouter {
      RoutingFixture.router(
        configuration, anthropic: kinds.contains(.anthropic) ? anthropic : nil, openRouter: kinds.contains(.openRouter) ? openRouter : nil, credentials: credentials,
        store: store, clock: clock)
    }

    func spent(_ nanoUSD: Int64, outcome: LedgerOutcome = .finished, source: LedgerCostSource = .computed) async throws {
      let entry = LedgerFixture.entry(startedMillis: clock.millis, outcome: outcome, cost: Cost(nanoUSD: nanoUSD), costSource: source)
      try await LedgerFixture.open(entry, in: store)
    }

    var sentNothing: Bool { anthropic.requests.isEmpty && openRouter.requests.isEmpty }
  }

  private static func refusal(_ router: TaskRouter, _ call: TaskCall = RoutingFixture.call()) async -> TaskRouterError? {
    do {
      _ = try await router.prepare(call)
      return nil
    } catch {
      return error
    }
  }

  @Test("should prepare a call once the key, consent and spend allow it")
  func admits() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    let call = try await setup.router().prepare(RoutingFixture.call(pace: .meticulous))
    #expect(call.route.model == "model-meticulous")
    #expect(call.host == "api.example.com")
    #expect(call.callIDs.isEmpty)
    #expect(try await LedgerFixture.entries(setup.store).isEmpty)
  }

  @Test("should ask for consent naming the provider when none was given")
  func consentMissing() async throws {
    let setup = try Setup()
    let refusal = await Self.refusal(setup.router())
    guard case .consentRequired(let request)? = refusal else {
      Issue.record("expected consentRequired, got \(String(describing: refusal))")
      return
    }
    #expect(request == AIConsentRequest(provider: .anthropic, host: "api.example.com", dataClass: "novel", disclosure: "novel-text/v1"))
    #expect(setup.sentNothing)
  }

  @Test("should ask again when consent was given for another disclosure, another provider, or revoked")
  func consentStale() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", consent: AIConsentRequirement(dataClass: "novel", disclosure: "novel-text/v0"), in: setup.store)
    guard case .consentRequired? = await Self.refusal(setup.router()) else {
      Issue.record("expected consentRequired for a changed disclosure")
      return
    }
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    guard case .consentRequired(let request)? = await Self.refusal(setup.router(), RoutingFixture.call(mode: .unrestricted)) else {
      Issue.record("expected consentRequired for OpenRouter")
      return
    }
    #expect(request.provider == .openRouter)
    #expect(request.host == "router.example.com")
    try await setup.store.write { transaction in
      try AIConsent.decide(.revoked, provider: "api.example.com", dataClass: "novel", summary: RoutingFixture.consent.disclosure, atMillis: 2, in: &transaction)
    }
    guard case .consentRequired? = await Self.refusal(setup.router()) else {
      Issue.record("expected consentRequired after a revoke")
      return
    }
  }

  @Test("should refuse a call once today's spend reaches the daily limit")
  func dailyLimit() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    try await setup.spent(2_000)
    let refusal = await Self.refusal(setup.router(RoutingFixture.configuration(limits: SpendLimits(daily: Cost(nanoUSD: 2_000)))))
    guard case .dailySpendLimitReached(let spent, let limit)? = refusal else {
      Issue.record("expected dailySpendLimitReached, got \(String(describing: refusal))")
      return
    }
    #expect(spent == Cost(nanoUSD: 2_000))
    #expect(limit == Cost(nanoUSD: 2_000))
    #expect(setup.sentNothing)
  }

  @Test("should report the monthly limit before the daily one")
  func monthlyLimit() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    try await setup.spent(5_000)
    let limits = SpendLimits(daily: Cost(nanoUSD: 1_000), monthly: Cost(nanoUSD: 4_000))
    guard case .monthlySpendLimitReached(Cost(nanoUSD: 5_000), Cost(nanoUSD: 4_000))? = await Self.refusal(setup.router(RoutingFixture.configuration(limits: limits))) else {
      Issue.record("expected monthlySpendLimitReached")
      return
    }
  }

  @Test("should not count pending calls toward the limit")
  func pendingNotCounted() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    try await setup.spent(9_000, outcome: .started, source: .pending)
    let call = try await setup.router(RoutingFixture.configuration(limits: SpendLimits(daily: Cost(nanoUSD: 1)))).prepare(RoutingFixture.call())
    #expect(call.route.provider == .anthropic)
  }

  @Test("should refuse when the routed provider has no key, or a key for another address")
  func credentialMissing() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    guard case .credentialMissing(.anthropic)? = await Self.refusal(setup.router(credentials: StaticCredentials(credentials: [:]))) else {
      Issue.record("expected credentialMissing")
      return
    }
    let foreign = StaticCredentials(credentials: [.anthropic: RoutingFixture.credential(RoutingFixture.openRouterOrigin)])
    guard case .credentialMissing(.anthropic)? = await Self.refusal(setup.router(credentials: foreign)) else {
      Issue.record("expected credentialMissing for a foreign key")
      return
    }
  }

  @Test("should fail an unrestricted call loudly when OpenRouter is not connected, sending nothing to the standard provider")
  func unrestrictedWithoutOpenRouter() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "api.example.com", in: setup.store)
    guard case .providerMissing(.openRouter)? = await Self.refusal(setup.router(kinds: [.anthropic]), RoutingFixture.call(mode: .unrestricted)) else {
      Issue.record("expected providerMissing")
      return
    }
    #expect(setup.sentNothing)
  }

  @Test("should send an unrestricted call only to the unrestricted model on OpenRouter")
  func unrestrictedSucceeds() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "router.example.com", in: setup.store)
    setup.openRouter.enqueueReply("Unrestricted reply", generationID: "g1")
    let call = try await setup.router().prepare(RoutingFixture.call(.writing, pace: .swift, deeper: true, mode: .unrestricted))
    let response = try await call.provider.stream(call.request(system: [], messages: [.user("Write.")])).collect()
    await call.settled()
    #expect(response.text == "Unrestricted reply")
    #expect(setup.anthropic.requests.isEmpty)
    #expect(setup.openRouter.requests.map(\.model) == ["or/unrestricted"])
    #expect(call.route.contentMode == .unrestricted)
    #expect(!call.route.deepened)
    #expect(call.entries.map(\.provider) == ["router.example.com"])
  }

  @Test("should fail an unrestricted call loudly when no unrestricted model is assigned")
  func unrestrictedUnassigned() async throws {
    let setup = try Setup()
    try await RoutingFixture.grantConsent(host: "router.example.com", in: setup.store)
    let configuration = RoutingFixture.configuration(.openRouter, assignments: OpenRouterAssignments(models: RoutingFixture.assignments.models))
    guard case .unrestrictedModelMissing? = await Self.refusal(setup.router(configuration), RoutingFixture.call(mode: .unrestricted)) else {
      Issue.record("expected unrestrictedModelMissing")
      return
    }
    #expect(setup.sentNothing)
    #expect(try await LedgerFixture.entries(setup.store).isEmpty)
  }
}
