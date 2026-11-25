import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// A goal's progress ring around its symbol; whoever shows it reads the goal aloud.
struct GoalRing: View {
  let symbol: String
  let thousandths: Int

  var body: some View {
    ProgressView(value: Double(thousandths), total: 1000)
      .progressViewStyle(.shadowRing)
      .controlSize(.large)
      .overlay {
        Image(systemName: symbol).imageScale(.small).foregroundStyle(ShadowColor.textSecondary)
      }
      .accessibilityHidden(true)
  }
}

/// One active goal as a chip: its ring, its name and how much is saved, opening the goal.
struct GoalChip: View {
  let share: GoalShare
  let forecast: GoalForecast?
  @Environment(\.locale) private var locale

  var body: some View {
    NavigationLink(value: MemoirRoute.money(.goal(share.id))) {
      HStack(spacing: Spacing.space2) {
        GoalRing(symbol: share.goal.symbol, thousandths: share.progressThousandths)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text(verbatim: share.goal.name).shadowFont(.subheadline).fontWeight(.semibold).lineLimit(2)
          Text(verbatim: GoalCopy.saved(share, locale: locale)).shadowFont(.caption).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
          if let short = GoalCopy.short(forecast, locale: locale) {
            Text(verbatim: short).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      .padding(Spacing.space2)
    }
    .buttonStyle(.shadowCard)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: GoalCopy.accessibilityLabel(share, forecast: forecast, locale: locale)))
    .accessibilityAddTraits(.isLink)
  }
}

/// The active goals' chips in fill order.
struct GoalChips: View {
  let snapshot: SavingsSnapshot

  var body: some View {
    ShadowFlowLayout(spacing: Spacing.space2) {
      ForEach(snapshot.active) { share in
        GoalChip(share: share, forecast: snapshot.overview.forecast(of: share.id))
      }
    }
  }
}

/// Money's goals card, beside money in the game: a chip per active goal, or how to start one.
struct GoalsCard: View {
  let snapshot: SavingsSnapshot

  var body: some View {
    MoneyCard(Text("Goals", tableName: "Money")) {
      NavigationLink(value: MemoirRoute.money(.goals)) { Text("Manage", tableName: "Money") }
    } content: {
      if snapshot.active.isEmpty {
        MoneyProse(Text("Name something to save towards, and what your budgets leave unspent fills it month by month.", tableName: "Money"))
        if snapshot.canAddGoal {
          NavigationLink(value: MemoirRoute.money(.newGoal)) { Text("Add a goal", tableName: "Money") }.buttonStyle(.shadowBordered)
        }
      } else {
        GoalChips(snapshot: snapshot)
      }
    }
  }
}

/// Saved under budget: the tally, what can be drawn, what it is waiting on, the pace, this month as it is going, and the last months' deposits.
struct SavingsCard: View {
  static let historyMonths = 6

  let snapshot: SavingsSnapshot
  @Environment(\.locale) private var locale

  var body: some View {
    let overview = snapshot.overview
    let balance = overview.balance
    MoneyCard(Text(verbatim: SavingsCopy.title)) {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text(verbatim: MoneyText.formatted(balance.balanceMinor, balance.home, locale: locale))
            .shadowFont(.title2).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
          if case .repaying(let owed) = balance.standing {
            Label {
              Text(verbatim: SavingsCopy.repaying(owed, home: balance.home, locale: locale))
            } icon: {
              Image(systemName: "arrow.uturn.backward.circle")
            }
            .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
          }
          Text(verbatim: SavingsCopy.available(balance, locale: locale)).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        MoneyProse(Text(verbatim: SavingsCopy.explanation))
        ForEach(SavingsCopy.notes(balance), id: \.self) { note in
          Text(verbatim: note).shadowFont(.caption).foregroundStyle(ShadowColor.warningText).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        Text(verbatim: SavingsCopy.pace(overview.pace, home: overview.home, locale: locale)).shadowFont(.subheadline)
        if let live = overview.liveMonth {
          VStack(alignment: .leading, spacing: Spacing.space05) {
            Text(verbatim: SavingsCopy.liveMonth(live, home: overview.home, locale: locale)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            if let pending = SavingsCopy.liveMonthPending(live) {
              Text(verbatim: pending).shadowFont(.caption).foregroundStyle(ShadowColor.warningText)
            }
          }
        }
        if !overview.history.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            ForEach(overview.history.suffix(Self.historyMonths).reversed(), id: \.month) { month in
              let row = SavingsCopy.month(month, home: overview.home, locale: locale)
              HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.title).shadowFont(.subheadline)
                Spacer()
                Text(verbatim: row.amount).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
              }
              .accessibilityElement(children: .combine)
            }
          }
        }
        Text(verbatim: SavingsCopy.borrowing(balance, locale: locale)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
