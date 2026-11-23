import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowJobs
import ShadowNetworking
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

@MainActor
@Suite("Library welcome", TestTimeLimit.standard)
struct LibraryWelcomeTests {
  private static func defaults() throws -> (UserDefaults, String) {
    let suite = "com.shadow.apps.novelforge.tests.welcome-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  private static func loaded(_ library: LibraryModel) async throws -> LibraryList {
    try await ChatWait.until("the library loads") { library.state.value != nil }
    return try #require(library.state.value)
  }

  @Test("should welcome an empty library until it is dismissed, and stay dismissed on this device")
  func shouldShowOnAnEmptyLibraryUntilDismissed() async throws {
    let (defaults, suite) = try Self.defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = LibraryModel(store: try NovelForgeStore.openInMemory())
    let observing = Task { await library.observe() }
    defer { observing.cancel() }
    let welcome = LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: defaults))
    let empty = try await Self.loaded(library)

    welcome.libraryChanged(empty)
    #expect(welcome.shows(empty))

    welcome.dismiss()

    #expect(!welcome.shows(empty))
    #expect(defaults.persistentDomain(forName: suite)?.keys.sorted() == [LibraryWelcomeStore.key])
    #expect(!LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: defaults)).shows(empty))
  }

  @Test("should end the first run once the library holds a novel, archived or not")
  func shouldEndOnceTheLibraryHoldsANovel() async throws {
    let (defaults, suite) = try Self.defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = LibraryModel(store: try NovelForgeStore.openInMemory())
    let observing = Task { await library.observe() }
    defer { observing.cancel() }
    let welcome = LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: defaults))
    let empty = try await Self.loaded(library)

    let novel = try await library.create(title: "Ashfall", notes: "")
    await library.archive(novel)
    try await ChatWait.until("the novel is archived") { library.state.value?.archived.count == 1 }
    let archivedOnly = try #require(library.state.value)
    #expect(!welcome.shows(archivedOnly))

    welcome.libraryChanged(archivedOnly)

    #expect(welcome.isDone && !welcome.shows(empty))
    #expect(LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: defaults)).isDone)
  }
}

@MainActor
@Suite("Provider prompt", TestTimeLimit.standard)
struct ProviderPromptTests {
  @Test("should ask for a provider instead of sending, keep the message, and send it once one is connected")
  func shouldPromptThenSendOnceConnected() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Mara keeps the harbour keys.")])
    let model = world.model(of: try await world.session())
    var connected = false
    model.providerReady = { connected }
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the transcript loads") { model.page != nil }
    model.draft = "Who is Mara?"

    #expect(await model.send("Who is Mara?") == false)

    #expect(model.needsProvider)
    #expect(model.draft == "Who is Mara?")
    #expect(model.display == .idle && model.messages.isEmpty)
    #expect(world.provider.requests.isEmpty)

