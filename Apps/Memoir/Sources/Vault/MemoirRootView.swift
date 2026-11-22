import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct MemoirRootView: View {
  let vault: MemoirVaultModel

  var body: some View {
    Group {
      switch vault.state {
      case .opening:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(ShadowColor.surfaceApp)
      case .ready(let opened):
        MemoirShell(context: MemoirScreenContext(opened))
      case .locked:
        MemoirVaultLockedView { Task { await vault.open() } }
      case .failed(let error):
        MemoirVaultFailureView(error: error) { Task { await vault.open() } }
      }
    }
    .task { await vault.open() }
  }
}

struct MemoirVaultFailureView: View {
  let error: VaultOpenError
  let retry: () -> Void

  var body: some View {
    ShadowContentUnavailable(
      Text("Your data could not be opened", tableName: "Vault"), kind: .error,
      message: Text("Nothing was changed. Try again, or restart the app.", tableName: "Vault")
    ) {
      Button(action: retry) { Text("Try Again", tableName: "Vault") }
    }
    .overlay(alignment: .bottom) {
      Text(verbatim: error.localizedDescription)
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textSecondary)
        .textSelection(.enabled)
        .padding(Spacing.space4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ShadowColor.surfaceApp)
  }
}

struct MemoirVaultLockedView: View {
  let retry: () -> Void

  var body: some View {
    ShadowContentUnavailable(
      Text("Unlock this device to open your data", tableName: "Vault"), systemImage: "lock",
      message: Text("Memoir opens your data as soon as this device has been unlocked once since it restarted.", tableName: "Vault")
    ) {
      Button(action: retry) { Text("Try Again", tableName: "Vault") }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ShadowColor.surfaceApp)
  }
}

#Preview("Locked") {
  MemoirVaultLockedView {}.shadowTheme()
}

#Preview("Failed") {
  MemoirVaultFailureView(error: .openFailed("The database file is not readable.")) {}.shadowTheme()
}
