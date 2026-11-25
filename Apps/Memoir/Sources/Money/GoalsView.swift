import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// The goals: the active ones in the order savings fill them, moved by dragging or from a row's menu, any active in another currency, and the bought
/// and set-aside ones below.
struct GoalsView: View {
  @State private var model: GoalsModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: GoalsModel(context: context))
  }

  var body: some View {
    MoneyLoadState(model.savings.snapshot.state) { snapshot in
      if let snapshot {
        GoalsList(model: model, snapshot: snapshot)
      } else {
        GoalsNoCurrency()
      }
    }
    .navigationTitle(Text("Goals", tableName: "Money"))
    .toolbar {
      ToolbarItem {
        NavigationLink(value: MemoirRoute.money(.newGoal)) {
          Label(title: { Text("Add goal", tableName: "Money") }, icon: { Image(systemName: "plus") })
        }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(!(model.savings.value?.canAddGoal ?? false))
        .shadowBarItem()
      }
    }
    .shadowScreen(.pushed)
    .task { await model.run() }
  }
}

struct GoalsNoCurrency: View {
  var body: some View {
    ShadowContentUnavailable(
      Text("No base currency yet", tableName: "Money"), systemImage: "star.circle",
      message: Text("Savings are kept in your base currency. Choose it in Settings, under Day and money.", tableName: "Money"))
  }
}

private struct GoalsList: View {
  let model: GoalsModel
  let snapshot: SavingsSnapshot
  @Environment(\.locale) private var locale

  var body: some View {
    List {
      if let failure = model.failure {
        Section { ShadowValidationMessage(failure.text) }
      } else if let notice = model.notice {
        Section { Text(verbatim: GoalCopy.notice(notice)).foregroundStyle(ShadowColor.successText) }
      }
      Section {
        if snapshot.active.isEmpty {
          Text("No goal is filling yet.", tableName: "Money").foregroundStyle(ShadowColor.textSecondary)
        }
        ForEach(Array(snapshot.active.enumerated()), id: \.element.id) { index, share in
          GoalRow(share: share, snapshot: snapshot)
            .contextMenu { moveActions(index) }
            .accessibilityActions { moveActions(index) }
            .disabled(model.working.contains(share.id))
        }
        .onMove { sources, destination in Task { await model.move(from: sources, to: destination) } }
      } header: {
        Text("Filling now", tableName: "Money")
      } footer: {
        Text(verbatim: GoalCopy.limit(SavingsRules.maximumActiveGoals))
      }
      if !snapshot.otherCurrencyActive.isEmpty {
        Section {
          ForEach(snapshot.otherCurrencyActive, id: \.id) { goal in
            SettledGoalRow(goal: goal, home: snapshot.home)
          }
        } header: {
          Text("In another currency", tableName: "Money")
        } footer: {
          Text(
            "Made in another currency while two devices disagreed on yours, so it doesn’t fill. It still counts as one of your goals; buy it or set it aside.",
            tableName: "Money")
        }
      }
      if !snapshot.settled.isEmpty {
        Section {
          ForEach(snapshot.settled, id: \.id) { goal in
            SettledGoalRow(goal: goal, home: snapshot.home)
          }
        } header: {
          Text("Done and set aside", tableName: "Money")
        }
      }
    }
  }

  @ViewBuilder
  private func moveActions(_ index: Int) -> some View {
    if index > 0 {
      Button {
        Task { await model.move(from: [index], to: index - 1) }
      } label: {
        Label(title: { Text("Fill sooner", tableName: "Money") }, icon: { Image(systemName: "arrow.up") })
      }
    }
    if index + 1 < snapshot.active.count {
      Button {
        Task { await model.move(from: [index], to: index + 2) }
      } label: {
        Label(title: { Text("Fill later", tableName: "Money") }, icon: { Image(systemName: "arrow.down") })
      }
    }
  }
}

