import Foundation
import ShadowDesignSystem
import ShadowStore
import SwiftUI

@main
struct NovelForgeApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(NovelForgeAppDelegate.self) private var delegate
  #else
    @UIApplicationDelegateAdaptor(NovelForgeAppDelegate.self) private var delegate
  #endif
  @Environment(\.scenePhase) private var scenePhase
  @State private var ai = AIServices.live()
  @State private var chats = ChatRuntimes()
  @State private var jobs = JobRuntimes(host: JobRunHosts.system())
  @State private var retrieval = RetrievalRuntimes()
  @State private var settingsTabs = SettingsTabs()

  private var vault: VaultModel { delegate.vault }
  private var sync: SyncRuntimes { delegate.sync }

  var body: some Scene {
    WindowGroup {
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
      Settings { NovelForgeSettingsScene(vault: vault, services: ai, sync: sync, tabs: settingsTabs) }
    #endif
  }
}
