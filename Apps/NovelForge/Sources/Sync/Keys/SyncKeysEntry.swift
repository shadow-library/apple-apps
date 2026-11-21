import ShadowDesignSystem
import ShadowSyncRuntime
import SwiftUI

extension SyncStatus {
  /// This device lacks a key the library uses: the whole key while it waits for one, or a key some devices' changes are sealed with.
  var needsKey: Bool {
    switch self {
    case .attentionNeeded(.awaitingKey), .attentionNeeded(.writingKeyMissing), .attentionNeeded(.keysMissing): true
    default: false
    }
  }
}

/// What Keys and Devices opens on: the page itself, or straight into setting up a recovery phrase when none is set up.
enum SyncKeysStart: Hashable {
  case overview
  case phraseSetup
}

/// Opens Keys and Devices from the sync indicator's popover: in a sheet on iPhone and iPad, in the Sync tab of Settings on the Mac.
struct SyncKeysButton: View {
  let start: SyncKeysStart
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #else
    @Environment(SyncRuntimes.self) private var sync
    @State private var isPresented = false
  #endif

  var body: some View {
    #if os(macOS)
      Button {
        tabs.selected = .sync
        tabs.syncKeys = start
        openSettings()
      } label: {
        label
      }
    #else
      Button {
        isPresented = true
      } label: {
        label
      }
      .sheet(isPresented: $isPresented) { SyncKeysSheet(sync: sync, start: start) }
    #endif
  }

  @ViewBuilder
  private var label: some View {
    switch start {
    case .overview:
      Label {
        Text("Bring the Key Here", tableName: "SyncKeys")
      } icon: {
        Image(systemName: "key")
      }
    case .phraseSetup:
      Label {
        Text("Set Up Recovery Phrase", tableName: "SyncKeys")
      } icon: {
        Image(systemName: "checkmark.shield")
      }
    }
  }
}

#if !os(macOS)
  private struct SyncKeysSheet: View {
    let sync: SyncRuntimes
    let start: SyncKeysStart
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        SyncKeysView(sync: sync, start: start)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button {
                dismiss()
              } label: {
                Text("Done", tableName: "SyncKeys")
              }
            }
          }
      }
    }
  }
#endif

/// The waiting state at the top of Sync Settings, with the way to Keys and Devices.
struct SyncKeysWaitingCallout: View {
  let open: () -> Void

  var body: some View {
    ShadowCallout(
      Text("Waiting for this library's key from your other devices", tableName: "SyncKeys"),
      message: Text("Enter your recovery phrase, or scan from another device, to bring it here now.", tableName: "SyncKeys"), intent: .info, systemImage: "key"
    ) {
      Button(action: open) {
        Text("Bring the Key Here", tableName: "SyncKeys")
      }
    }
  }
}