/// An active goal: its ring, how much is saved and its forecast line, opening it.
private struct GoalRow: View {
  let share: GoalShare
  let snapshot: SavingsSnapshot
  @Environment(\.locale) private var locale

  var body: some View {
    let forecast = snapshot.overview.forecast(of: share.id)
    NavigationLink(value: MemoirRoute.money(.goal(share.id))) {
      HStack(alignment: .top, spacing: Spacing.space3) {
        GoalRing(symbol: share.goal.symbol, thousandths: share.progressThousandths)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text(verbatim: share.goal.name).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: "\(GoalCopy.saved(share, locale: locale)) · \(GoalCopy.amounts(share, locale: locale))")
            .shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
          if let forecast {
            Text(verbatim: snapshot.forecastLine(forecast, locale: locale)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.vertical, Spacing.space1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct SettledGoalRow: View {
  let goal: SavingsGoalRecord
  let home: CurrencyCode

  var body: some View {
    NavigationLink(value: MemoirRoute.money(.goal(goal.id))) {
      ShadowListRow(
        title: Text(verbatim: goal.name), subtitle: GoalCopy.state(goal, home: home).map { Text(verbatim: $0) }
      ) {
        ShadowSymbolTile(systemImage: goal.symbol, tint: .neutral)
      }
    }
  }
}

/// One goal: its ring, what it holds against its target, its forecast, whether it earns rewards, and buying it, setting it aside or deleting it.
struct GoalView: View {
  let id: UUID
  @State private var model: GoalsModel

  init(id: UUID, context: MemoirScreenContext) {
    self.id = id
    _model = State(initialValue: GoalsModel(context: context))
  }

  var body: some View {
    MoneyLoadState(model.savings.snapshot.state) { snapshot in
      if let snapshot, let goal = snapshot.goal(id) {
        GoalDetail(model: model, snapshot: snapshot, goal: goal)
      } else if snapshot == nil {
        GoalsNoCurrency()
      } else {
        ShadowContentUnavailable(
          Text("That goal is no longer here", tableName: "Money"), systemImage: "star.circle",
          message: Text("It may have been deleted on another device.", tableName: "Money"))
      }
    }
    .navigationTitle(Text(verbatim: model.savings.value?.goal(id)?.name ?? ""))
    .toolbar {
      if model.savings.value?.goal(id) != nil {
        ToolbarItem {
          NavigationLink(value: MemoirRoute.money(.editGoal(id))) { Text("Edit", tableName: "Money") }.shadowBarItem()
        }
      }
    }
    .shadowScreen(.pushed)
    .task { await model.run() }
  }
}

private struct GoalDetail: View {
  let model: GoalsModel
  let snapshot: SavingsSnapshot
  let goal: SavingsGoalRecord
  @State private var confirming: Confirmation?
  @Environment(\.locale) private var locale
  @Environment(\.dismiss) private var dismiss
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  private enum Confirmation: Identifiable {
    case abandon
    case delete

    var id: Self { self }
  }

  private var share: GoalShare? { snapshot.overview.allocation.share(of: goal.id) }
  private var forecast: GoalForecast? { snapshot.overview.forecast(of: goal.id) }
  private var isActive: Bool { goal.state == .known(.active) }
  private var isFilling: Bool { isActive && goal.currency == snapshot.home }
  private var showsRewards: Bool { modules?.selection.contains(.hero) ?? true }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let failure = model.failure {
          ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .danger)
        } else if let notice = model.notice {
          ShadowCallout(Text(verbatim: GoalCopy.notice(notice)), intent: .success)
        }
        ShadowAdaptiveColumns {
          MoneyCard(Text("Progress", tableName: "Money")) { progress }
          if let forecast {
            MoneyCard(Text("Forecast", tableName: "Money")) {
              MoneyProse(Text(verbatim: snapshot.forecastLine(forecast, locale: locale)))
              if let need = forecast.need, need.perMonthMinor > 0 {
                Text(verbatim: GoalCopy.need(need, home: snapshot.home, locale: locale)).shadowFont(.caption).monospacedDigit()
                  .foregroundStyle(ShadowColor.textSecondary)
              }
            }
          }
          if showsRewards, let eligibility = snapshot.overview.rewards[goal.id] {
            MoneyCard(Text("Rewards", tableName: "Money")) {
              MoneyProse(Text(verbatim: GoalCopy.eligibility(eligibility, home: snapshot.home, locale: locale)))
            }
          }
          actions
        }
      }
      .padding(Spacing.space4)
    }
    .disabled(model.working.contains(goal.id))
    .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { confirmation in
      Button(role: .destructive) {
        Task { await perform(confirmation) }
      } label: {
        confirmation == .abandon ? Text("Set aside", tableName: "Money") : Text("Delete goal", tableName: "Money")
      }
      .shadowDestructiveDialogAction()
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Money")
      }
      .shadowDialogCancelAction()
    } message: { confirmation in
      switch confirmation {
      case .abandon: Text("What it holds goes back to savings for the goals after it. You can’t pick it up again.", tableName: "Money")
      case .delete: Text("Expenses that bought it keep their savings part, which then counts as any other draw. Rewards it earned stay.", tableName: "Money")
      }
    }
  }

