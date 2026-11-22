import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

@main
struct MemoirApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(MemoirAppDelegate.self) private var delegate
  #else
    @UIApplicationDelegateAdaptor(MemoirAppDelegate.self) private var delegate
  #endif
  @Environment(\.scenePhase) private var scenePhase
  @State private var settingsTabs = SettingsTabs()

  private var vault: MemoirVaultModel { delegate.vault }
  private var sync: SyncRuntimes { delegate.sync }
  private var ai: AIServices { delegate.ai }

  var body: some Scene {
    WindowGroup {
      MemoirRootView(vault: vault)
        .environment(ai)
        .environment(sync)
        .environment(settingsTabs)
        .environment(delegate.reminders)
        .environment(delegate.insights)
        .syncSettingsSection { MemoirSyncSettingsSection(vault: vault) }
        .task { await ai.loadOpenRouterModelsIfKeyed() }
        .task(id: vault.opened.map { ObjectIdentifier($0.stores.main) }) {
          await delegate.vaultChanged()
          delegate.health.foregrounded(vault.opened)
        }
        .shadowTheme()
        #if os(macOS)
          .frame(minWidth: 800, minHeight: 560)
        #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      Task { await sync.phaseChanged(phase) }
      Task { await delegate.insights.phaseChanged(isActive: phase == .active) }
      guard phase == .active else { return }
      delegate.dayTurns.restart()
      delegate.health.foregrounded(vault.opened)
    }
    #if os(macOS)
      Settings { MemoirSettingsScene(vault: vault, services: ai, sync: sync, tabs: settingsTabs) }
    #endif
  }
}
