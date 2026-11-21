import Foundation
import ShadowDesignSystem
import ShadowStore
import SwiftUI

@main
struct NovelForgeApp: App {
  static let libraryWindow = "library"

  #if os(macOS)
    @NSApplicationDelegateAdaptor(NovelForgeAppDelegate.self) private var delegate
  #else
    @UIApplicationDelegateAdaptor(NovelForgeAppDelegate.self) private var delegate
  #endif
  @Environment(\.scenePhase) private var scenePhase
  @State private var chats = ChatRuntimes()
  @State private var settingsTabs = SettingsTabs()

  private var vault: VaultModel { delegate.vault }
  private var sync: SyncRuntimes { delegate.sync }
  private var ai: AIServices { delegate.ai }
  private var jobs: JobRuntimes { delegate.jobs }
  private var retrieval: RetrievalRuntimes { delegate.retrieval }

  var body: some Scene {
    WindowGroup(id: Self.libraryWindow) {
      RootView(vault: vault)
        .environment(ai)
        .environment(chats)
        .environment(jobs)
        .environment(sync)
        .environment(settingsTabs)
        .task { await ai.loadOpenRouterModelsIfKeyed() }
        .task(id: vault.store.map(ObjectIdentifier.init)) { await chats.launch(vault.store, services: ai) }
        .task(id: vault.store.map(ObjectIdentifier.init)) { await jobs.launch(vault.store, services: ai, trustedClock: vault.trustedClock) }
        .task(id: vault.store.map(ObjectIdentifier.init)) { await retrieval.launch(vault.store, embedders: ai.embedders) }
        .task(id: vault.store.map(ObjectIdentifier.init)) { await sync.launch(vault.store, trustedClock: vault.trustedClock) }
        .shadowTheme()
        .flushingUnsavedWork()
        #if os(macOS)
          .frame(minWidth: 900, minHeight: 600)
        #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      Task { await retrieval.phaseChanged(phase) }
      Task { await sync.phaseChanged(phase) }
      Task { await jobs.phaseChanged(phase) }
    }
    .commands { NovelForgeCommands() }
    #if os(macOS)
      .defaultLaunchBehavior(delegate.worker.isOn ? .suppressed : .automatic)
    #endif
    #if os(macOS)
      Settings { NovelForgeSettingsScene(vault: vault, services: ai, sync: sync, jobs: jobs, worker: delegate.worker, tabs: settingsTabs) }
      WorkerMenuBar(worker: delegate.worker, tabs: settingsTabs)
    #endif
  }
}
