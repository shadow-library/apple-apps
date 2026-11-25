import MemoirCore
import ShadowAppShell
import SwiftUI

extension SettingsTabs.Tab {
  static let features = SettingsTabs.Tab("features")
}

/// Settings › Features: pushed on iPhone and iPad, the Settings window's tab on the Mac.
struct MemoirFeaturesLink: View {
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #endif

  var body: some View {
    #if os(macOS)
      Button {
        tabs.selected = .features
        tabs.syncKeys = nil
        openSettings()
      } label: {
        label
      }
    #else
      NavigationLink(value: MemoirRoute.settings(.features)) { label }
    #endif
  }

  static var label: some View {
    Label {
      Text("Features", tableName: "Settings")
    } icon: {
      Image(systemName: "square.grid.2x2")
    }
  }

  private var label: some View { Self.label }
}

/// The Settings screen's ways to Sync and AI settings: pushed pages on iPhone and iPad, the Settings window's tabs on the Mac. Reminders are pushed on
/// every device, since the choice belongs to the device in hand.
struct MemoirSettingsLinks: View {
  let stores: MemoirStores
  @Environment(ReminderScheduler.self) private var reminders: ReminderScheduler?
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #else
    @Environment(SyncRuntimes.self) private var sync
    @Environment(AIServices.self) private var services
  #endif

  var body: some View {
    #if os(macOS)
      Button {
        open(.sync)
      } label: {
        syncLabel
      }
      Button {
        open(.ai)
      } label: {
        aiLabel
      }
    #else
      NavigationLink {
        SyncSettingsView(sync: sync).navigationTitle(Text("Sync", tableName: "Sync"))
      } label: {
        syncLabel
      }
      NavigationLink {
        AISettingsView(services: services, store: stores.main).navigationTitle(Text("AI Settings", tableName: "AI"))
      } label: {
        aiLabel
      }
    #endif
    if let reminders {
      NavigationLink {
        RemindersSettingsView(scheduler: reminders)
      } label: {
        remindersLabel
      }
    }
  }

  #if os(macOS)
    private func open(_ tab: SettingsTabs.Tab) {
      tabs.selected = tab
      tabs.syncKeys = nil
      openSettings()
    }
  #endif

  private var syncLabel: some View {
    Label {
      Text("Sync", tableName: "Sync")
    } icon: {
      Image(systemName: "arrow.triangle.2.circlepath")
    }
  }

  private var remindersLabel: some View {
    Label {
      Text("Reminders", tableName: "Reminders")
    } icon: {
      Image(systemName: "bell")
    }
  }

  private var aiLabel: some View {
    Label {
      Text("AI Settings", tableName: "AI")
    } icon: {
      Image(systemName: "sparkles")
    }
  }
}
