import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowKeychain
import ShadowNetworking
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForge

@MainActor
@Suite("Novel Forge on the app shell", TestTimeLimit.standard)
struct NovelForgeShellTests {
  private let request = AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "novel-text", disclosure: "novel-text/v2")

  @Test("should keep the keychain services and defaults keys that existing installs hold")
  func shouldKeepTheNamesExistingInstallsHold() throws {
    let suite = "NovelForgeShellTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AppIdentity.novelForge.id == "com.shadow.apps.novelforge")
    #expect(AIServices.keychain(identity: .novelForge).service == "com.shadow.apps.novelforge.ai")
    #expect(AISettingsStore(identity: .novelForge, defaults: defaults).key == "com.shadow.apps.novelforge.ai.settings.v1")
    #expect(AppIdentity.novelForge.recoveryRecipientKeyPrefix == "com.shadow.apps.novelforge.sync.recovery-recipient.")
    #expect(AppIdentity.novelForge.recoveryOfferDeclinedKeyPrefix == "com.shadow.apps.novelforge.sync.recovery-offer-declined.")
    #expect(AIServices.novelForge(defaults: defaults).openRouterConfiguration.applicationTitle == "Novel Forge")
    #expect(AppIdentity.novelForge.exampleBucketName == "my-novels")
  }

  @Test("should screen an unrestricted route with the hard line and leave a standard route alone")
  func shouldScreenAnUnrestrictedRouteWithTheHardLine() throws {
    let suite = "NovelForgeShellTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let services = AIServices.novelForge(defaults: defaults)

    #expect(services.requestGuard(Self.route(.standard)) == nil)
    let requestGuard = try #require(services.requestGuard(Self.route(.unrestricted)))
    #expect(Self.refuses(requestGuard, Self.hardLineRequest))
    #expect(!Self.refuses(requestGuard, ModelRequest(model: "or/unrestricted", system: [], messages: [.user("Go on.")], maxOutputTokens: 512)))
  }

  @Test("should refuse a hard-line request on an unrestricted call its router prepares")
  func shouldRefuseAHardLineRequestThroughTheRouter() async throws {
    let suite = "NovelForgeShellTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let services = AIServices(
      identity: .novelForge, keys: .standard(store: InMemorySecureStore()), settingsStore: AISettingsStore(identity: .novelForge, defaults: defaults),
      transport: URLSessionTransport(), disclosures: ConsentDisclosure.novelForge, requestGuard: AIServices.novelForge(defaults: defaults).requestGuard)
    services.update { $0.assignments.unrestricted = "or/unrestricted" }
    try services.keys.save(try #require(services.keys.makeCredential("sk-or-test", for: .openRouter)), for: .openRouter)
    let store = try NovelForgeStore.openInMemory()
    try await services.grant(AIConsentRequest(provider: .openRouter, host: "openrouter.ai", dataClass: "novel-text", disclosure: "novel-text/v2"), in: store)

    let call = TaskCall(task: .chat, pace: .steady, contentMode: .unrestricted, consent: ConsentDisclosure.novelText.requirement)
    let routed = try await services.router(store: store).prepare(call)

    #expect(Self.refuses(try #require(routed.requestGuard), Self.hardLineRequest))
  }

  private static let hardLineRequest = ModelRequest(model: "or/unrestricted", system: [], messages: [.user("a child and intercourse")], maxOutputTokens: 512)

  private static func route(_ mode: ModelContentMode) -> ModelRoute {
    ModelRoute(
      task: .chat, pace: .steady, thinksDeeper: false, deepened: false, contentMode: mode, provider: .openRouter, model: "or/unrestricted", effort: nil,
      maxOutputTokens: 512, supportsNativeSchema: false)
  }

  private static func refuses(_ requestGuard: ModelRequestGuard, _ request: ModelRequest) -> Bool {
    guard case .refuse = requestGuard.screen(request) else { return false }
    return true
  }

  @Test("should resolve the shell's strings from its own bundle inside the app")
  func shouldResolveTheShellsStringsFromItsBundle() throws {
    let url = try #require(Bundle.main.url(forResource: "ShadowKit_ShadowAppShell", withExtension: "bundle"))
    let bundle = try #require(Bundle(url: url))

    #expect(bundle.localizedString(forKey: "Something went wrong.", value: "missing", table: "AppShell") == PresentedError.genericHeadline)
    #expect(bundle.localizedString(forKey: "Your %@ is the same on all your devices.", value: "missing", table: "Sync") != "missing")
    #expect(bundle.localizedString(forKey: "AI Settings", value: "missing", table: "AISettings") == "AI Settings")
  }

  @Test("should map the novel text disclosure to its text naming the provider")
  func shouldMapTheNovelTextDisclosureToItsText() throws {
    let disclosure = try #require(ConsentDisclosure(request))

    #expect(disclosure == .novelText)
    #expect(disclosure.explanation(provider: "Anthropic").contains("Anthropic"))
    #expect(!disclosure.title.isEmpty)
    #expect(disclosure.requirement == AIConsentRequirement(dataClass: "novel-text", disclosure: "novel-text/v2"))
  }

  @Test("should not map an unknown disclosure id or a mismatched data class")
  func shouldNotMapAnUnknownDisclosureOrMismatchedDataClass() {
    #expect(ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "novel-text", disclosure: "novel-text/v9")) == nil)
    #expect(ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "other", disclosure: "novel-text/v2")) == nil)
  }

  @Test("should present a domain error through the shell with its code and a store failure with the store's words")
  func shouldPresentDomainErrorsThroughTheShell() {
    let missing = PresentedError(DomainError.novelNotFound(UUID()))
    #expect(missing.headline == PresentedError.genericHeadline)
    #expect(missing.detail == DomainError.novelNotFound(UUID()).code)
    #expect(PresentedError(DomainError.store(.database("closed"))).headline == PresentedError.storeHeadline)
  }
}

