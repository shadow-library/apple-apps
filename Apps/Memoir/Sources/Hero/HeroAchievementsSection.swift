import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// Locked achievements keep their name and any counter hidden, as the reference does (`achievements-panel.tsx`): only a teaser shows.
struct HeroAchievementsSection: View {
  let achievements: [AchievementStanding]
  @State private var selection: AchievementID?
  @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 150

  var body: some View {
    ShadowAdaptiveColumns {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: Spacing.space3)], spacing: Spacing.space3) {
        ForEach(achievements) { achievement in tile(achievement) }
      }
      if let selected { detail(selected) }
    }
  }

  private var selected: AchievementStanding? {
    achievements.first { $0.id == selection } ?? achievements.first
  }

  private func tile(_ achievement: AchievementStanding) -> some View {
    let locked = achievement.earnedOn == nil
    let isSelected = achievement.id == selected?.id
    return Button {
      selection = achievement.id
    } label: {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Image(systemName: locked ? "lock" : HeroCatalogue.symbol(of: achievement.id))
          .shadowFont(.title3)
          .foregroundStyle(locked ? ShadowColor.textTertiary : ShadowColor.accentText)
        Text(verbatim: locked ? String(localized: "Locked", table: "Hero") : HeroCatalogue.name(of: achievement.id))
          .shadowFont(.subheadline)
          .foregroundStyle(locked ? ShadowColor.textSecondary : ShadowColor.textPrimary)
        Group {
          if let earned = achievement.earnedOn {
            Text("Earned \(HeroDates.text(earned))", tableName: "Hero")
          } else {
            Text(verbatim: HeroCatalogue.teaser(of: achievement.id))
          }
        }
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.space3)
      .background(isSelected ? ShadowColor.selectionRow : ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(isSelected ? ShadowColor.borderFocus : ShadowColor.borderDefault)
      }
      .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func detail(_ achievement: AchievementStanding) -> some View {
    let earned = achievement.earnedOn
    let earnedCount = achievements.count { $0.earnedOn != nil }
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(earned == nil ? Text("Locked", tableName: "Hero") : Text("Earned", tableName: "Hero"))
        Image(systemName: earned == nil ? "lock" : HeroCatalogue.symbol(of: achievement.id))
          .shadowFont(.largeTitle)
          .foregroundStyle(earned == nil ? ShadowColor.textTertiary : ShadowColor.accentText)
          .accessibilityHidden(true)
        Text(verbatim: earned == nil ? String(localized: "Locked achievement", table: "Hero") : HeroCatalogue.name(of: achievement.id))
          .shadowFont(.title3)
          .foregroundStyle(ShadowColor.textPrimary)
        Text(verbatim: earned == nil ? HeroCatalogue.teaser(of: achievement.id) : HeroCatalogue.description(of: achievement.id))
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        LabeledContent {
          Text(verbatim: earned.map { HeroDates.text($0) } ?? String(localized: "Not yet", table: "Hero"))
        } label: {
          Text("Earned", tableName: "Hero")
        }
        if let cosmetic = achievement.unlocks {
          LabeledContent {
            Text(verbatim: earned == nil ? String(localized: "Unknown until it happens", table: "Hero") : HeroCatalogue.name(of: cosmetic))
          } label: {
            Text("Unlocks", tableName: "Hero")
          }
        }
        Group {
          if earned == nil {
            Text(
              "Locked achievements show no counter and no progress bar. A number here would turn this into a chore, and you will know when it happens.",
              tableName: "Hero")
          } else {
            Text(
              "\(earnedCount) of \(achievements.count) achievements in the catalogue are yours so far. They arrive on their own — there is nothing to claim.",
              tableName: "Hero")
          }
        }
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}
