import Foundation
import ShadowAI
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("Provider connection", TestTimeLimit.standard)
struct ProviderConnectionTests {
  private static let code = "auth_code_abc123"
  private static let signedInKey = "sk-or-v1-signed-in"

  private static func exchange(status: Int = 200, json: String = #"{"key":"sk-or-v1-signed-in"}"#) -> StubHTTPExchangeTransport {
    StubHTTPExchangeTransport(plain: StubHTTPTransport(statusCode: status, json: json))
  }

  private static func query(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
  }

  /// Returns to the app's callback with `items` and, unless told not to, the state the sign-in page was sent.
  private static func returning(_ items: [URLQueryItem], echoingState: Bool = true) -> WebSignIn {
    { (page, _) async throws(ModelError) -> URL in
      let state = echoingState ? query(page)["state"].map { [URLQueryItem(name: "state", value: $0)] } ?? [] : []
      return AppIdentity.fixture.openRouterCallback.appending(queryItems: items + state)
    }
  }

  @Test("should open OpenRouter's PKCE page for the app's callback and store the key it returns as a pasted key")
  func shouldStoreTheSignedInKeyAsAPastedKey() async throws {
    let transport = Self.exchange()
    let world = try SettingsFixtures.world(transport: transport)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    var opened: (url: URL, scheme: String)?

    let returning = Self.returning([URLQueryItem(name: "code", value: Self.code)])
    await model.signInWithOpenRouter { (url, scheme) async throws(ModelError) -> URL in
      opened = (url, scheme)
      return try await returning(url, scheme)
    }

    let page = try #require(opened)
    #expect(page.scheme == "com.shadow.apps.shelltest")
    #expect(page.url.host() == "openrouter.ai" && page.url.path() == "/auth")
    let query = Self.query(page.url)
    #expect(query["callback_url"] == "com.shadow.apps.shelltest://openrouter-sign-in")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["code_challenge"]?.count == 43)
    #expect(query["state"]?.count == 43)
    let sent = try #require(transport.plain.requests.first)
    #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
    let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
    #expect(body["code"] == Self.code && body["code_challenge_method"] == "S256" && body["code_verifier"]?.count == 43)
    #expect(model.signIn == .idle)
    #expect(model.storedKeys.contains(.openRouter))
    #expect(world.secure.accounts == ["ai.openrouter.api-key"])
    #expect(try await world.services.keys.credential(for: .openRouter)?.secret == Self.signedInKey)
  }

  @Test("should stay idle and send nothing when the person closes the sign-in page")
  func shouldStayIdleWhenTheSignInIsClosed() async throws {
    let transport = Self.exchange()
    let world = try SettingsFixtures.world(transport: transport)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)

    await model.signInWithOpenRouter { (_, _) async throws(ModelError) -> URL in throw .cancelled }