nonisolated final class PassCount: Sendable {
  private let value = Mutex(0)

  var count: Int { value.withLock { $0 } }

  func increment() { value.withLock { $0 += 1 } }
}

/// A vault with a pending OpenRouter charge and a settler whose passes are counted, its lookup answered by `transport`.
@MainActor
struct CostWorld {
  static let host = "openrouter.ai"

  let store: VaultStore
  let transport: StubHTTPTransport
  let passes: PassCount

  init(store: VaultStore, transport: StubHTTPTransport = Self.reply(200), passes: PassCount = PassCount()) {
    self.store = store
    self.transport = transport
    self.passes = passes
  }

  var settler: CostSettler { Self.settler(store: store, transport: transport, passes: passes) }

  static func reply(_ status: Int) -> StubHTTPTransport {
    StubHTTPTransport(statusCode: status, json: status == 200 ? "{\"data\":{\"total_cost\":\"0.0005\"}}" : "{}")
  }

  static func settler(store: VaultStore, transport: StubHTTPTransport, passes: PassCount) -> CostSettler {
    let origin = URL(string: "https://openrouter.ai")
    let lookup = OpenRouterGenerationLookup(
      credential: { () async throws(ModelError) -> ProviderCredential in
        guard let origin, let credential = ProviderCredential(origin: origin, secret: "sk-or-test") else { throw .cancelled }
        return credential
      }, transport: transport)
    let policy = ReconciliationPolicy(maxAttempts: 1, startedGrace: .seconds(0))
    return CostSettler { () throws(StoreError) -> ReconciliationReport in
      passes.increment()
      return try await Ledger.reconcilePending(in: store, using: lookup, policy: policy, sleep: { _ in })
    }
  }

  func addPending(generation: String = "gen-1") async throws -> UUID {
    let entry = ModelCallEntry(
      id: UUID(), provider: Self.host, model: "anthropic/claude", task: .chat, pace: nil, startedMillis: 1_700_000_000_000, generationID: generation, outcome: .finished)
    try await store.write { transaction in try Ledger.open(entry, in: &transaction) }
    return entry.id
  }

  func source(of id: UUID) async throws -> LedgerCostSource? {
    try await store.read { transaction in try Ledger.entries(in: transaction).first { $0.id == id }?.costSource }
  }
}

@MainActor
@Suite("Cost settler in chat", TestTimeLimit.standard)
struct CostSettlerChatTests {
  @Test func shouldSettleOnceWhenAChatTurnEnds() async throws {
    let chat = try await ChatWorld.make([ChatScript.reply("Here it is.")])
    let costs = CostWorld(store: chat.store)
    let runtime = ChatRuntime(store: chat.store, engine: chat.engine, settler: costs.settler)
    let session = try await chat.session()
    let model = runtime.model(for: chat.context).session(session)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the transcript loads") { model.page != nil }

    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Here it is." && model.display == .idle }
    try await ChatWait.until("the turn end settles costs") { costs.passes.count == 1 }
    try await Task.sleep(for: .milliseconds(150))
    #expect(costs.passes.count == 1)
  }

  @Test func shouldSettleWhenTheHookIsSetAfterTheSessionExists() async throws {
    let chat = try await ChatWorld.make([ChatScript.reply("Here it is.")])
    let costs = CostWorld(store: chat.store)
    let novel = ChatNovelModel(context: chat.context, engine: chat.engine)
    let session = try await chat.session()
    let model = novel.session(session)
    let settler = costs.settler
    novel.turnEnded = { settler.settle() }
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the transcript loads") { model.page != nil }

    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the turn end settles costs") { costs.passes.count == 1 }
  }
}
