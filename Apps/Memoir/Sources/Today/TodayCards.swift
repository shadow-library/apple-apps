import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct TodayNoticeView: View {
  let notice: TodayNotice

  var body: some View {
    switch notice {
    case .unknownZone(let identifier, let offset):
      ShadowCallout(
        Text("This device doesn’t know the time zone \(identifier).", tableName: "Today"),
        message: offset.map {
          Text(
            "Memoir keeps counting the account’s days at UTC\(TodayFormat.offset(minutes: $0)), the last offset recorded for it, until this device’s time zone data is updated.",
            tableName: "Today")
        }
          ?? Text("Memoir counts the account’s days in this device’s time zone until its time zone data is updated.", tableName: "Today"),
        intent: .neutral, systemImage: "globe")
    case .needsAppUpdate:
      ShadowCallout(
        Text("Update Memoir", tableName: "Today"),
        message: Text("Another device recorded something this version can’t read. Your hero is shown as it was before it until Memoir is updated.", tableName: "Today"),
        intent: .warning, systemImage: "arrow.down.app")
    case .purchaseWithdrawn(let balance, let price):
      ShadowCallout(
        Text("A purchase was withdrawn", tableName: "Today"),
        message: Text(
          "Merging another device’s changes left \(balance) coins for an item costing \(price), so the purchase was undone and nothing was charged.", tableName: "Today"),
        intent: .info)
    }
  }
}

/// `COMING_BACK_NOTICES` (`lib/data/labels.ts:13-22`): Today frames a Returner day or a Recovery quest (`features/today/index.tsx:96-111`); a Comeback is
/// the Hero screen's to explain.
struct TodayComingBack: View {
  let reason: ComingBackReason

  var body: some View {
    ShadowCallout(title, message: message, intent: .info, systemImage: "arrow.uturn.left.circle") {
      HStack(spacing: Spacing.space2) {
        ModuleLink(MemoirRoute.hero(.comingBack)) { Text("See recovery choices", tableName: "Today") }.buttonStyle(.shadowBordered)
        ModuleLink(MemoirRoute.destination(.planningBoard)) { Text("See the week", tableName: "Today") }.buttonStyle(.shadowPlain)
      }
    }
  }

  private var title: Text {
    reason == .returner ? Text("Welcome back", tableName: "Today") : Text("A recovery quest is on today", tableName: "Today")
  }

  private var message: Text {
    reason == .returner
      ? Text(
        "You have been away for a while. Your experience, levels and titles are untouched, and streaks that closed while you were gone keep their records in History.",
        tableName: "Today")
      : Text(
        "A quest was missed yesterday, so today also offers a lighter recovery quest you can keep before the day closes. Nothing you have earned was taken away.",
        tableName: "Today")
  }
}

/// The day's Recovery quest: kept by `recovery.complete` only while it is pending on the account's open day.
struct TodayRecoveryCard: View {
  let offer: RecoveryOffer
  let zone: TimeZone
  let isBusy: Bool
  let keep: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline) {
        Text("Recovery quest", tableName: "Today").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        Spacer(minLength: Spacing.space2)
        state
      }
      Group {
        if let name = offer.sourceName {
          Text("Offered after \(name) was missed. It never costs HP and keeps no streak.", tableName: "Today")
        } else {
          Text("Offered after a missed quest. It never costs HP and keeps no streak.", tableName: "Today")
        }
      }
      .todayNote()
      if offer.state == .pending, let expires = offer.expiresAtMillis {
        Text("Open until \(TodayFormat.time(millis: expires, in: zone))", tableName: "Today").todayNote()
      }
      if offer.state == .pending {
        if case .unavailable(let block) = offer.complete {
          Text(verbatim: QuestActionCopy.blocked(block, for: .complete)).todayNote()
        } else {
          Button(action: keep) { Text("Keep the recovery quest", tableName: "Today") }
            .buttonStyle(.shadowFilled)
            .disabled(isBusy)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }

  @ViewBuilder
  private var state: some View {
    switch offer.state {
    case .pending: EmptyView()
    case .completed: ShadowBadge(Text("Kept", tableName: "Today"), intent: .success)
    case .expired: ShadowBadge(Text("Closed unkept", tableName: "Today"))
    }
  }
}

