import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// The Money screen's card for money in the game, which is the hero's only card while Quests is off: the money and saving streaks, this week's logging,
/// a debuff in force, the closes not yet seen here, and "No spend" for today and the earlier days the window still takes.
struct MoneyGameCard: View {
  let model: MoneyGameModel

  var body: some View {
    if let snapshot = model.snapshot {
      MoneyCard(Text("Money streak", tableName: "Money")) {
        EmptyView()
      } content: {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          MoneyGameStatus(snapshot: snapshot)
          if !model.newCloses.isEmpty {
            Divider()
            MoneyCloseResults(model: model)
          }
          Divider()
          NoSpendControl(model: model, snapshot: snapshot, showsCovered: true)
        }
      }
    }
  }
}

/// The streaks, this week's logging and the debuff; the streak waits for the first money activity.
struct MoneyGameStatus: View {
  let snapshot: MoneyGameSnapshot
  @Environment(\.locale) private var locale

  var body: some View {
    let standing = snapshot.standing
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if snapshot.hasActivity {
        Text(verbatim: MoneyGameCopy.streak(standing.weekStreak)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        if let week = standing.week { progress(week, text: MoneyGameCopy.week(week)) }
        if let settling = standing.settlingWeek { progress(settling, text: MoneyGameCopy.settling(settling)) }
        if standing.savingStreak > 0 { MoneyProse(Text(verbatim: MoneyGameCopy.savingStreak(standing.savingStreak))) }
      } else {
        MoneyProse(Text(verbatim: MoneyGameCopy.notStarted))
      }
      ShadowFlowLayout(spacing: Spacing.space2) {
        if let debuff = standing.debuff {
          ShadowBadge(Text(verbatim: MoneyGameCopy.debuff(debuff, locale: locale)), intent: .warning, systemImage: "arrow.down.circle")
        }
        if let home = snapshot.homeInDanger {
          let content = BudgetRowContent(home, locale: locale)
          ShadowBadge(Text(verbatim: MoneyGameCopy.home(home, locale: locale)), intent: content.tone.badgeIntent, systemImage: content.tone.symbol)
        }
      }
    }
  }

  private func progress(_ week: MoneyWeekProgress, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      ProgressView(value: Double(min(week.covered.count, week.required)), total: Double(max(week.required, 1))).progressViewStyle(.shadowLinear)
        .accessibilityHidden(true)
      Text(verbatim: text).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

/// The closes not yet seen on this device, newest first, until the owner says they have seen them.
struct MoneyCloseResults: View {
  let model: MoneyGameModel
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Budgets closed", tableName: "Money").shadowFont(.subheadline).fontWeight(.semibold).foregroundStyle(ShadowColor.textPrimary)
      ForEach(model.newCloses) { close in row(close) }
      Button {
        model.acknowledgeCloses()
      } label: {
        Text("Got it", tableName: "Money")
      }
      .buttonStyle(.shadowBordered)
    }
  }

  private func row(_ close: MoneyCloseSummary) -> some View {
    let good = MoneyGameCopy.isGood(close.outcome)
    let details = MoneyGameCopy.result(close.result, locale: locale) + [MoneyGameCopy.deposit(model.snapshot?.deposits[close.key], locale: locale)].compactMap(\.self)
    return HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
      Image(systemName: good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(good ? ShadowColor.successText : ShadowColor.warningText)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(verbatim: MoneyGameCopy.closeName(close)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        Text(verbatim: MoneyGameCopy.outcome(close.outcome, locale: locale)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        Text(verbatim: MoneyGameCopy.closePeriod(close, locale: locale)).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
        if !details.isEmpty {
          Text(verbatim: details.joined(separator: " · ")).shadowFont(.caption).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// "No spend" for the account's open day while the standing takes it, what covers that day once something does, and a chip for each earlier day of the
/// window nothing covers yet.
struct NoSpendControl: View {
  let model: MoneyGameModel
  let snapshot: MoneyGameSnapshot
  /// Whether to say what covers today once it is covered.
  let showsCovered: Bool
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if let today = snapshot.noSpendToday {
        Button {
          log(today.date)
        } label: {
          Label {
            Text(verbatim: MoneyGameCopy.noSpend(on: today.date, today: snapshot.today, locale: locale))
          } icon: {
            Image(systemName: "checkmark.circle")
          }
        }
        .buttonStyle(.shadowFilled)
        .disabled(model.logging != nil)
      } else if showsCovered, let covered = MoneyGameCopy.covered(snapshot.standing.today?.coverage) {
        Label {
          Text(verbatim: covered)
        } icon: {
          Image(systemName: "checkmark.circle.fill")
        }
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.successText)
      }
      if !snapshot.noSpendBackFill.isEmpty {
        ShadowFlowLayout(spacing: Spacing.space2) {
          ForEach(snapshot.noSpendBackFill) { day in
            Button {
              log(day.date)
            } label: {
              Text(verbatim: MoneyGameCopy.noSpend(on: day.date, today: snapshot.today, locale: locale))
            }
            .buttonStyle(.shadowBordered)
            .disabled(model.logging != nil)
          }
        }
      }
      if let problem = model.problem {
        Text(verbatim: problem).shadowFont(.caption).foregroundStyle(ShadowColor.dangerText)
      }
    }
  }

  private func log(_ date: LocalDate) {
    Task { await model.logNoSpend(on: date) }
  }
}

extension MoneyGameSnapshot {
  /// Whether "No spend" is offered for any day, today's included.
  var offersNoSpend: Bool { noSpendToday != nil || !noSpendBackFill.isEmpty }
}

#if DEBUG
  #Preview("Money game") {
    @Previewable @State var model: MoneyGameModel?
    ScrollView {
      if let model { MoneyGameCard(model: model).padding(Spacing.space4).task { await model.run() } }
    }
    .task { model = await MoneyGamePreviewData.model() }
    .shadowTheme()
  }
#endif
