@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct ButtonPage: View {
  @State private var isPublishing = false

  var body: some View {
    ComponentPage(component: .button) {
      StateSection("Variants", note: "One filled button per view carries the primary action; everything else is tinted, bordered or plain.") {
        FlowRow {
          Button("Continue reading") {}.buttonStyle(.shadowFilled)
          Button("Save", systemImage: "bookmark") {}.buttonStyle(.shadowTinted)
          Button("Share") {}.buttonStyle(.shadowBordered)
          Button("Edit") {}.buttonStyle(.shadowPlain)
        }
      }
      StateSection("Destructive", note: "role: .destructive uses danger-solid fills and destructive-label text, never a custom red.") {
        FlowRow {
          Button("Remove", role: .destructive) {}.buttonStyle(.shadowTinted)
          Button("Delete chapter", role: .destructive) {}.buttonStyle(.shadowFilled)
          Button("Delete…", role: .destructive) {}.buttonStyle(.shadowBordered)
          Button("Delete", role: .destructive) {}.buttonStyle(.shadowPlain)
        }
      }
      StateSection("Hover and pressed", note: "The pointer on iPad and Mac adds accent-hover or bg-hover; touch-down uses accent-active or bg-pressed.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          ForEach(InteractionRow.all) { row in
            FlowRow {
              Button(row.title) {}.buttonStyle(.shadowFilled).shadowPreviewInteraction(row.interaction)
              Button(row.title) {}.buttonStyle(.shadowTinted).shadowPreviewInteraction(row.interaction)
              Button(row.title) {}.buttonStyle(.shadowBordered).shadowPreviewInteraction(row.interaction)
              Button(row.title) {}.buttonStyle(.shadowPlain).shadowPreviewInteraction(row.interaction)
            }
          }
        }
      }
      StateSection("Disabled", note: "Disabled buttons fade to disabled-opacity and ignore input.") {
        FlowRow {
          Button("Continue reading") {}.buttonStyle(.shadowFilled)
          Button("Save", systemImage: "bookmark") {}.buttonStyle(.shadowTinted)
          Button("Share") {}.buttonStyle(.shadowBordered)
          Button("Edit") {}.buttonStyle(.shadowPlain)
        }
        .disabled(true)
      }
      StateSection("Loading", note: "A progress view replaces the label at the same width, and the button is disabled until the work finishes.") {
        FlowRow {
          Button("Publish") {}.buttonStyle(.shadowFilled).shadowLoading(true)
          Button("Save draft") {}.buttonStyle(.shadowTinted).shadowLoading(true)
          Button("Sync") {}.buttonStyle(.shadowBordered).shadowLoading(true)
          Button(isPublishing ? "Publishing" : "Tap to publish") { publish() }
            .buttonStyle(.shadowFilled)
            .shadowLoading(isPublishing)
        }
      }
      StateSection("Sizes", note: "Touch: 36, 44 and 50pt capsules. Mac: 24, 28 and 32pt rounded rectangles.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          FlowRow {
            Button("Small") {}.controlSize(.small)
            Button("Medium") {}
            Button("Large") {}.controlSize(.large)
          }
          .buttonStyle(.shadowFilled)
          FlowRow {
            Button("Small") {}.controlSize(.small)
            Button("Medium") {}
            Button("Large") {}.controlSize(.large)
          }
          .buttonStyle(.shadowBordered)
        }
      }
      StateSection("Full-width call to action", note: "The one action a screen exists for, at the large size across the readable width.") {
        Button(action: {}) {
          Text("Start reading").frame(maxWidth: .infinity)
        }
        .buttonStyle(.shadowFilled)
        .controlSize(.large)
      }
      StateSection("Label with icon", note: "SF Symbols in the regular weight, at the label's text style.") {
        FlowRow {
          Button("Continue reading", systemImage: "book") {}.buttonStyle(.shadowFilled)
          Button("Add to library", systemImage: "plus") {}.buttonStyle(.shadowTinted)
          Button("Share", systemImage: "square.and.arrow.up") {}.buttonStyle(.shadowBordered)
          Button("Learn more", systemImage: "info.circle") {}.buttonStyle(.shadowPlain)
        }
      }
      StateSection("Long label", note: "Labels wrap onto a second line instead of truncating.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          Button("Finalize into canon and notify everyone following The Ninth Archive") {}.buttonStyle(.shadowFilled)
          Button("Keep my answers and close the quest for today") {}.buttonStyle(.shadowBordered)
        }
        .frame(maxWidth: 320, alignment: .leading)
      }
      StateSection("Glass", note: "For floating chrome over content, one tinted action per group. Toolbar items take the system’s toolbar glass instead.") {
        GlassStage(height: 112, alignment: .center) {
          HStack(spacing: Spacing.space3) {
            Button("Save", systemImage: "bookmark") {}.buttonStyle(.shadowGlass)
            Button("Publish") {}.buttonStyle(.shadowGlassProminent)
            Button("Archive") {}.buttonStyle(.shadowGlass).disabled(true)
          }
        }
      }
      StateSection("Default and cancel", note: "Return triggers the default button and Escape cancels, on Mac and with an iPad keyboard.") {
        HStack(spacing: Spacing.space3) {
          Button("Cancel", role: .cancel) {}
            .buttonStyle(.shadowBordered)
            .keyboardShortcut(.cancelAction)
          Button("Publish") {}
            .buttonStyle(.shadowFilled)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func publish() {
    isPublishing = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      isPublishing = false
    }
  }
}

private struct InteractionRow: Identifiable {
  let title: LocalizedStringKey
  let interaction: ShadowButtonInteraction

  var id: ShadowButtonInteraction { interaction }

  static let all = [InteractionRow(title: "Hover", interaction: .hovered), InteractionRow(title: "Pressed", interaction: .pressed)]
}
