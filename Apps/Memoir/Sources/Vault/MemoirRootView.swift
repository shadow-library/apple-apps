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
        MemoirShell(stores: opened.stores)
      case .failed(let error):
        MemoirVaultFailureView(error: error) { Task { await vault.open() } }
      }
    }
    .task { await vault.open() }
  }
}

struct MemoirVaultFailureView: View {
  let error: MemoirVaultOpenError
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

#Preview("Failed") {
  MemoirVaultFailureView(error: .openFailed("The database file is not readable.")) {}.shadowTheme()
}