struct TodayRecoverySheet: View {
  let model: TodayViewModel
  let finished: (QuestActionOutcome) -> Void
  @State private var reflection = ""
  @State private var problem: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      Text("It is judged on the day rather than the hour, and keeping it earns its own reward.", tableName: "Today").todayNote()
      ShadowTextEditor(text: $reflection, placeholder: Text("A line about how it went (optional)", tableName: "Today"), minHeight: 56, maxHeight: 160) { count in
        Text("\(count.count) characters", tableName: "Today")
      }
      .accessibilityLabel(Text("Reflection", tableName: "Today"))
      if let problem { ShadowCallout(Text(verbatim: problem), intent: .danger) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.space4)
    .shadowFittedDetents()
    .shadowSheetStyle(.form)
    .shadowSheetHeader(
      Text("Keep the recovery quest", tableName: "Today"), cancel: ShadowSheetCancel(Text("Cancel", tableName: "Today")) { dismiss() },
      confirm: ShadowSheetConfirm(Text("Mark kept", tableName: "Today"), isDisabled: model.actions.isCompletingRecovery, submitShortcut: true) { keep() })
  }

  private func keep() {
    problem = nil
    Task {
      let outcome = await model.completeRecovery(reflection: reflection)
      switch outcome {
      case .done:
        finished(outcome)
        dismiss()
      case .failed(let error): problem = String(localized: "Couldn’t save the recovery quest: \(error.headline)", table: "Today")
      case .unavailable(let reason): problem = QuestActionCopy.unavailable(reason, for: .complete)
      case .cancelled: break
      }
    }
  }
}

/// `NothingDueToday` (`features/today/index.tsx:36-55`).
struct TodayNothingDue: View {
  let next: NextOccurrence?
  let today: LocalDate

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Nothing is due today", tableName: "Today").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Group {
        if let next {
          Text("\(next.name ?? String(localized: "Unnamed quest", table: "Today")) is next · \(TodayFormat.nextDay(next.date, from: today)).", tableName: "Today")
        } else {
          Text("None of your active quests is scheduled again in the next year.", tableName: "Today")
        }
      }
      .todayNote()
      ModuleLink(MemoirRoute.destination(.planningBoard)) { Text("See the week", tableName: "Today") }.buttonStyle(.shadowPlain)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }
}

/// The first day's empty state (`features/today/index.tsx:111-138`).
struct TodayFirstDay: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowContentUnavailable(
        Text("Your first day is empty on purpose", tableName: "Today"), systemImage: "sunrise",
        message: Text(
          "A quest is a promise you keep to yourself, not a task. Start with one that takes ten minutes — it is easier to keep a small promise every day than a large one twice.",
          tableName: "Today")
      ) {
        ModuleLink(MemoirRoute.quest(.new)) { Text("Create your first quest", tableName: "Today") }.buttonStyle(.shadowFilled)
      }
      .frame(maxWidth: .infinity)
      .shadowCard()
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text("While you decide, anything you log still counts", tableName: "Today").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        Text(
          "Expenses, meals, weight and journal entries all work before your first quest exists. Side quests earn XP on their own.", tableName: "Today"
        )
        .todayNote()
        ModuleLink(MemoirRoute.destination(.sideQuests)) { Text("Log a side quest", tableName: "Today") }.buttonStyle(.shadowPlain)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .shadowCard()
    }
  }
}

/// `daySummary` (`fixture-provider.ts:296-312`) with the actions under it (`features/today/index.tsx:162-179`).
struct TodayDayEndCard: View {
  let end: TodayDayEnd

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("End of day", tableName: "Today").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: detail).todayNote()
      HStack(spacing: Spacing.space2) {
        ModuleLink(MemoirRoute.destination(.journal)) { Text("Write a line about today", tableName: "Today") }.buttonStyle(.shadowBordered)
        ModuleLink(MemoirRoute.destination(.planningBoard)) { Text("Plan tomorrow", tableName: "Today") }.buttonStyle(.shadowPlain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }

  private var detail: String {
    let completed =
      end.partial > 0
      ? String(localized: "\(end.kept) of \(end.scheduled) quests completed, \(end.partial) partial.", table: "Today")
      : String(localized: "\(end.kept) of \(end.scheduled) quests completed.", table: "Today")
    guard end.skipped > 0 else { return completed }
    return [completed, String(localized: "\(end.skipped) skipped.", table: "Today")].joined(separator: " ")
  }
}

/// Money in the game on Today: the closes not yet seen here, and "No spend" for the days the logging window still takes; nothing once neither is left.
struct TodayMoneyCards: View {
  let game: MoneyGameModel

  var body: some View {
    if !game.newCloses.isEmpty {
      MoneyCloseResults(model: game).frame(maxWidth: .infinity, alignment: .leading).shadowCard()
    }
    if let snapshot = game.snapshot, snapshot.offersNoSpend || game.problem != nil {
      NoSpendControl(model: game, snapshot: snapshot, showsCovered: false).frame(maxWidth: .infinity, alignment: .leading).shadowCard()
    }
  }
}
