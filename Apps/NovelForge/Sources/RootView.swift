import ShadowDesignSystem
import SwiftUI

struct RootView: View {
  let vault: VaultModel

  var body: some View {
    Group {
      switch vault.state {
      case .opening:
        ProgressView()
      case .ready(let store):
        NovelForgeShell(store: store)
      case .locked:
        VaultLockedView { Task { await vault.open() } }
      case .failed(let error):
        VaultFailureView(error: error) { Task { await vault.open() } }
      }
    }
    .task { await vault.open() }
  }
}

struct VaultFailureView: View {
  let error: VaultOpenError
  let retry: () -> Void

  var body: some View {
    ShadowContentUnavailable("Your library could not be opened", kind: .error, message: "Nothing was changed. Try again, or restart the app.") {
      Button("Try Again", action: retry)
    }
    .overlay(alignment: .bottom) {
      Text(verbatim: error.localizedDescription)
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textSecondary)
        .textSelection(.enabled)
        .padding(Spacing.space4)
    }
    .background(ShadowColor.surfaceApp)
  }
}

struct VaultLockedView: View {
  let retry: () -> Void

  var body: some View {
    ShadowContentUnavailable(
      Text("Unlock this device to open your library"), systemImage: "lock",
      message: Text("Your library opens as soon as this device has been unlocked once since it restarted.")
    ) {
      Button("Try Again", action: retry)
    }
    .background(ShadowColor.surfaceApp)
  }
}
