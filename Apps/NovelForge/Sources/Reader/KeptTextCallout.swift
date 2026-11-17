import ShadowDesignSystem
import SwiftUI

struct KeptTextCallout: View {
  let kept: ChapterText
  let onDiscard: () async -> Void
  @State private var showing = false
  @State private var confirmingDiscard = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowCallout(
        Text("Text kept on this device", tableName: "Reader"), message: Text("It is not part of the chapter and is not synced.", tableName: "Reader"), intent: .warning
      ) {
        HStack {
          Button {
            showing.toggle()
          } label: {
            if showing { Text("Hide", tableName: "Reader") } else { Text("Show", tableName: "Reader") }
          }
          Button {
            Clipboard.copy(kept.title.isEmpty ? kept.body : "\(kept.title)\n\n\(kept.body)")
          } label: {
            Text("Copy", tableName: "Reader")
          }
          Button(role: .destructive) {
            confirmingDiscard = true
          } label: {
            Text("Discard", tableName: "Reader")
          }
        }
      }
      if showing {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          if let title = ChapterDisplay.title(kept.title) { Text(verbatim: title).shadowFont(.title2).foregroundStyle(ShadowColor.textPrimary) }
          ProseView(markdown: kept.body)
        }
      }
    }
    .confirmationDialog(Text("Discard the kept text?", tableName: "Reader"), isPresented: $confirmingDiscard, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { await onDiscard() }
      } label: {
        Text("Discard", tableName: "Reader")
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Reader")
      }
    } message: {
      Text("This text is not saved anywhere else and cannot be recovered.", tableName: "Reader")
    }
  }
}
