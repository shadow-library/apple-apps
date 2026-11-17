import ShadowDesignSystem
import SwiftUI

/// A plain message field with Send, which turns into Stop while a turn runs (apps/novel-forge-web/src/features/chat/ChatColumn.tsx:1029-1039). The
/// composer with modes, passages and options replaces it.
struct ChatComposerPlaceholder: View {
  @Binding var draft: String
  let canSend: Bool
  let isSending: Bool
  let isLocked: Bool
  let isRunning: Bool
  let send: () -> Void
  var stop: (() -> Void)?

  var body: some View {
    HStack(alignment: .bottom, spacing: Spacing.space2) {
      TextField(text: $draft, prompt: Text("Message Forge", tableName: "Chat"), axis: .vertical) {
        Text("Message", tableName: "Chat")
      }
      .lineLimit(1...8)
      .shadowField()
      .disabled(isLocked || isSending)
      .onSubmit(submit)
      if isRunning, let stop {
        Button(action: stop) {
          Label {
            Text("Stop", tableName: "Chat")
          } icon: {
            Image(systemName: "stop.fill")
          }
        }
        .keyboardShortcut(".", modifiers: .command)
      } else {
        Button(action: submit) {
          Label {
            Text("Send", tableName: "Chat")
          } icon: {
            Image(systemName: "arrow.up")
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
      }
    }
    .labelStyle(.iconOnly)
    .padding(Spacing.space3)
    .background(ShadowColor.surfaceApp)
  }

  private func submit() {
    guard canSend else { return }
    send()
  }
}
