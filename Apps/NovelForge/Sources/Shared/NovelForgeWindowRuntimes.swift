import ShadowAppShell
import SwiftUI

/// One library and what serves it: its AI services, sync, age gate, first-run welcome, and chat, job and retrieval runtimes.
@MainActor
struct NovelForgeRuntimeSet {
  let vault: NovelForgeVault
  let ai: AIServices
  let sync: SyncRuntimes
  let adult: AdultConfirmationModel
  let welcome: LibraryWelcomeModel
  let chats: ChatRuntimes
  let jobs: JobRuntimes
  let retrieval: RetrievalRuntimes

  /// Starts every runtime of the set on the set's own library, so no runtime is ever handed another set's store.
  func launch() async {
    let (store, clock) = (vault.store, vault.trustedClock)
    async let chatting: Void = chats.launch(store, services: ai)
    async let running: Void = jobs.launch(store, services: ai, trustedClock: clock)
    async let indexing: Void = retrieval.launch(store, embedders: ai.embedders)
    async let syncing: Void = sync.launch(store, trustedClock: clock)
    _ = await (chatting, running, indexing, syncing)
  }

  func phaseChanged(_ phase: ScenePhase) async {
    async let indexing: Void = retrieval.phaseChanged(phase)
    async let syncing: Void = sync.phaseChanged(phase)
    async let running: Void = jobs.phaseChanged(phase)
    _ = await (indexing, syncing, running)
  }
}

/// What the window runs on: the demo's set while the demo is on, the owner's otherwise. The owner's set keeps its library and hears every scene phase
/// while the demo runs, so its sync, jobs and retrieval still follow the app to the background and back.
@MainActor
final class NovelForgeWindowRuntimes {
  let owner: NovelForgeRuntimeSet
  let demo: NovelForgeDemoSession

  /// The owner's welcome offers the demo; the demo's offers nothing, and its seeded library never shows it.
  init(owner: NovelForgeRuntimeSet, demo: NovelForgeDemoSession) {
    self.owner = owner
    self.demo = demo
    owner.welcome.tryDemo = { Task { await demo.enter() } }
  }

  var active: NovelForgeRuntimeSet { demo.active?.runtimes ?? owner }

  func launchActive() async {
    await active.launch()
  }

  func phaseChanged(_ phase: ScenePhase) async {
    let sets = [owner] + (demo.active.map { [$0.runtimes] } ?? [])
    await withDiscardingTaskGroup { group in
      for set in sets { group.addTask { await set.phaseChanged(phase) } }
    }
  }
}
