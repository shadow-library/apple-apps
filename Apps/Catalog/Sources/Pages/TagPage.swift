@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct TagPage: View {
  private static let genres = ["All", "Fantasy", "Slow burn", "Found family", "Mystery", "Romance"]

  @State private var genre = "All"
  @State private var applied = ["AI drafted", "Spoiler-free"]
  @State private var spoilerFree = true
  @State private var onlyCanon = false
  @State private var tokens = ["fantasy", "slow burn"]
  @State private var text = ""

  var body: some View {
    ComponentPage(component: .tag) {
      StateSection("Filters", note: "A row of toggles above a collection, with All first. Selected filters fill with accent; on iPhone and iPad the row scrolls, on Mac it wraps.")
      {
        FilterRow {
          ForEach(Self.genres, id: \.self) { name in
            ShadowTag(LocalizedStringKey(name), isSelected: Binding(get: { genre == name }, set: { if $0 { genre = name } }))
          }
        }
        .shadowCard()
      }
      StateSection("Applied and removable", note: "Applied filters are soft accent capsules with a leading symbol and a remove button; Add tag is a bordered action.") {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          ForEach(applied, id: \.self) { name in
            ShadowTag(LocalizedStringKey(name), systemImage: name == "AI drafted" ? "sparkles" : nil, removeLabel: "Remove \(name)") { applied.removeAll { $0 == name } }
          }
          ShadowTag("Add tag", systemImage: "plus") { applied.append("Tag \(applied.count + 1)") }
        }
        .shadowCard()
      }
      StateSection("Static", note: "Plain category labels with an optional symbol on a borderless surface-well fill, so they never read as tappable filters.") {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          ShadowTag("Fantasy")
          ShadowTag("Slow burn", systemImage: "flame")
          ShadowTag("Found family", systemImage: "person.2")
        }
        .shadowCard()
      }
      StateSection("Selected and unselected", note: "Selected adds the selected trait for VoiceOver as well as the accent fill.") {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          ShadowTag("Spoiler-free", systemImage: "eye.slash", isSelected: $spoilerFree)
          ShadowTag("Only canon", systemImage: "checkmark.seal", isSelected: $onlyCanon)
        }
        .shadowCard()
      }
      StateSection(
        "Sizes", note: ShadowDensity.current == .touch ? "Medium is 36pt (control-touch-sm) with a 44pt hit area; small is 28pt for dense rows." : "Medium is 22pt; small is 18pt."
      ) {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          ForEach([ControlSize.regular, .small], id: \.self) { size in
            ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
              ShadowTag("All", isSelected: .constant(true))
              ShadowTag("Fantasy", isSelected: .constant(false))
              ShadowTag("AI drafted", systemImage: "sparkles", removeLabel: "Remove AI drafted") {}
              ShadowTag("Add tag", systemImage: "plus") {}
            }
            .controlSize(size)
          }
        }
        .shadowCard()
      }
      StateSection("Hover and pressed", note: "Pointer hover adds bg-hover; touch-down uses bg-pressed or the active accent.") {
        ShadowFlowLayout(spacing: Spacing.space5, lineSpacing: Spacing.space3) {
          ForEach(ShadowButtonInteraction.allCases, id: \.self) { interaction in
            VStack(alignment: .leading, spacing: Spacing.space1) {
              Text(interaction.caption)
                .shadowFont(.caption)
                .foregroundStyle(ShadowColor.textSecondary)
              HStack(spacing: Spacing.space2) {
                ShadowTag("Fantasy", isSelected: .constant(false))
                ShadowTag("All", isSelected: .constant(true))
              }
              .shadowPreviewInteraction(interaction)
            }
          }
        }
        .shadowCard()
      }
      StateSection("Disabled") {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          ShadowTag("All", isSelected: .constant(true))
          ShadowTag("Fantasy", isSelected: .constant(false))
          ShadowTag("AI drafted", systemImage: "sparkles", removeLabel: "Remove AI drafted") {}
          ShadowTag("Add tag", systemImage: "plus") {}
        }
        .disabled(true)
        .shadowCard()
      }
      StateSection("Long text", note: "Labels stay on one line and truncate in the middle rather than growing past the row.") {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          ShadowTag("A very long genre name that cannot fit on one line of the screen", isSelected: .constant(false))
          ShadowTag("Another considerably long applied filter that keeps going", systemImage: "sparkles", removeLabel: "Remove") {}
        }
        .shadowCard()
      }
      StateSection("In a token field", note: "The token field renders its tokens with the same tag; selected tokens fill with accent.") {
        ShadowTokenField("Genres", tokens: $tokens, text: $text, prompt: Text("Add a genre"), suggestions: ["fantasy", "mystery", "romance", "slow burn"]) { Text("Remove \($0)") }
      }
      StateSection("Light and dark") {
        SchemePair {
          ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
            ShadowTag("All", isSelected: .constant(true))
            ShadowTag("Fantasy", isSelected: .constant(false))
            ShadowTag("AI drafted", systemImage: "sparkles", removeLabel: "Remove AI drafted") {}
            ShadowTag("Add tag", systemImage: "plus") {}
          }
        }
      }
      .shadowColumnSpan(.full)
    }
  }
}

private struct FilterRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    #if os(macOS)
      ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) { content }
    #else
      ScrollView(.horizontal) {
        HStack(spacing: Spacing.space2) { content }
          .padding(.vertical, Spacing.space1)
      }
      .scrollIndicators(.hidden)
      .contentMargins(.horizontal, Spacing.space4, for: .scrollContent)
      .padding(.horizontal, -Spacing.space4)
    #endif
  }
}

extension ShadowButtonInteraction {
  var caption: LocalizedStringKey {
    switch self {
    case .idle: "Idle"
    case .hovered: "Hover"
    case .pressed: "Pressed"
    }
  }
}
