import ShadowDesignSystem
import SwiftUI

struct RootView: View {
  let vault: VaultModel

  var body: some View {
    Group {
      switch vault.state {
      case .opening:
        ProgressView()
      case .ready:
        LibraryPlaceholderView()
      case .failed(let error):
        VaultFailureView(error: error) { Task { await vault.open() } }
      }
    }
    .task { await vault.open() }
  }
}

struct LibraryPlaceholderView: View {
  var body: some View {
    NavigationSplitView {
      List {
        Label("Library", systemImage: "books.vertical")
      }
      .navigationTitle("Novel Forge")
    } detail: {
      ShadowContentUnavailable("No novels yet", systemImage: "book.closed", message: "Your library will appear here.")
        .background(ShadowColor.surfaceApp)
    }
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
