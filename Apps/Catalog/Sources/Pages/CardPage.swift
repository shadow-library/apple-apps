@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct CardPage: View {
  var body: some View {
    ComponentPage(component: .card) {
      StateSection("Basic", note: "surface-card on surface-app. No border or shadow on iPhone and iPad; a border-default edge on Mac.") {
        ShadowCard {
          Text("Reading this week")
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
          Text("4 h 12 min")
            .shadowFont(.title)
            .monospacedDigit()
            .foregroundStyle(ShadowColor.textPrimary)
          Text("Across 3 books and 11 chapters.")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textTertiary)
        }
      }
      StateSection("Header and footer", note: "One title, an optional accessory, and at most one action.") {
        DailyQuestsCard()
      }
      StateSection("Tappable", note: "The whole card is one button. It dims on touch-down, lifts under the iPad pointer and gains a stronger edge on Mac.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          ContinueReadingCard(book: CatalogBook.shelf[0], interaction: nil)
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text("Pressed")
              .shadowFont(.caption)
              .foregroundStyle(ShadowColor.textSecondary)
            ContinueReadingCard(book: CatalogBook.shelf[1], interaction: .pressed)
          }
        }
      }
      StateSection("Long content", note: "Titles wrap and prose keeps its line length; nothing truncates.") {
        ShadowCard {
          Text(CatalogBook.prose + " " + CatalogBook.prose)
            .shadowFont(.body)
            .foregroundStyle(ShadowColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
          ShadowCardHeader("Chapter 42 · The Glass Stair, in which Mira finally meets the Archivist", subtitle: "Updated 2 hours ago · 3,214 words")
        }
      }
    }
  }
}

private struct DailyQuestsCard: View {
  private let quests: [(title: LocalizedStringKey, isDone: Bool)] = [
    ("Walk 6,000 steps", true),
    ("Log today’s spending", true),
    ("Drink 2 litres of water", true),
    ("Read for 20 minutes", false),
    ("Stretch for 10 minutes", false),
  ]

  var body: some View {
    ShadowCard {
      ProgressView(value: 0.6)
        .tint(ShadowColor.accent)
        .accessibilityLabel("Daily quests")
      VStack(alignment: .leading, spacing: 0) {
        ForEach(quests.indices, id: \.self) { index in
          QuestRow(title: quests[index].title, isDone: quests[index].isDone)
        }
      }
    } header: {
      ShadowCardHeader("Daily quests", subtitle: "3 of 5 done · 120 XP left today") {
        StreakLabel()
      }
    } footer: {
      Button("Open quests") {}
        .buttonStyle(.shadowTinted)
        .controlSize(.small)
    }
  }
}

private struct QuestRow: View {
  let title: LocalizedStringKey
  let isDone: Bool

  var body: some View {
    Label {
      Text(title).foregroundStyle(ShadowColor.textPrimary)
    } icon: {
      QuestCheckGlyph(isDone: isDone)
    }
    .shadowFont(.body)
    .frame(minHeight: ShadowMetrics.rowHeight)
    .accessibilityAddTraits(isDone ? .isSelected : [])
  }
}

private struct StreakLabel: View {
  var body: some View {
    Label("12-day streak", systemImage: "flame")
      .shadowFont(.caption)
      .foregroundStyle(ShadowColor.infoTextOnSubtle)
      .padding(.horizontal, Spacing.space2)
      .padding(.vertical, Spacing.space05)
      .background(ShadowColor.infoBgSubtle, in: .capsule)
      .overlay { Capsule().strokeBorder(ShadowColor.infoBorder) }
      .fixedSize()
  }
}

private struct ContinueReadingCard: View {
  let book: CatalogBook
  let interaction: ShadowButtonInteraction?

  var body: some View {
    Button(action: {}) {
      HStack(spacing: Spacing.space3) {
        CoverArt(book: book, showsTitle: false)
          .frame(width: 48, height: 64)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text("Continue reading")
            .shadowFont(.caption)
            .foregroundStyle(ShadowColor.accentText)
          Text(verbatim: book.title)
            .shadowFont(.headline)
            .foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: book.progress)
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.forward")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textTertiary)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(.shadowCard)
    .shadowPreviewInteraction(interaction)
  }
}
