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

  private var windows: MemoirWindowRuntimes { delegate.windows }
  private var active: MemoirRuntimeSet { windows.active }

  var body: some Scene {
    WindowGroup {
      MemoirRootView(vault: active.vault)
        .id(ObjectIdentifier(active.vault))
        .environment(active.ai)
        .environment(active.sync)
        .environment(settingsTabs)
        .environment(windows.isDemo ? nil : delegate.reminders)
        .environment(windows.isDemo ? nil : delegate.rates)
        .environment(windows.isDemo ? nil : delegate.modules)
        .environment(active.insights)
        .environment(windows.isDemo ? nil : delegate.deletion)
        .diagnostics(.memoir(active.vault.opened, sync: active.sync, ai: active.ai))
        .vaultDeletionNotice(delegate.deletion)
        .syncSettingsSection { MemoirSyncSettingsSection(vault: active.vault) }
        .demoSession(delegate.demo, identity: .memoir)
        .loadsOpenRouterModels(active.ai)
        .task(id: active.vault.opened.map { ObjectIdentifier($0.stores.main) }) { await windows.activeVaultChanged() }
        .shadowTheme()
        #if os(macOS)
          .frame(minWidth: 800, minHeight: 560)
        #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      Task { await windows.phaseChanged(phase) }
    }
    #if os(macOS)
      Settings {
        MemoirSettingsScene(
          vault: active.vault, services: active.ai, sync: active.sync, effects: windows.isDemo ? nil : delegate.modules, tabs: settingsTabs
        )
        .demoOffer(delegate.demo)
      }
    #endif
  }
}
