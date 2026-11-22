import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Memoir's own section of Sync Settings, shown once the vault is open.
struct MemoirSyncSettingsSection: View {
  let vault: MemoirVaultModel
  @Environment(SyncRuntimes.self) private var sync

  var body: some View {
    if let stores = vault.opened?.stores {
      ActivitySyncSection(model: ActivitySyncModel(main: stores.main, sync: sync)).id(ObjectIdentifier(stores.main))
    }
  }
}

struct ActivitySyncSection: View {
  @State var model: ActivitySyncModel

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        switch model.state {
        case .loading:
          ProgressView().frame(maxWidth: .infinity)
        case .unreadable(let error):
          error.text.foregroundStyle(ShadowColor.textSecondary)
        case .loaded:
          Toggle(isOn: Binding(get: { model.isOn }, set: { isOn in Task { await model.set(isOn) } })) {
            Text("Sync Activity Through iCloud", tableName: "Sync")
          }
          .disabled(model.isSaving)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Activity", tableName: "Sync").shadowFont(.headline)
    } footer: {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text(
          "Steps, workouts and other activity stay on this device when your vault syncs with iCloud. Turn this on to send them through iCloud as well, so your other devices show them. With any other storage, activity always syncs.",
          tableName: "Sync")
        Text(
          "Apple may count activity as health information, which apps may not keep in iCloud, so this setting may go away in a later version. Health data such as weight, heart rate and sleep never goes to iCloud.",
          tableName: "Sync")
        Text(
          "Turning it off stops sending activity through iCloud. Your activity stays on this device, kept out of its backups, and what was already sent stays in iCloud.",
          tableName: "Sync")
      }
    }
    .task { await model.load() }
    .onChange(of: model.sync.status) { Task { await model.load() } }
  }
}

#Preview {
  if let stores = try? MemoirStores.openInMemory() {
    ScrollView {
      ActivitySyncSection(model: ActivitySyncModel(main: stores.main, sync: SyncRuntimes(identity: .memoir, factory: nil))).padding(Spacing.space4)
    }
    .shadowTheme()
  }
}
