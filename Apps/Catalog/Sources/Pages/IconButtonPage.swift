@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct IconButtonPage: View {
  var body: some View {
    ComponentPage(component: .iconButton) {
      StateSection("In bars", note: "Glass circles float over content; related actions share one glass capsule, and one action is tinted.") {
        GlassStage(height: 200) {
          HStack(spacing: Spacing.space2) {
            ShadowIconButton("Back", systemImage: "chevron.backward", variant: .glass) {}
            Spacer(minLength: 0)
            BarActions()
          }
        }
      }
      StateSection("In content", note: "Filled, tinted or plain; a destructive action also uses the trash symbol. Counts sit on the top-trailing corner.") {
        FlowRow(spacing: Spacing.space4) {
          if ShadowDensity.current == .touch {
            ShadowIconButton("New quest", systemImage: "plus", variant: .filled) {}
            ShadowIconButton("Favourite", systemImage: "heart", variant: .tinted) {}
          } else {
            ShadowIconButton("New quest", systemImage: "plus", variant: .bordered) {}
          }
          ShadowIconButton("Delete chapter", systemImage: "trash", variant: ShadowDensity.current == .touch ? .plain : .bordered, role: .destructive) {}
          ShadowIconButton("Refresh deliveries", systemImage: "arrow.clockwise") {}.keyboardShortcut("r")
          ShadowIconButton("Notifications", systemImage: "bell", badgeCount: 3) {}
        }
      }
      StateSection("Capsule group", note: "Related bar actions merge into one glass capsule; the items inside take text-primary.") {
        GlassStage(height: 104, alignment: .center) {
          HStack(spacing: Spacing.space3) {
            ShadowIconButtonGroup {
              ShadowIconButton("Bold", systemImage: "bold", variant: .glass) {}
              ShadowIconButton("Italic", systemImage: "italic", variant: .glass) {}
              ShadowIconButton("Link", systemImage: "link", variant: .glass) {}
            }
            ShadowIconButtonGroup {
              ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .glass) {}
              ShadowIconButton("More", systemImage: "ellipsis", variant: .glass) {}
            }
          }
        }
      }
      StateSection("Sizes", note: "Small, medium and large. On touch the hit area stays at least 44pt even when the circle is smaller.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          SizeRow(variant: .filled)
          SizeRow(variant: .tinted)
          SizeRow(variant: .bordered)
          GlassStage(height: 84, alignment: .leading) {
            SizeRow(variant: .glass)
          }
        }
      }
      StateSection("Hover and pressed", note: "Pointer hover adds bg-hover; touch-down uses bg-pressed or the active accent.") {
        FlowRow(spacing: Spacing.space4) {
          ForEach(ShadowButtonInteraction.allCases, id: \.self) { interaction in
            ShadowIconButton("Favourite", systemImage: "heart", variant: .tinted) {}.shadowPreviewInteraction(interaction)
          }
          ForEach(ShadowButtonInteraction.allCases, id: \.self) { interaction in
            ShadowIconButton("Refresh deliveries", systemImage: "arrow.clockwise") {}.shadowPreviewInteraction(interaction)
          }
        }
      }
      StateSection("Disabled") {
        FlowRow(spacing: Spacing.space4) {
          ShadowIconButton("New quest", systemImage: "plus", variant: .filled) {}
          ShadowIconButton("Favourite", systemImage: "heart", variant: .tinted) {}
          ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .bordered) {}
          ShadowIconButton("Notifications", systemImage: "bell", badgeCount: 3) {}
        }
        .disabled(true)
      }
      StateSection("Counts", note: "Counts use danger-solid, tabular figures, and cap at 99+.") {
        FlowRow(spacing: Spacing.space4) {
          ShadowIconButton("Notifications", systemImage: "bell", badgeCount: 3) {}
          ShadowIconButton("Messages", systemImage: "tray", badgeCount: 12) {}
          ShadowIconButton("Mentions", systemImage: "at", badgeCount: 120) {}
        }
      }
    }
  }
}

private struct BarActions: View {
  var body: some View {
    HStack(spacing: Spacing.space2) {
      if ShadowDensity.current == .touch {
        ShadowIconButtonGroup {
          ShadowIconButton("Bookmark", systemImage: "bookmark", variant: .glass) {}
          ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .glass) {}
          ShadowIconButton("More", systemImage: "ellipsis", variant: .glass) {}
        }
        ShadowIconButton("Done", systemImage: "checkmark", variant: .glassProminent) {}
      } else {
        ShadowIconButtonGroup {
          ShadowIconButton("Bold", systemImage: "bold", variant: .glass) {}
          ShadowIconButton("Italic", systemImage: "italic", variant: .glass) {}
          ShadowIconButton("Link", systemImage: "link", variant: .glass) {}
        }
        ShadowIconButtonGroup {
          ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .glass) {}
          ShadowIconButton("More", systemImage: "ellipsis", variant: .glass) {}
        }
      }
    }
  }
}

private struct SizeRow: View {
  let variant: ShadowButtonVariant

  var body: some View {
    HStack(spacing: Spacing.space4) {
      ShadowIconButton("Bookmark", systemImage: "bookmark", variant: variant) {}.controlSize(.small)
      ShadowIconButton("Bookmark", systemImage: "bookmark", variant: variant) {}
      ShadowIconButton("Bookmark", systemImage: "bookmark", variant: variant) {}.controlSize(.large)
    }
  }
}
