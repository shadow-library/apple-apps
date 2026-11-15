import ShadowDesignSystem
import SwiftUI

struct ConfirmationDialogPage: View {
  @State private var showsDelete = false
  @State private var showsPublish = false

  var body: some View {
    ComponentPage(component: .confirmationDialog) {
      StateSection(
        "Destructive choice",
        note:
          "Names the object and says what survives. iPhone: a glass panel anchored to the button, with no separate Cancel row. iPad: a popover anchored to the button; tapping outside cancels. Mac: an alert where Cancel is the default and Delete chapter needs ⌘⌫."
      ) {
        PresentationBackdrop(alignment: .topTrailing) {
          Button("Delete", systemImage: "trash", role: .destructive) { showsDelete = true }
            .buttonStyle(.shadowTinted)
            .confirmationDialog("Delete “The Glass Stair”?", isPresented: $showsDelete, titleVisibility: .visible) {
              Button("Delete chapter", role: .destructive) {}
                .shadowDestructiveDialogAction()
              Button("Move to drafts") {}
              Button("Cancel", role: .cancel) {}
                .shadowDialogCancelAction()
            } message: {
              Text("Readers keep their progress. You can restore it from drafts for 30 days.")
            }
        }
      }
      StateSection("Safe alternatives", note: "Without a destructive option the first choice may be the default; Cancel still closes it.") {
        Button("Publish…") { showsPublish = true }
          .buttonStyle(.shadowBordered)
          .confirmationDialog("Publish chapter 42?", isPresented: $showsPublish, titleVisibility: .visible) {
            Button("Publish now") {}
            Button("Schedule for Friday") {}
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("Readers on Web Novel get a notification when it goes live.")
          }
      }
      StateSection("Undo instead of asking", note: "Actions people can take back don’t need a confirmation; offer Undo in a toast.") {
        ShadowToastView(ShadowToast("Chapter moved to drafts", systemImage: "tray", action: ShadowToastButton("Undo") {}))
      }
    }
    .catalogAutoPresent($showsDelete)
  }
}