    model.needsProvider = false
    connected = true
    await model.providerConnected()

    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Mara keeps the harbour keys." && model.display == .idle }
    #expect(model.transcriptRoles == [.known(.user), .known(.assistant)])
    #expect(model.draft.isEmpty)
  }

  @Test("should send nothing when the sheet closes without a provider, and ask again on the next send")
  func shouldSendNothingWhenNotConnected() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Unused.")])
    let model = world.model(of: try await world.session())
    model.providerReady = { false }

    #expect(await model.send("Who is Mara?") == false)
    model.needsProvider = false
    await model.providerConnected()

    #expect(model.needsProvider)
    #expect(world.provider.requests.isEmpty)
  }

  @Test("should ask for consent after the provider is connected, send nothing until it is allowed, then send exactly once")
  func shouldAskForConsentAfterTheProvider() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Mara keeps the harbour keys.")], granted: false)
    let model = world.model(of: try await world.session())
    var connected = false
    model.providerReady = { connected }
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the transcript loads") { model.page != nil }

    #expect(await model.send("Who is Mara?") == false)
    model.needsProvider = false
    connected = true
    await model.providerConnected()

    let request = try #require(model.consentRequest)
    #expect(world.provider.requests.isEmpty && model.messages.isEmpty)

    try await world.grantConsent(host: request.host)
    model.consentRequest = nil
    await model.consentAllowed()
    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Mara keeps the harbour keys." && model.display == .idle }

    await model.providerConnected()
    await model.consentAllowed()

    #expect(world.provider.requests.count == 1)
    #expect(model.transcriptRoles == [.known(.user), .known(.assistant)])
  }

  @Test("should not hold an unrestricted message for the standard provider, which it does not use")
  func shouldNotHoldAnUnrestrictedMessage() async throws {
    let world = try await ChatWorld.make()
    let model = world.model(of: try await world.session())
    model.providerReady = { false }

    _ = await model.send("Who is Mara?", choices: ChatTurnChoices(contentMode: .unrestricted))

    #expect(!model.needsProvider)
    #expect(model.notice != nil)
  }

  @Test("should hold an action that starts work here until a provider is connected, then run it once")
  func shouldHoldAStartingActionUntilConnected() async {
    let gate = ProviderGate()
    var runs = 0

    await gate.perform(providerReady: false) { runs += 1 }

    #expect(gate.needsProvider && runs == 0)
    gate.needsProvider = false
    await gate.providerConnected()
    await gate.providerConnected()
    #expect(runs == 1)

    await gate.perform(providerReady: true) { runs += 1 }
    #expect(runs == 2 && !gate.needsProvider)
  }

  @Test("should hand every chat of the vault its runtime's provider check")
  func shouldHandEveryChatTheProviderCheck() async throws {
    let world = try await ChatWorld.make()
    let runtime = ChatRuntime(store: world.store, engine: world.engine, providerReady: { false })

    let chats = runtime.model(for: world.context)

    #expect(!chats.session(try await world.session()).providerReady())
  }

  @Test("should show a run's options only once a provider is connected")
  func shouldAskForAProviderBeforeARunsOptions() {
    let model = GenerationModel(novel: UUID(), chapter: 1)

    #expect(model.ask(.generate, providerReady: true) == .generate && !model.needsProvider)
    #expect(model.ask(.regenerate, providerReady: false) == nil && model.needsProvider)

    model.needsProvider = false
    #expect(model.providerConnected() == .regenerate)
    #expect(model.providerConnected() == nil)
  }

  @Test("should need a provider here only for a job that starts on this device")
  func shouldNeedAProviderOnlyForJobsStartingHere() async throws {
    let suite = "com.shadow.apps.novelforge.tests.provider-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let services = AIServices(
      identity: .novelForge, keys: .standard(store: InMemorySecureStore()), settingsStore: AISettingsStore(identity: .novelForge, defaults: defaults),
      transport: URLSessionTransport(), disclosures: ConsentDisclosure.novelForge, requestGuard: { _ in nil })
    let store = try NovelForgeStore.openInMemory()
    let phone = Self.runtime(store: store, platform: .phone)
    let mac = Self.runtime(store: store, platform: .mac)

    #expect(services.isReady(toStart: .generate, on: phone))
    #expect(!services.isReady(toStart: .plan, on: phone))
    #expect(!services.isReady(toStart: .generate, on: mac))
    #expect(!services.isReady(toStart: .plan, on: nil))

    try services.keys.save(try #require(services.keys.makeCredential("sk-ant-test", for: .anthropic)), for: .anthropic)

    #expect(services.isReady(toStart: .generate, on: mac) && services.isReady(toStart: .plan, on: phone))

    try services.saveKey(try #require(services.keys.makeCredential("sk-or-test", for: .openRouter)), for: .openRouter)
    services.update { $0.provider = .openRouter }

    #expect(!services.isReady(toStart: .generate, on: mac) && !services.isReady(toStart: .plan, on: phone))
    #expect(services.isReady(toStart: .generate, on: phone))

    services.update { $0.assignments.models[Pace.allCases[0]] = "vendor/model" }

    #expect(services.isReady(toStart: .generate, on: mac) && services.isReady(toStart: .plan, on: phone))
  }

  private static func runtime(store: VaultStore, platform: JobPlatform) -> JobRuntime {
    JobRuntime(store: store, clock: LeaseClock(trusted: nil), platform: platform) { () throws(JobEngineError) -> JobEngine in throw .engineExists }
  }
}
