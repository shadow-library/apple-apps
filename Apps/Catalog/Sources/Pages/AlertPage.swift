import ShadowDesignSystem
import SwiftUI

struct AlertPage: View {
  @State private var showsRevoke = false
  @State private var showsSyncFailure = false
  @State private var showsAccountDeletion = false

  var body: some View {
    ComponentPage(component: .alert) {
      StateSection(
        "Destructive alert",
        note:
          "The title asks the question and the buttons answer it: “Revoke”, never “OK”. Cancel comes first. On Mac, Cancel is the default so Return and Escape both cancel; Revoke needs ⌘⌫."
      ) {
        PresentationBackdrop(height: 260, alignment: .bottomLeading) {
          Button("Revoke session…", role: .destructive) { showsRevoke = true }
            .buttonStyle(.shadowFilled)
        }
      }
      StateSection("Acknowledge a failure", note: "One action that names the next step, and a way out. The safe action is the default.") {
        Button("Sync library") { showsSyncFailure = true }
          .buttonStyle(.shadowBordered)
      }
      StateSection("Long text", note: "Titles and messages wrap; long button labels stack instead of truncating.") {
        Button("Delete account…", role: .destructive) { showsAccountDeletion = true }
          .buttonStyle(.shadowBordered)
      }
      StateSection("Success is not an alert", note: "Confirm a background result with a toast instead.") {
        Label("Saved to your library", systemImage: "checkmark.circle")
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
    .alert("Revoke this session?", isPresented: $showsRevoke) {
      Button("Cancel", role: .cancel) {}
        .shadowDialogCancelAction()
      Button("Revoke", role: .destructive) {}
        .shadowDestructiveDialogAction()
    } message: {
      Text("This device will be signed out within a minute.")
    }
    .alert("Couldn’t sync your library", isPresented: $showsSyncFailure) {
      Button("Try again") {}
        .keyboardShortcut(.defaultAction)
      Button("Not now", role: .cancel) {}
    } message: {
      Text("Check your connection, then try again. Your changes are saved on this device.")
    }
    .alert("Delete your account and every novel, chapter and draft in it?", isPresented: $showsAccountDeletion) {
      Button("Cancel", role: .cancel) {}
        .shadowDialogCancelAction()
      Button("Delete account and all novels", role: .destructive) {}
        .shadowDestructiveDialogAction()
    } message: {
      Text(
        "You’ll be signed out of every device. Readers lose access to your published chapters straight away, and Synapse deletes your drafts within 30 days."
      )
    }
    .catalogAutoPresent($showsRevoke)
  }
}
