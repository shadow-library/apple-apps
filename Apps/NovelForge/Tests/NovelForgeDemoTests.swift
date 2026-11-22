import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import SwiftUI
import Testing

@testable import NovelForge

@MainActor
@Suite("Novel Forge demo", TestTimeLimit.standard)
struct NovelForgeDemoModeTests {
  private let root = FileManager.default.temporaryDirectory.appending(path: "NovelForgeDemoTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private var demoDirectory: URL { root.appending(path: DemoDirectory.name, directoryHint: .isDirectory) }

  private func session() -> NovelForgeDemoSession {
    let directory = demoDirectory
    return NovelForgeDemoRun.session(directory: { directory }, pace: .zero)
  }

  private func files(under directory: URL) throws -> [String: Data] {
    let paths = try #require(FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false)) as [String]?)
    var contents: [String: Data] = [:]
    for path in paths.sorted() {
      let url = directory.appending(path: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
      contents[path] = try Data(contentsOf: url)
    }
    return contents
  }

  private func grantNovelText(in store: VaultStore) async throws {
    let disclosure = ConsentDisclosure.novelText
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: DemoModelProvider.host, dataClass: disclosure.dataClass, summary: disclosure.id, atMillis: 1, in: &transaction)
    }
  }

  private func ledger(of store: VaultStore) async throws -> [ModelCallEntry] {
    try await store.read { transaction in try Ledger.entries(in: transaction) }
  }

  @Test("should open the sample library in its own directory and delete it on leaving, leaving the owner's library byte for byte as it was")
  func shouldLeaveTheOwnersLibraryUntouched() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let ownerDirectory = root.appending(path: "Vaults").appending(path: "Default")
    try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
    let owner = try await VaultOpener.open(.file(ownerDirectory.appending(path: "vault.sqlite")))
    let ownNovel = try await LibraryService(store: owner).create(title: "The Owner's Own Saga", notes: "Notes nobody else should ever see.")
    let before = try files(under: ownerDirectory)
    let session = session()

    await session.enter()
    let run = try #require(session.active)
    let demo = try #require(run.vault.store)
    try await grantNovelText(in: demo)
    let chat = ChatRuntime.live(store: demo, services: run.ai, adult: run.adult).engine
    let created = try await demo.createChatSession(novel: NovelForgeDemo.novel)
    let turn = try await chat.send("Tell me about the cast", session: created.id, novel: NovelForgeDemo.novel)
    #expect(await turn.outcome() != .cancelled)
    #expect(FileManager.default.fileExists(atPath: demoDirectory.appending(path: "vault.sqlite").path(percentEncoded: false)))
    await session.leave()

