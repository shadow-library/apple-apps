import Foundation
import ShadowAI
import ShadowCore
import ShadowKeychain
import ShadowNetworking
import ShadowStore
import Synchronization
import Testing

@testable import ShadowAppShell

final class RefusingTransport: HTTPTransport, HTTPStreamingTransport {
  private let recorded = Mutex<[URLRequest]>([])

  var requests: [URLRequest] { recorded.withLock { $0 } }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorded.withLock { $0.append(request) }
    throw URLError(.cannotConnectToHost)
  }

  func stream(_ request: URLRequest) async throws -> HTTPStreamingResponse {
    recorded.withLock { $0.append(request) }
    throw URLError(.cannotConnectToHost)
  }
}

@MainActor
@Suite("AIServices demo", TestTimeLimit.standard)
struct DemoServicesTests {
  private static let outline: JSONValue = [
    "type": "object", "properties": ["title": ["type": "string", "minLength": 1]], "required": ["title"], "additionalProperties": false,
  ]

  private static let script = DemoScript(
    rules: [
      DemoRule(DemoMatch(schema: "outline"), replies: [.json(["title": "Glass and Ash"])]),
      DemoRule(DemoMatch(task: .chat), replies: [.text("Welcome to the demo.")]),
    ],
    fallback: "A demo answer.")

  @MainActor
  private struct World {
    let services: AIServices
    let transport = RefusingTransport()
    let store: VaultStore

    init() throws {
      services = AIServices.demo(
        identity: .fixture, provider: DemoModelProvider(script: DemoServicesTests.script, pace: .zero), disclosures: [.fixtureText], requestGuard: { _ in nil },
        transport: transport)
      store = try ShellStore.open()
    }
  }

  private static let call = TaskCall(task: .chat, pace: .steady, consent: ConsentDisclosure.fixtureText.requirement)

  private static func consentRequest(_ services: AIServices, _ store: VaultStore) async -> AIConsentRequest? {
    do {
      _ = try await services.router(store: store).prepare(call)
      return nil
    } catch {
      guard case .consentRequired(let request) = error else { return nil }
      return request
    }
  }

  @Test("should answer text and structured calls from the script with no key, never touching the network")
  func shouldAnswerFromTheScriptWithNoKeyNeverTouchingTheNetwork() async throws {
    let world = try World()
    #expect(world.services.isDemo && world.services.hasUsableProvider)
    #expect(world.services.settings.provider == .demo)
    try await world.services.grant(try #require(await Self.consentRequest(world.services, world.store)), in: world.store)

    let chat = try await world.services.router(store: world.store).prepare(Self.call)
    var text = ""
    for try await event in chat.provider.stream(chat.request(system: [], messages: [.user("Hello")])) {
      if case .textDelta(let delta) = event { text += delta }
    }
    let structured = try await chat.structured(chat.request(system: [], messages: [.user("Outline it.")]), name: "outline", schema: Self.outline)
    await chat.settled()
    await #expect(throws: ModelError.self) {
      try await world.services.validate(try #require(ProviderKeys.standard(store: FakeSecureStore()).makeCredential("sk-x", for: .anthropic)), for: .anthropic)
    }
    try await world.services.refreshOpenRouterModels()
    await world.services.loadOpenRouterModelsIfChosen()
    world.services.settler(for: world.store).settle()
    try await ShellWait.until("the settler is idle") { !world.services.settler(for: world.store).isSettling }

    #expect(text == "Welcome to the demo.")
    #expect(String(decoding: structured.json, as: UTF8.self) == #"{"title":"Glass and Ash"}"#)
    #expect(world.services.openRouterModels.isEmpty)
    #expect(world.transport.requests.isEmpty)
    let entries = try await world.store.read { transaction in try Ledger.entries(in: transaction) }
    #expect(entries.count == 2 && entries.allSatisfy { $0.isDemo && $0.cost == .zero && $0.costSource == .reported })
  }

  @Test("should still ask consent for the demo, list it, and ask again once it is revoked")
  func shouldStillGateOnConsent() async throws {
    let world = try World()
    let request = try #require(await Self.consentRequest(world.services, world.store))
    #expect(request.provider == .demo && request.host == DemoModelProvider.host && request.disclosure == "fixture-text/v2")
    #expect(AIErrors.headline(for: .consentRequired(request), app: .fixture) == "Allow the demo to use this first.")

    try await world.services.grant(request, in: world.store)
    let granted = try await world.services.grantedConsents(in: world.store)
    #expect(granted.map(\.provider) == [.demo])
    _ = try await world.services.router(store: world.store).prepare(Self.call)

    try await world.services.revoke(try #require(granted.first), in: world.store)
    #expect(await Self.consentRequest(world.services, world.store) == request)
  }

  @Test("should keep the demo provider and leave the owner's keys alone")
  func shouldKeepTheDemoProviderAndLeaveKeysAlone() throws {
    let world = try World()
    world.services.update {
      $0.provider = .anthropic
      $0.limits = SpendLimits(daily: Cost(nanoUSD: 1), monthly: nil)
    }

    #expect(world.services.settings.provider == .demo)
    #expect(world.services.settings.limits.daily == Cost(nanoUSD: 1))
    #expect(world.services.router(store: world.store).configuration.provider == .demo)
    #expect(try !world.services.keys.contains(.anthropic))
    #expect(world.services.keys.makeCredential("sk-x", for: .anthropic) == nil)
    #expect(throws: SecureStoreError.self) {
      try world.services.keys.save(try #require(ProviderKeys.standard(store: FakeSecureStore()).makeCredential("sk-x", for: .openRouter)), for: .openRouter)
    }
  }

  @Test("should not be a demo when built live")
  func shouldNotBeADemoWhenBuiltLive() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }

    #expect(!world.services.isDemo && !world.services.hasUsableProvider)
    #expect(world.services.settings.provider == .anthropic)
    try world.services.keys.save(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    #expect(world.services.hasUsableProvider)
  }
}
