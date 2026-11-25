import MemoirCore
import ShadowDesignSystem
import SwiftUI

struct HeroCardTitle: View {
  let text: Text

  init(_ text: Text) {
    self.text = text
  }

  var body: some View {
    text
      .shadowFont(.headline)
      .foregroundStyle(ShadowColor.textPrimary)
      .accessibilityAddTraits(.isHeader)
  }
}

struct HeroCrestCard: View {
  let deck: HeroDeck

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        HStack(alignment: .top, spacing: Spacing.space4) {
          crest
          VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(verbatim: HeroCopy.heroName(deck.name)).shadowFont(.title2).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: HeroCopy.subtitle(deck)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            HeroLevelProgress(level: deck.level)
          }
        }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Spacing.space6) { tallies }
          VStack(alignment: .leading, spacing: Spacing.space3) { tallies }
        }
      }
    }
  }

  private var crest: some View {
    VStack(spacing: Spacing.space05) {
      Text(deck.level.level, format: .number).shadowFont(.title).monospacedDigit().foregroundStyle(ShadowColor.accentText)
      Text("level", tableName: "Hero").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
    .padding(Spacing.space3)
    .background(ShadowColor.accentSoft, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Level \(deck.level.level)", tableName: "Hero"))
  }

  @ViewBuilder
  private var tallies: some View {
    HeroTally(label: Text("Coins", tableName: "Hero")) {
      Text(deck.coins, format: .number).shadowFont(.headline).monospacedDigit()
    }
    HeroTally(label: Text("HP", tableName: "Hero"), note: Text(verbatim: HeroCopy.hpNote(deck.hp))) {
      HeroHPTally(hp: deck.hp)
    }
    HeroTally(label: Text("Shields", tableName: "Hero")) {
      Text(verbatim: HeroCopy.shields(deck.shields)).shadowFont(.headline).monospacedDigit()
    }
  }
}

struct HeroTally<Value: View>: View {
  let label: Text
  var note: Text?
  @ViewBuilder let value: Value

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      label.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      value.foregroundStyle(ShadowColor.textPrimary)
      if let note { note.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary) }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Pips while the maximum is small enough to count at a glance, a bar beyond it (`hero-screen.tsx:121-140`).
struct HeroHPTally: View {
  static let pipCap = 10

  let hp: DayHP?

  var body: some View {
    if let hp, hp.hpMax > 0 {
      Group {
        if hp.hpMax > Self.pipCap {
          ProgressView(value: Double(hp.hpEnd), total: Double(hp.hpMax)).progressViewStyle(.shadowLinear).frame(minWidth: Spacing.space10 * 2)
        } else {
          HStack(spacing: Spacing.space05) {
            ForEach(0..<hp.hpMax, id: \.self) { index in
              Image(systemName: index < hp.hpEnd ? "heart.fill" : "heart")
                .foregroundStyle(index < hp.hpEnd ? ShadowColor.dangerText : ShadowColor.textTertiary)
            }
          }
          .shadowFont(.footnote)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("HP \(hp.hpEnd) of \(hp.hpMax)", tableName: "Hero"))
    } else {
      Text(verbatim: HeroCopy.noHPYet).shadowFont(.headline)
    }
  }
}

struct HeroLevelProgress: View {
  let level: LevelProgress

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      if level.isHighestLevel {
        ProgressView(value: 1).progressViewStyle(.shadowLinear).accessibilityLabel(Text("Highest level reached", tableName: "Hero"))
        Text("Highest level reached · experience is never taken away", tableName: "Hero").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      } else {
        ProgressView(value: Double(min(level.xpIntoLevel, level.xpForNextLevel)), total: Double(level.xpForNextLevel))
          .progressViewStyle(.shadowLinear)
          .accessibilityLabel(Text("Experience towards level \(level.level + 1)", tableName: "Hero"))
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.space3) { foot }
          VStack(alignment: .leading, spacing: Spacing.space05) { foot }
        }
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  @ViewBuilder
  private var foot: some View {
    Text("\(level.xpIntoLevel) / \(level.xpForNextLevel) XP", tableName: "Hero").monospacedDigit()
    Text("\(max(0, level.xpForNextLevel - level.xpIntoLevel)) to level \(level.level + 1) · experience is never taken away", tableName: "Hero")
  }
}

struct HeroStatsGrid: View {
  let stats: [LifetimeStat]

  var body: some View {
    ShadowStatisticGrid {
      ForEach(stats, id: \.stat) { stat in
        let name = HeroCopy.stat(stat.stat)
        ShadowStatistic(Text(verbatim: name), value: Text(stat.value, format: .number), caption: Text(verbatim: HeroCopy.statNote(stat.stat))) {
          ProgressView(value: Double(stat.percentOfBest), total: 100)
            .progressViewStyle(.shadowLinear)
            .accessibilityLabel(Text("\(name) against your strongest stat", tableName: "Hero"))
        }
      }
    }
  }
}

struct HeroOverviewSection: View {
  let deck: HeroDeck
  let today: LocalDate?
  /// Nil while Money is off.
  var money: MoneyGameSnapshot?
  @Environment(\.locale) private var locale

  var body: some View {
    ShadowAdaptiveColumns {
      progression
      if let money { moneyCard(money) }
      if let crown = deck.crown { crownCard(crown) }
      if let momentum = HeroCopy.momentum(deck.momentum, comingBack: deck.comingBack) { momentumCard(momentum) }
      ShadowCallout(
        Text("Experience only ever goes up", tableName: "Hero"),
        message: Text(
          "Missing a quest can end a streak or spend HP. It never removes experience or a level you have earned, and nothing you have already done is undone.",
          tableName: "Hero"),
        intent: .info)
    }
  }

  private var progression: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(Text("Recent progression", tableName: "Hero"))
        if deck.progression.isEmpty {
          Text("Nothing has happened yet. The first quest you keep appears here, and everything after it stays.", tableName: "Hero")
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
        } else {
          ForEach(deck.progression) { entry in event(entry) }
        }
      }
    }
  }

  private func event(_ entry: ProgressionEntry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(verbatim: HeroCopy.eventTitle(entry)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        let meta = [HeroDates.relative(entry.event.date, today: today), HeroCopy.eventMeta(entry.event)].compactMap(\.self).joined(separator: " · ")
        Text(verbatim: meta).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      Spacer(minLength: Spacing.space2)
      if let value = HeroCopy.eventValue(entry.event) {
        Text(verbatim: value)
          .shadowFont(.subheadline)
          .monospacedDigit()
          .foregroundStyle(entry.isRewarded ? ShadowColor.successText : ShadowColor.textSecondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func crownCard(_ crown: CrownWindow) -> some View {
    let label = HeroCopy.crownLabel(crown.cadence)
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(Text("Crown · \(label)", tableName: "Hero"))
        ProgressView(value: Double(crown.keptPercent), total: 100)
          .progressViewStyle(.shadowLinear)
          .accessibilityLabel(Text("Crown \(label): \(crown.keptPercent)% kept", tableName: "Hero"))
        Text(verbatim: HeroCopy.crownNote(crown)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        if !deck.crownHistory.isEmpty {
          HStack(spacing: Spacing.space2) {
            ForEach(deck.crownHistory) { close in
              let period = HeroCopy.crownClose(close)
              Image(systemName: close.isBanked ? "crown.fill" : "crown")
                .foregroundStyle(close.isBanked ? ShadowColor.accentText : ShadowColor.textTertiary)
                .help(Text(verbatim: period))
                .accessibilityLabel(close.isBanked ? Text("\(period): banked", tableName: "Hero") : Text("\(period): not banked", tableName: "Hero"))
            }
          }
          .shadowFont(.headline)
        }
      }
    }
  }

  /// The money streak once there is money activity, with this week's logging and last week's while it is still open, the saving streak, a debuff in
  /// force and Home's danger badge.
  private func moneyCard(_ money: MoneyGameSnapshot) -> some View {
    let standing = money.standing
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(Text("Money", tableName: "Hero"))
        if money.hasActivity {
          Text(verbatim: HeroMoneyCopy.streak(standing.weekStreak)).shadowFont(.title3).foregroundStyle(ShadowColor.textPrimary)
          if let week = standing.week { weekProgress(week, text: HeroMoneyCopy.week(week)) }
          if let settling = standing.settlingWeek { weekProgress(settling, text: HeroMoneyCopy.settling(settling)) }
        } else {
          Text(verbatim: HeroMoneyCopy.notStarted).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        }
        if standing.savingStreak > 0 {
          Text(verbatim: HeroMoneyCopy.savingStreak(standing.savingStreak)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        }
        ShadowFlowLayout(spacing: Spacing.space2) {
          if let debuff = standing.debuff {
            ShadowBadge(Text(verbatim: HeroMoneyCopy.debuff(debuff, locale: locale)), intent: .warning, systemImage: "arrow.down.circle")
          }
          if let home = money.homeInDanger {
            let content = BudgetRowContent(home, locale: locale)
            ShadowBadge(Text(verbatim: HeroMoneyCopy.home(content.status)), intent: content.tone.badgeIntent, systemImage: content.tone.symbol)
          }
        }
        if let week = standing.week {
          Text("A week counts once \(week.required) of its days are logged, by an expense or by saying you spent nothing.", tableName: "Hero")
            .shadowFont(.caption)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }

  private func weekProgress(_ week: MoneyWeekProgress, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      ProgressView(value: Double(min(week.covered.count, week.required)), total: Double(max(week.required, 1)))
        .progressViewStyle(.shadowLinear)
        .accessibilityHidden(true)
      Text(verbatim: text).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private func momentumCard(_ momentum: String) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        HeroCardTitle(Text("Momentum", tableName: "Hero"))
        Text(verbatim: momentum).shadowFont(.title3).foregroundStyle(ShadowColor.textPrimary)
        Text("Momentum describes the last two weeks. It is not a currency and it cannot go negative.", tableName: "Hero")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}