  @ViewBuilder
  private var progress: some View {
    HStack(alignment: .center, spacing: Spacing.space3) {
      GoalRing(symbol: goal.symbol, thousandths: share?.progressThousandths ?? 0)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        if let share, isFilling {
          Text(verbatim: GoalCopy.saved(share, locale: locale)).shadowFont(.headline).monospacedDigit()
          Text(verbatim: GoalCopy.amounts(share, locale: locale)).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
        } else {
          Text(verbatim: MoneyText.formatted(goal.targetMinor, goal.currency, locale: locale)).shadowFont(.headline).monospacedDigit()
        }
        if let state = GoalCopy.state(goal, home: snapshot.home) {
          ShadowBadge(Text(verbatim: state))
        }
      }
    }
    .accessibilityElement(children: .combine)
    if let share, isFilling, let held = GoalCopy.held(share, locale: locale) {
      Text(verbatim: held).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
    if let date = GoalCopy.targetDate(goal, locale: locale) {
      Text(verbatim: date).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  @ViewBuilder
  private var actions: some View {
    MoneyCard(Text("Buying it", tableName: "Money")) {
      if isActive {
        MoneyProse(
          Text(
            "When you buy it, add the purchase as an expense and pick this goal on it, paying what you like from savings; goal purchases needn’t be one-offs. Then mark it bought here.",
            tableName: "Money"))
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.space2) { buyingButtons }
          VStack(alignment: .leading, spacing: Spacing.space2) { buyingButtons }
        }
      }
      Button(role: .destructive) {
        confirming = .delete
      } label: {
        Text("Delete goal", tableName: "Money")
      }
      .buttonStyle(.shadowPlain)
    }
  }

  @ViewBuilder
  private var buyingButtons: some View {
    Button {
      Task { await model.markBought(goal.id) }
    } label: {
      Text("Mark as bought", tableName: "Money")
    }
    .buttonStyle(.shadowFilled)
    Button {
      confirming = .abandon
    } label: {
      Text("Set aside", tableName: "Money")
    }
    .buttonStyle(.shadowBordered)
  }

  private var isConfirming: Binding<Bool> {
    Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
  }

  private var confirmationTitle: Text {
    confirming == .delete ? Text("Delete this goal?", tableName: "Money") : Text("Set this goal aside?", tableName: "Money")
  }

  private func perform(_ confirmation: Confirmation) async {
    switch confirmation {
    case .abandon: await model.abandon(goal.id)
    case .delete: if await model.delete(goal.id) { dismiss() }
    }
  }
}
