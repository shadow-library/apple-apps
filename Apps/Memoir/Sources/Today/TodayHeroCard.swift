import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// `features/today/hero-card.tsx`: level and experience to the next, coins, HP, the Crown's period and momentum.
struct TodayHeroCard: View {
  private static let pipLimit = 10

  let hero: TodayHero
  let summary: DaySummary?
  let comingBack: ComingBackReason?
  let showsCrown: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      HStack(alignment: .top, spacing: Spacing.space3) {
        crest
        VStack(alignment: .leading, spacing: Spacing.space2) {
          HStack(alignment: .firstTextBaseline) {
            title
            Spacer(minLength: Spacing.space2)
            Label {
              Text(verbatim: hero.coins.formatted())
            } icon: {
              Image(systemName: "circle.hexagonpath")
            }
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
            .accessibilityLabel(Text("\(hero.coins) coins", tableName: "Today"))
          }
          levelProgress
        }
      }
      ShadowFlowLayout(spacing: Spacing.space3) {
        if let hp = summary?.hp, hp.hpMax > 0 { hpMeter(hp) }
        if showsCrown, let crown = summary?.crown { crownText(crown) }
        Text("Momentum \(momentum)", tableName: "Today").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        NavigationLink(value: MemoirRoute.destination(.hero)) {
          Text("Hero", tableName: "Today")
        }
        .buttonStyle(.shadowPlain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }

  private var crest: some View {
    VStack(spacing: 0) {
      Text(verbatim: hero.level.level.formatted()).shadowFont(.title2).foregroundStyle(ShadowColor.onAccent)
      Text("lvl", tableName: "Today").shadowFont(.caption2).foregroundStyle(ShadowColor.onAccent)
    }
    .frame(minWidth: ShadowMetrics.tapTarget, minHeight: ShadowMetrics.tapTarget)
    .background(ShadowColor.accent, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Level \(hero.level.level)", tableName: "Today"))
  }

  @ViewBuilder
  private var title: some View {
    if case .title(let id) = hero.name {
      Text(verbatim: Self.titleName(id)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
    } else {
      Text("No title displayed", tableName: "Today").shadowFont(.subheadline).foregroundStyle(ShadowColor.textTertiary)
    }
  }

  @ViewBuilder
  private var levelProgress: some View {
    let level = hero.level
    if level.isHighestLevel {
      ProgressView(value: 1).progressViewStyle(.shadowLinear).accessibilityLabel(Text("Highest level reached", tableName: "Today"))
      Text("Highest level reached", tableName: "Today").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    } else {
      ProgressView(value: Double(min(level.xpIntoLevel, level.xpForNextLevel)), total: Double(level.xpForNextLevel))
        .progressViewStyle(.shadowLinear)
        .accessibilityLabel(Text("Experience towards level \(level.level + 1)", tableName: "Today"))
      HStack {
        Text("\(level.xpIntoLevel.formatted()) / \(level.xpForNextLevel.formatted()) XP", tableName: "Today").monospacedDigit()
        Spacer(minLength: Spacing.space2)
        Text("\(max(0, level.xpForNextLevel - level.xpIntoLevel).formatted()) XP to level \(level.level + 1)", tableName: "Today")
      }
      .shadowFont(.caption)
      .foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private func hpMeter(_ hp: DayHP) -> some View {
    let shown = min(max(hp.hpEnd, 0), hp.hpMax)
    return HStack(spacing: Spacing.space2) {
      if hp.hpMax < Self.pipLimit {
        HStack(spacing: Spacing.space05) {
          ForEach(0..<hp.hpMax, id: \.self) { index in
            Circle().fill(index < shown ? ShadowColor.dangerSolid : ShadowColor.fillTrack).frame(width: Spacing.space2, height: Spacing.space2)
          }
        }
      } else {
        ProgressView(value: Double(shown), total: Double(hp.hpMax)).progressViewStyle(.shadowLinear).frame(width: Spacing.space10 * 2)
      }
      Text("HP \(hp.hpEnd) of \(hp.hpMax)", tableName: "Today").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("HP \(hp.hpEnd) of \(hp.hpMax)", tableName: "Today"))
  }

  /// `crownProgress` (`hero-card.tsx:24-27`).
  private func crownText(_ crown: CrownWindow) -> some View {
    Group {
      switch crown.cadence {
      case .daily: Text("Crown · today · \(crown.keptPercent)% kept", tableName: "Today")
      case .weekly: Text("Crown · this week · day \(crown.dayIndex) of \(crown.dayCount) · \(crown.keptPercent)% kept", tableName: "Today")
      }
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.textSecondary)
  }

  /// `momentumLabel` (`hero-card.tsx:18-22`): a day not yet opened is a start, and a return is framed as one.
  private var momentum: String {
    guard let summary else { return String(localized: "starting", table: "Today") }
    if comingBack == .returner || comingBack == .recovery { return String(localized: "returning", table: "Today") }
    return switch summary.momentum {
    case .cold: String(localized: "settling", table: "Today")
    case .steady: String(localized: "steady", table: "Today")
    case .warm: String(localized: "warm", table: "Today")
    }
  }

  /// `TITLES` (`lib/data/hero.provider.ts:173-191`).
  static func titleName(_ id: TitleID) -> String {
    switch id {
    case .steadyBuilder: String(localized: "Steady Builder", table: "Today")
    case .bodyTempered: String(localized: "Body Tempered", table: "Today")
    case .wealthDisciplined: String(localized: "Wealth Disciplined", table: "Today")
    case .mindCultivated: String(localized: "Mind Cultivated", table: "Today")
    case .anchorHolder: String(localized: "Anchor Holder", table: "Today")
    case .goalKeeper: String(localized: "Goal Keeper", table: "Today")
    case .routineForged: String(localized: "Routine Forged", table: "Today")
    case .quietClimber: String(localized: "Quiet Climber", table: "Today")
    case .architect: String(localized: "Architect", table: "Today")
    case .honestPlanner: String(localized: "Honest Planner", table: "Today")
    case .reflectivePractitioner: String(localized: "Reflective Practitioner", table: "Today")
    case .restorer: String(localized: "Restorer", table: "Today")
    case .returner: String(localized: "Returner", table: "Today")
    case .comebackSteady: String(localized: "Comeback Steady", table: "Today")
    case .optionalSurplus: String(localized: "Optional Surplus", table: "Today")
    case .crossStatClimber: String(localized: "Cross-Stat Climber", table: "Today")
    case .quietYear: String(localized: "Quiet Year", table: "Today")
    }
  }
}
