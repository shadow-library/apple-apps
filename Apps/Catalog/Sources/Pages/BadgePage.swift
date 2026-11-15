@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct BadgePage: View {
  var body: some View {
    ComponentPage(component: .badge) {
      StateSection("Status", note: "Status always pairs a word with its tone; every intent badge carries a symbol, so colour is never the only signal.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) { StatusBadges() }
          ShadowFlowLayout(spacing: Spacing.space4, lineSpacing: Spacing.space3) {
            ShadowBadge("New", intent: .accent)
            Image(systemName: "bell").imageScale(.large).foregroundStyle(ShadowColor.textPrimary).frame(width: Spacing.space8, height: Spacing.space8).shadowBadge(
              count: 4, ring: ShadowColor.surfaceCard)
            Image(systemName: "tray").imageScale(.large).foregroundStyle(ShadowColor.textPrimary).frame(width: Spacing.space8, height: Spacing.space8).shadowBadge(
              count: 12, ring: ShadowColor.surfaceCard)
          }
          .padding(.trailing, Spacing.space2)
        }
        .shadowCard()
      }
      StateSection("Counts", note: "Counts use danger-solid and tabular figures, cap at 99+ and hide at zero.") {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          ShadowFlowLayout(spacing: Spacing.space3, lineSpacing: Spacing.space3) {
            ForEach([1, 12, 99, 100, 1_204], id: \.self) { ShadowBadge(count: $0) }
            ShadowBadge(count: 0)
            ShadowBadge.dot()
          }
          ShadowFlowLayout(spacing: Spacing.space6, lineSpacing: Spacing.space4) {
            ShadowIconButton("Notifications", systemImage: "bell", badgeCount: 3) {}
            ShadowIconButton("Messages", systemImage: "tray", badgeCount: 120) {}
            ShadowIconButton("Mentions", systemImage: "at") {}.shadowBadgeDot(label: Text("New mentions"))
          }
          .padding(.trailing, Spacing.space2)
        }
        .shadowCard()
      }
      StateSection(
        "Native badges",
        note: "Tab items, sidebar items and list rows use the system `.badge(_:)`; Shadow badges are for status words and counts on custom controls such as icon buttons."
      ) {
        FormBlock {
          FormSection {
            Label("Updates", systemImage: "bell").badge(3)
            Label("Failed deliveries", systemImage: "exclamationmark.triangle").badge(120)
            Label("Drafts", systemImage: "doc").badge(Text("New"))
          }
        }
      }
      StateSection("Disabled", note: "Badges dim with the control they describe.") {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          ShadowBadge("Failed", intent: .danger)
          ShadowBadge(count: 7)
        }
        .disabled(true)
      }
      StateSection("Long text", note: "Keep the label to one or two words; a longer one truncates instead of wrapping.") {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ShadowBadge("Needs review before Friday’s release", intent: .warning)
          ShadowBadge("Scheduled", intent: .info, systemImage: "clock")
        }
        .frame(maxWidth: 220, alignment: .leading)
        .shadowCard()
      }
      StateSection(
        "Platform sizes",
        note: ShadowDensity.current == .touch
          ? "24pt capsules on iPhone and iPad." : "20pt capsules on Mac; sidebar counts are plain text-tertiary numbers unless they need attention."
      ) {
        HStack(spacing: Spacing.space3) {
          ShadowBadge("Draft")
          ShadowBadge("Canon", intent: .success)
          ShadowBadge("Failed", intent: .danger)
        }
        .shadowCard()
      }
      StateSection("Intents in light and dark", note: "Each intent uses bg-subtle, border and text-on-subtle, so copy keeps 4.5:1 in both themes.") {
        SchemePair {
          ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
            StatusBadges()
            ShadowBadge("New", intent: .accent)
          }
        }
      }
      .shadowColumnSpan(.full)
    }
  }
}

private struct StatusBadges: View {
  var body: some View {
    ShadowBadge("Draft")
    ShadowBadge("Scheduled", intent: .info, systemImage: "clock")
    ShadowBadge("Canon", intent: .success)
    ShadowBadge("Needs review", intent: .warning)
    ShadowBadge("Failed", intent: .danger)
  }
}