    #expect(try files(under: ownerDirectory) == before)
    #expect(!FileManager.default.fileExists(atPath: demoDirectory.path(percentEncoded: false)))
    let library = try await owner.load(LibraryList.self)
    #expect(library.novels.map(\.novel.id) == [ownNovel])
    #expect(try await ledger(of: owner).isEmpty)
  }

  @Test("should route the demo's calls to the demo model, ledgered and consented in the demo library only")
  func shouldRouteIntoTheDemoLibrary() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = try await VaultOpener.open(.inMemory)
    let run = await NovelForgeDemoRun.start(in: try Self.directory(root), pace: .zero)
    let demo = try #require(run.vault.store)
    let request = AIConsentRequest(provider: .demo, host: DemoModelProvider.host, dataClass: ConsentDisclosure.novelText.dataClass, disclosure: ConsentDisclosure.novelText.id)

    try await run.ai.grant(request, in: demo)
    let engine = ChatRuntime.live(store: demo, services: run.ai, adult: run.adult).engine
    let session = try await demo.createChatSession(novel: NovelForgeDemo.novel)
    let turn = try await engine.send("What should happen next?", session: session.id, novel: NovelForgeDemo.novel)
    guard case .answered = await turn.outcome() else { throw DemoModeTestError.missing("an answer") }

    #expect(run.ai.isDemo)
    #expect(run.ai.hasUsableProvider)
    #expect(!run.adult.isConfirmed)
    #expect(UnrestrictedAccess.live(services: run.ai, adult: run.adult).offer(languageCovered: true) == .notInThisBuild)
    #expect(run.ai.router(store: demo).configuration.provider == .demo)
    let calls = try await ledger(of: demo)
    #expect(!calls.isEmpty)
    #expect(calls.allSatisfy { $0.isDemo })
    #expect(try await run.ai.grantedConsents(in: demo).map(\.host) == [DemoModelProvider.host])
    #expect(try await ledger(of: owner).isEmpty)
    #expect(try await run.ai.grantedConsents(in: owner).isEmpty)
    #expect(ConsentDisclosure.novelForgeDemo.map(\.requirement) == ConsentDisclosure.novelForge.map(\.requirement))
    await run.stop()
  }

  @Test("should write and approve the sample novel's first chapter through the app's job runtime with no key")
  func shouldWriteTheFirstChapterInTheDemo() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let run = await NovelForgeDemoRun.start(in: try Self.directory(root), pace: .zero)
    let demo = try #require(run.vault.store)
    try await grantNovelText(in: demo)
    let runtime = run.jobs.runtime(for: demo, services: run.ai, trustedClock: run.vault.trustedClock)
    await runtime.launch()
    try await JobsWait.until("the demo's jobs run here") { runtime.mode == .running }

    #expect(runtime.startsWhenAsked(.generate))
    let engine = try #require(runtime.engine)
    guard case .running(let handle) = try await engine.generateChapter(novel: NovelForgeDemo.novel, chapter: 1) else {
      throw DemoModeTestError.missing("a generation run here")
    }
    #expect(await handle.result == .settled(.succeeded))
    let ref = try DraftRecord.ref(novel: NovelForgeDemo.novel, chapter: 1)
    let head = try #require(try await demo.read { transaction in try DraftRecord.history(ref, in: transaction).history?.head })
    _ = try await demo.approveChapter(novel: NovelForgeDemo.novel, chapter: 1, revision: head)

    let chapter = try await NovelEvaluation.chapters(novel: NovelForgeDemo.novel, in: demo).chapters.first { $0.chapter == 1 }
    #expect(chapter?.approved == true)
    #expect(chapter?.body == NovelForgeDemo.firstChapter)
    await run.stop()
  }

  @Test("should enter the demo when launched with the demo argument, and not otherwise")
  func shouldEnterOnTheLaunchArgument() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = session()
    await plain.launched(arguments: ["NovelForge"])
    #expect(plain.isOff)

    let requested = session()
    await requested.launched(arguments: ["NovelForge", DemoDirectory.launchArgument])

    let run = try #require(requested.active)
    let store = try #require(run.vault.store)
    #expect(try await store.load(LibraryList.self).novels.map(\.novel.id) == [NovelForgeDemo.novel])
    await requested.leave()
    #expect(!FileManager.default.fileExists(atPath: demoDirectory.path(percentEncoded: false)))
  }

  private static func directory(_ root: URL) throws -> URL {
    let url = root.appending(path: DemoDirectory.name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private enum DemoModeTestError: Error {
  case missing(String)
}

@MainActor
@Suite("Novel Forge window runtimes", TestTimeLimit.standard)
struct NovelForgeWindowRuntimesTests {
  private final class SyncedStores {
    var stores: [ObjectIdentifier] = []
  }

  fileprivate final class SceneHost: JobRunHost {
    private(set) var backgrounds = 0
    private(set) var actives = 0

    func host(_ run: HostedJobRun) {}
    func sceneEnteredBackground() { backgrounds += 1 }
    func sceneBecameActive() { actives += 1 }
  }

  private let root = FileManager.default.temporaryDirectory.appending(path: "NovelForgeWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private static func defaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "NovelForgeWindowTests-\(UUID().uuidString)"))
  }

  private static func owner(
    sync: SyncRuntimes = SyncRuntimes(identity: .novelForge, factory: nil), adult: AdultConfirmationModel? = nil, host: SceneHost = SceneHost()
  ) throws -> NovelForgeRuntimeSet {
    let adult = try adult ?? AdultConfirmationModel(store: AdultConfirmationStore(defaults: defaults()))
    return NovelForgeRuntimeSet(
      vault: NovelForgeVault(open: { wallClock throws(VaultOpenError) in try await VaultOpener.open(.inMemory, wallClock: wallClock) }, hasUnlockedSinceBoot: { true }),
      ai: AIServices.novelForge(defaults: try defaults()), sync: sync, adult: adult, welcome: LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: try defaults())),
      chats: ChatRuntimes(adult: adult), jobs: JobRuntimes(host: host, ageGate: adult.gate), retrieval: RetrievalRuntimes(stopsInBackground: true))
  }

  private func windows(_ owner: NovelForgeRuntimeSet) -> NovelForgeWindowRuntimes {
    let directory = root.appending(path: DemoDirectory.name, directoryHint: .isDirectory)
    return NovelForgeWindowRuntimes(owner: owner, demo: NovelForgeDemoRun.session(directory: { directory }, pace: .zero))
  }

  @Test("should keep the owner's runtimes on the owner's library while the demo runs, and give the window back to them on leaving")
  func shouldKeepTheOwnersRuntimesOnTheirLibrary() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (host, synced) = (SceneHost(), SyncedStores())
    let adult = AdultConfirmationModel(store: AdultConfirmationStore(defaults: try Self.defaults()))
    let sync = SyncRuntimes(identity: .novelForge) { stored, _ in
      synced.stores.append(ObjectIdentifier(stored.store))
      return nil
    }
    let owner = try Self.owner(sync: sync, adult: adult, host: host)
    let windows = windows(owner)
    await owner.vault.open()
    let ownerStore = try #require(owner.vault.store)
    await windows.launchActive()

    await windows.demo.enter()
    let demo = try #require(windows.demo.active)
    #expect(windows.active.vault === demo.vault)
    await windows.launchActive()
    let demoStore = try #require(demo.vault.store)

    #expect(owner.jobs.active?.store === ownerStore)
    #expect(owner.chats.store === ownerStore)
    #expect(owner.retrieval.launched == ObjectIdentifier(ownerStore))
    #expect(synced.stores == [ObjectIdentifier(ownerStore)])
    #expect(demo.jobs.active?.store === demoStore)
    #expect(demo.chats.store === demoStore)
    #expect(demo.retrieval.launched == ObjectIdentifier(demoStore))

    await windows.phaseChanged(.background)
    #expect(host.backgrounds == 1)
    #expect(owner.retrieval.inBackground)
    #expect(demo.retrieval.inBackground)
    await windows.phaseChanged(.active)
    #expect(host.actives == 1)
    #expect(!owner.retrieval.inBackground)

    await windows.demo.leave()
    #expect(windows.active.vault === owner.vault)
    #expect(windows.active.jobs === owner.jobs)
    await windows.launchActive()
    #expect(owner.jobs.active?.store === ownerStore)
    #expect(synced.stores == [ObjectIdentifier(ownerStore)])
  }

  @Test("should offer the demo on the owner's welcome only and enter it from there, with no welcome over the demo's seeded library")
  func shouldOfferTheDemoOnTheWelcome() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let before = UserDefaults.standard.object(forKey: LibraryWelcomeStore.key) as? NSObject
    let owner = try Self.owner()
    let windows = windows(owner)

    let tryDemo = try #require(owner.welcome.tryDemo)
    tryDemo()
    try await JobsWait.until("the welcome enters the demo") { windows.demo.active != nil }

    let demo = try #require(windows.demo.active)
    #expect(windows.active.welcome === demo.welcome)
    #expect(demo.welcome.tryDemo == nil)
    #expect(demo.ai.isReadyForStandardCalls)
    let list = try await try #require(demo.vault.store).load(LibraryList.self)
    #expect(!demo.welcome.shows(list))
    demo.welcome.libraryChanged(list)
    #expect(!owner.welcome.isDone)
    #expect(UserDefaults.standard.object(forKey: LibraryWelcomeStore.key) as? NSObject == before)
    await windows.demo.leave()
    #expect(windows.active.welcome === owner.welcome)
  }

  @Test("should keep the demo's age confirmation and finalize notices out of the owner's defaults")
  func shouldKeepTheDemosChoicesOutOfTheOwnersDefaults() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = [AdultConfirmationStore.key, FinalizeAcknowledgements.key]
    let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
    let directory = root.appending(path: DemoDirectory.name, directoryHint: .isDirectory)
    let session = NovelForgeDemoRun.session(directory: { directory }, pace: .zero)
    await session.enter()
    let run = try #require(session.active)
    let suite = DemoDefaults.suite(for: .novelForge)
    let sets = FinalizePresentation.TwoSets(id: "demo", applied: [], others: [])

    run.adult.confirm()
    FinalizeAcknowledgements.device(isDemo: run.ai.isDemo).acknowledge(sets, novel: NovelForgeDemo.novel, chapter: 1)

    #expect(suite.object(forKey: AdultConfirmationStore.key) != nil)
    #expect(suite.stringArray(forKey: FinalizeAcknowledgements.key)?.isEmpty == false)
    #expect(keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == before)
    await session.leave()
    #expect(suite.object(forKey: AdultConfirmationStore.key) == nil)
    #expect(suite.object(forKey: FinalizeAcknowledgements.key) == nil)
  }
}