    #expect(model.signIn == .idle)
    #expect(transport.plain.requests.isEmpty)
    #expect(world.secure.accounts.isEmpty)
  }

  @Test("should report a return without a code, sending nothing")
  func shouldReportAReturnWithoutACode() async throws {
    let transport = Self.exchange()
    let world = try SettingsFixtures.world(transport: transport)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)

    await model.signInWithOpenRouter(using: Self.returning([URLQueryItem(name: "error", value: "access_denied")]))

    guard case .failed(let error) = model.signIn else {
      Issue.record("A return without a code was not reported.")
      return
    }
    #expect(error.detail == "model.malformed_response")
    #expect(transport.plain.requests.isEmpty)
    #expect(world.secure.accounts.isEmpty)
  }

  @Test("should refuse a code returned without the state it was sent, sending nothing")
  func shouldRefuseACodeWithoutItsState() async throws {
    let transport = Self.exchange()
    let world = try SettingsFixtures.world(transport: transport)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)

    await model.signInWithOpenRouter(using: Self.returning([URLQueryItem(name: "code", value: Self.code)], echoingState: false))

    guard case .failed(let error) = model.signIn else {
      Issue.record("A code without its state was accepted.")
      return
    }
    #expect(error.detail == "model.malformed_response")
    #expect(transport.plain.requests.isEmpty && world.secure.accounts.isEmpty)
  }

  @Test("should report an exchange OpenRouter refuses and store nothing")
  func shouldReportARefusedExchange() async throws {
    let transport = Self.exchange(status: 403, json: #"{"error":{"code":403,"message":"Invalid code or code_verifier"}}"#)
    let world = try SettingsFixtures.world(transport: transport)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)

    await model.signInWithOpenRouter(using: Self.returning([URLQueryItem(name: "code", value: Self.code)]))

    guard case .failed(let error) = model.signIn else {
      Issue.record("A refused exchange was not reported.")
      return
    }
    #expect(error.detail == "model.forbidden")
    #expect(transport.plain.requests.count == 1)
    #expect(world.secure.accounts.isEmpty)
    #expect(!model.storedKeys.contains(.openRouter))
  }

  @Test("should enter the demo from the prompt and close it without the action that opened it, even once a provider is ready")
  func shouldLeaveForTheDemoWithoutTheHeldAction() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let connection = ProviderConnectionModel(services: world.services)
    var entered = 0

    connection.tryDemo(DemoEntry(isEntering: true) { entered += 1 })
    #expect(entered == 0)
    #expect(!connection.closes)
    connection.tryDemo(DemoEntry(isEntering: false) { entered += 1 })

    #expect(entered == 1)
    #expect(connection.leftForDemo && connection.closes)
    try world.services.keys.save(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    world.services.update { $0.provider = .anthropic }
    #expect(world.services.isReadyForStandardCalls)
    #expect(!ProviderConnectionModel.continuesHeldAction(services: world.services, leftForDemo: true))
    #expect(ProviderConnectionModel.continuesHeldAction(services: world.services, leftForDemo: false))
  }

  @Test("should recommend Anthropic and make a key saved through the prompt the provider requests go to")
  func shouldConnectThePromptedProvider() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    world.services.update { $0.provider = .openRouter }
    let connection = ProviderConnectionModel(services: world.services)
    #expect(connection.choice == .anthropic)
    #expect(!connection.isConnected)

    connection.settings.keyDrafts[.anthropic] = SettingsFixtures.secret
    await connection.settings.submitKey(for: .anthropic)

    #expect(connection.isFinished)
    #expect(world.services.settings.provider == .anthropic)
    #expect(world.services.hasUsableProvider)
  }

  @Test("should switch to a provider with a saved key only when the owner picks it")
  func shouldUseASavedKeyOnlyWhenPicked() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    try world.services.keys.save(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    world.services.update { $0.provider = .openRouter }
    let connection = ProviderConnectionModel(services: world.services)
    await connection.load()
    #expect(!connection.isConnected && connection.hasStoredChoice && !connection.isFinished)
    #expect(world.services.settings.provider == .openRouter)

    connection.useSavedKey()

    #expect(connection.isFinished)
    #expect(world.services.settings.provider == .anthropic)
  }

  @Test("should keep OpenRouter connecting until every pace has a model, listing OpenRouter's models once the key is saved")
  func shouldAskForPaceModelsBeforeOpenRouterIsReady() async throws {
    let listed = CallCount()
    let world = try SettingsFixtures.world(listing: {
      listed.increment()
      return [RemoteModel(id: "vendor/model", name: "Model", contextLength: nil)]
    })
    defer { world.tearDown() }
    let connection = ProviderConnectionModel(services: world.services)
    connection.choice = .openRouter
    #expect(connection.needsModels)
    connection.settings.keyDrafts[.openRouter] = SettingsFixtures.secret

    await connection.settings.submitKey(for: .openRouter)

    #expect(connection.isConnected && !connection.isFinished)
    #expect(world.services.hasUsableProvider && !world.services.assignsEveryPace)
    #expect(listed.value == 1 && connection.settings.listedModels.map(\.id) == ["vendor/model"])

    for pace in Pace.allCases.dropLast() { connection.settings.choose(connection.settings.listedModels[0], for: pace) }
    connection.settings.saveModels()
    #expect(!connection.isFinished && !world.services.assignsEveryPace)

    connection.settings.choose(connection.settings.listedModels[0], for: Pace.allCases[Pace.allCases.count - 1])
    connection.settings.saveModels()

    #expect(connection.isFinished && world.services.assignsEveryPace)
    #expect(world.services.settings.provider == .openRouter)
  }

  @Test("should be ready for standard calls only with the provider's key and, for OpenRouter, a model for some pace")
  func shouldBeReadyOnlyWithAKeyAndSomePace() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    #expect(!world.services.isReadyForStandardCalls)

    try world.services.saveKey(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .anthropic)), for: .anthropic)
    #expect(world.services.isReadyForStandardCalls)

    try world.services.saveKey(try #require(world.services.keys.makeCredential(SettingsFixtures.secret, for: .openRouter)), for: .openRouter)
    world.services.update {
      $0.provider = .openRouter
      $0.assignments.models = Dictionary(uniqueKeysWithValues: Pace.allCases.map { ($0, "  ") })
    }
    #expect(world.services.hasUsableProvider && !world.services.isReadyForStandardCalls)

    let connection = ProviderConnectionModel(services: world.services)
    #expect(connection.choice == .openRouter && connection.isConnected && !connection.isFinished)

    world.services.update { $0.assignments.models[Pace.allCases[0]] = "vendor/model" }
    #expect(world.services.isReadyForStandardCalls && !world.services.assignsEveryPace && !connection.isFinished)

    world.services.update { $0.assignments.models = Dictionary(uniqueKeysWithValues: Pace.allCases.map { ($0, "vendor/model") }) }
    #expect(world.services.isReadyForStandardCalls && connection.isFinished)
  }

  @Test("should count a key saved by paste or sign-in and a removed key, and nothing for a refused key or a closed sign-in")
  func shouldCountEveryKeyWrite() async throws {
    let accepts = Flag()
    let world = try SettingsFixtures.world(validation: { _, _ in accepts.value ? .valid(label: nil) : .invalid }, transport: Self.exchange())
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    #expect(world.services.keysRevision == 0)

    model.keyDrafts[.anthropic] = SettingsFixtures.secret
    await model.submitKey(for: .anthropic)
    #expect(world.services.keysRevision == 0)

    accepts.value = true
    await model.submitKey(for: .anthropic)
    #expect(world.services.keysRevision == 1)

    await model.signInWithOpenRouter { (_, _) async throws(ModelError) -> URL in throw .cancelled }
    #expect(world.services.keysRevision == 1)

    await model.signInWithOpenRouter(using: Self.returning([URLQueryItem(name: "code", value: Self.code)]))
    #expect(world.services.keysRevision == 2)

    await model.removeKey(.anthropic)
    #expect(world.services.keysRevision == 3)
  }

  @Test("should not switch provider when a key is saved for one other than the chosen one")
  func shouldIgnoreAKeySavedForAnotherProvider() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let connection = ProviderConnectionModel(services: world.services)
    connection.settings.keyDrafts[.openRouter] = SettingsFixtures.secret

    await connection.settings.submitKey(for: .openRouter)

    #expect(!connection.isFinished)
    #expect(world.services.settings.provider == .anthropic)
  }
}

