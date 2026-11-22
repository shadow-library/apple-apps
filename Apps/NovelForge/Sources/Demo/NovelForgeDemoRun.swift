import Foundation
import NovelForgeCore
import OSLog
import ShadowAI
import ShadowAppShell
import ShadowStore

typealias NovelForgeDemoSession = DemoSession<NovelForgeDemoRun>

/// What the app runs while the demo is on, in place of the owner's: the sample library in the demo's own directory, the demo model, a sync that never
/// attaches, and chat, job and retrieval runtimes of its own, so the owner's runtimes stay on the owner's library.
@MainActor
final class NovelForgeDemoRun {
  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "demo")

  let vault: NovelForgeVault
  let ai: AIServices
  let sync = SyncRuntimes(identity: .novelForge, factory: nil)
  /// Never confirmed, as the demo offers no way to: its chats, jobs and novels get a gate that never passes.
  let adult = AdultConfirmationModel.demo()
  let welcome = LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: DemoDefaults.suite(for: .novelForge)))
  let chats: ChatRuntimes
  /// The demo library has no worker to wait for, so every job runs where it is asked for, as on a Mac.
  let jobs: JobRuntimes
  let retrieval = RetrievalRuntimes()

  init(vault: NovelForgeVault, ai: AIServices) {
    self.vault = vault
    self.ai = ai
    chats = ChatRuntimes(adult: adult)
    jobs = JobRuntimes(ageGate: adult.gate, platform: .mac)
  }

  var runtimes: NovelForgeRuntimeSet {
    NovelForgeRuntimeSet(vault: vault, ai: ai, sync: sync, adult: adult, welcome: welcome, chats: chats, jobs: jobs, retrieval: retrieval)
  }

  static func session(directory: @escaping NovelForgeDemoSession.Locate = DemoDirectory.appLocation, pace: Duration = DemoModelProvider.readingPace)
    -> NovelForgeDemoSession
  {
    NovelForgeDemoSession(
      directory: directory, defaultsSuite: DemoDefaults.suiteName(for: .novelForge), start: { directory in await start(in: directory, pace: pace) },
      stop: { run in await run.stop() })
  }

  static func start(in directory: URL, pace: Duration = DemoModelProvider.readingPace) async -> NovelForgeDemoRun {
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let vault = NovelForgeVault { wallClock throws(VaultOpenError) in
      let store = try await VaultOpener.open(location, wallClock: wallClock)
      do throws(StoreError) {
        try store.setExcludedFromBackup(true)
      } catch {
        logger.notice("The demo library stays in backups code=\(error.code, privacy: .public)")
      }
      do {
        try await NovelForgeDemo.seed(in: store)
      } catch {
        throw .openFailed(error.localizedDescription)
      }
      return store
    }
    let ai = AIServices.demo(
      identity: .novelForge, script: NovelForgeDemo.script, disclosures: ConsentDisclosure.novelForgeDemo, requestGuard: { ModelRequestGuard.hardLine(for: $0) },
      pace: pace)
    let run = NovelForgeDemoRun(vault: vault, ai: ai)
    await vault.open()
    return run
  }

  /// Stops every runtime on the demo library, then closes it so nothing writes while its files go.
  func stop() async {
    jobs.shutDown()
    await retrieval.shutDown()
    await sync.shutDown()
    guard let store = vault.store else { return }
    ai.settler(for: store).shutDown()
    do {
      try store.close()
    } catch {
      Self.logger.notice("The demo library was still in use as it closed code=\(error.code, privacy: .public)")
    }
  }
}

extension ConsentDisclosure {
  nonisolated static let novelForgeDemo = [
    ConsentDisclosure(
      id: novelText.id, dataClass: novelText.dataClass, title: { String(localized: "The sample novel's text", table: "Demo") },
      explanation: { _ in
        String(
          localized:
            "In the demo, Novel Forge reads the parts of the sample novel a request needs and your message, and the demo answers them from a script on this device. Nothing is sent anywhere.",
          table: "Demo")
      })
  ]
}
