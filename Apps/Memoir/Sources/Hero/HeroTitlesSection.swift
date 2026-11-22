import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// Titles are earned, never chosen: unearned ones are not listed at all, so there is nothing to aim at (`titles-panel.tsx`).
struct HeroTitlesSection: View {
  let deck: HeroDeck
  let model: HeroModel

  var body: some View {
    let earned = deck.titles.filter { $0.earnedOn != nil }
    if earned.isEmpty {
      ShadowCard {
        ShadowContentUnavailable(
          Text("No titles yet", tableName: "Hero"), systemImage: "text.badge.star",
          message: Text(
            "Titles arrive by themselves, from patterns you keep rather than goals you set. There is nothing to unlock and nothing to aim at, so this stays quiet until the first one appears.",
            tableName: "Hero"))
      }
    } else {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        ShadowAdaptiveColumns {
          ForEach(earned) { title in card(title) }
        }
        VStack(alignment: .leading, spacing: Spacing.space1) {
          if earned.count < deck.titles.count {
            Text("The rest of the catalogue arrives on its own, with no hints and no counters.", tableName: "Hero")
          }
          Text("One title is shown at a time, and every one you have earned is kept whatever you display.", tableName: "Hero")
        }
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
        if deck.titles.contains(where: \.isDisplayed) {
          Button {
            Task { await model.clearTitle() }
          } label: {
            Text("Clear displayed title", tableName: "Hero")
          }
          .buttonStyle(.shadowPlain)
          .disabled(model.pending != nil)
        }
      }
    }
  }

  private func card(_ title: TitleStanding) -> some View {
    let name = HeroCatalogue.name(of: title.id)
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        HStack(spacing: Spacing.space2) {
          Text(verbatim: name).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          if title.isDisplayed { ShadowBadge(Text("Displayed", tableName: "Hero"), intent: .info) }
        }
        if let earnedOn = title.earnedOn {
          Text("\(HeroCatalogue.earnedFrom(title.id)) · earned \(HeroDates.text(earnedOn))", tableName: "Hero")
            .shadowFont(.caption)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        Button {
          Task { await model.display(title.id) }
        } label: {
          if title.isDisplayed { Text("Displayed", tableName: "Hero") } else { Text("Display \(name)", tableName: "Hero") }
        }
        .buttonStyle(ShadowButtonStyle(title.isDisplayed ? .plain : .bordered))
        .disabled(title.isDisplayed || model.pending != nil)
      }
    }
  }
}