private final class Flag: Sendable {
  private let state = Mutex(false)

  var value: Bool {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }
}

@MainActor
@Suite("Unrestricted writing model", TestTimeLimit.standard)
struct UnrestrictedModelSettingsTests {
  @Test("should hide the field and save nothing when the app does not offer unrestricted writing")
  func shouldHideTheFieldWhenNotOffered() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    model.unrestrictedDraft = "vendor/unrestricted-model"

    #expect(!model.showsUnrestrictedModel && !model.canSaveUnrestricted)
    model.saveUnrestricted()

    #expect(world.services.settings.assignments.unrestricted == nil)
  }

  @Test("should save a valid identifier where routing and the next launch read it, refuse one with spaces, and clear it when emptied")
  func shouldSaveTheIdentifierWhenOffered() throws {
    let world = try SettingsFixtures.world(offersUnrestrictedModel: true)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    #expect(model.showsUnrestrictedModel && !model.canSaveUnrestricted)

    model.unrestrictedDraft = "vendor/unrestricted model"
    #expect(model.unrestrictedIssue == .invalid && !model.canSaveUnrestricted)

    model.unrestrictedDraft = "  vendor/unrestricted-model \n"
    model.saveUnrestricted()

    #expect(world.services.settings.assignments.unrestricted == "vendor/unrestricted-model")
    #expect(model.unrestrictedDraft == "vendor/unrestricted-model" && !model.canSaveUnrestricted)
    #expect(AISettingsStore(identity: .fixture, defaults: world.defaults).load().assignments.unrestricted == "vendor/unrestricted-model")
    #expect(AISettingsModel(services: world.services, store: world.store).unrestrictedDraft == "vendor/unrestricted-model")

    model.unrestrictedDraft = ""
    model.saveUnrestricted()

    #expect(world.services.settings.assignments.unrestricted == nil)
  }
}
