import Foundation
import ShadowAppShell
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
  @State private var settingsTabs = SettingsTabs()

  private var active: NovelForgeRuntimeSet { delegate.windows.active }

  var body: some Scene {
    WindowGroup(id: Self.libraryWindow) {
      RootView(vault: active.vault)
        .id(ObjectIdentifier(active.vault))
        .environment(active.ai)
        .environment(active.chats)
        .environment(active.adult)
        .environment(active.welcome)
        .environment(active.jobs)
        .environment(active.sync)
        .environment(settingsTabs)
        .diagnostics(.novelForge(store: active.vault.store, sync: active.sync, ai: active.ai))
        .task(id: ObjectIdentifier(active.ai)) { await active.ai.loadOpenRouterModelsIfKeyed() }
        .task(id: active.vault.store.map(ObjectIdentifier.init)) { await delegate.windows.launchActive() }
        .demoSession(delegate.demo, identity: .novelForge)
        .shadowTheme()
        .flushingUnsavedWork()
        #if os(macOS)
          .frame(minWidth: 900, minHeight: 600)
        #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      Task { await delegate.windows.phaseChanged(phase) }
    }
    .commands { NovelForgeCommands() }
    #if os(macOS)
      .defaultLaunchBehavior(delegate.worker.isOn ? .suppressed : .automatic)
    #endif
    #if os(macOS)
      Settings {
        NovelForgeSettingsScene(
          vault: active.vault, services: active.ai, sync: active.sync, adult: active.adult, jobs: active.jobs, worker: delegate.worker, tabs: settingsTabs
        )
        .diagnostics(.novelForge(store: active.vault.store, sync: active.sync, ai: active.ai))
        .demoOffer(delegate.demo)
      }
      WorkerMenuBar(worker: delegate.worker, tabs: settingsTabs)
    #endif
  }
}
