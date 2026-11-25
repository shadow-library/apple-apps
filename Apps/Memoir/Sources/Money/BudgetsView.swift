import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Every budget with its current period: Home, the monthly budgets in other currencies and the trips, before, during and after them.
struct BudgetsView: View {
  @State private var model: BudgetsModel
  @Environment(\.locale) private var locale

  init(context: MemoirScreenContext) {
    _model = State(initialValue: BudgetsModel(context: context))
  }

  var body: some View {
    MoneyLoadState(model.standings.state) { standings in
      if let standings {
        content(standings)
      } else {
        ShadowContentUnavailable(
          Text("No base currency yet", tableName: "Money"), systemImage: "chart.pie",
          message: Text("Money totals are kept in your base currency. Choose it in Settings, under Day and money.", tableName: "Money"))
      }
    }
    .navigationTitle(Text("Budgets", tableName: "Money"))
    .toolbar {
      ToolbarItem {
        NavigationLink(value: MemoirRoute.money(.newBudget)) {
          Label(title: { Text("Add budget", tableName: "Money") }, icon: { Image(systemName: "plus") })
        }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(model.standings.state.value == .some(nil))
        .shadowBarItem()
      }
    }
    .shadowScreen(.pushed)
    .task { await model.run() }
  }

  private func content(_ standings: BudgetStandings) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let failure = model.failure {
          ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .danger)
        }
        if standings.unreadableBudgets > 0 {
          ShadowCallout(
            Text("Some budgets can’t be read", tableName: "Money"),
            message: Text("They were written by a newer version of Memoir. Update the app to see them.", tableName: "Money"), intent: .warning)
        }
        if let currency = model.homeCurrencyDiffers {
          ShadowCallout(
            Text("Home counts in \(currency.code)", tableName: "Money"),
            message: Text(
              "Home kept the currency it was first set up in on another device, so its limit and spending are in \(currency.code), not \(standings.home.code).",
              tableName: "Money"),
            intent: .neutral, systemImage: "info.circle")
        }
        ShadowAdaptiveColumns {
          MoneyCard(Text("Your budgets", tableName: "Money")) {
            ForEach(standings.budgets) { standing in
              BudgetLink(content: BudgetRowContent(standing, locale: locale), isHome: standing.budget.isHome) { await model.delete(standing.id) }
                .disabled(model.working.contains(standing.id))
            }
          }
          if standings.offersConsolidated {
            MoneyCard(Text("Added up", tableName: "Money")) {
              ConsolidatedView(content: ConsolidatedContent(standings.consolidated, locale: locale))
            }
          }
          MoneyCard(Text("Where an expense counts", tableName: "Money")) {
            MoneyProse(
              Text(
                "An expense counts in the budget you choose for it. Otherwise it counts in a trip whose dates cover it, then in the monthly budget of its currency, and then in Home, converted.",
                tableName: "Money"))
          }
        }
      }
      .padding(Spacing.space4)
    }
  }
}

/// A budget's row, opening its form; every budget but Home can be deleted from its menu.
private struct BudgetLink: View {
  let content: BudgetRowContent
  let isHome: Bool
  let delete: () async -> Bool
  @State private var isConfirmingDelete = false

  var body: some View {
    NavigationLink(value: MemoirRoute.money(.budget(content.id))) {
      BudgetRowView(content: content).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      if !isHome {
        Button(role: .destructive) {
          isConfirmingDelete = true
        } label: {
          Label(title: { Text("Delete budget", tableName: "Money") }, icon: { Image(systemName: "trash") })
        }
      }
    }
    .confirmationDialog(Text("Delete this budget?", tableName: "Money"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { _ = await delete() }
      } label: {
        Text("Delete budget", tableName: "Money")
      }
      .shadowDestructiveDialogAction()
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Money")
      }.shadowDialogCancelAction()
    } message: {
      Text("Its expenses go back to counting in Home or the monthly budget of their currency, months not yet closed included.", tableName: "Money")
    }
  }
}

/// One budget: its name and pace, what it spent against its limit, and how far along it is.
struct BudgetRowView: View {
  let content: BudgetRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
          heading
          Spacer(minLength: Spacing.space2)
          badge
        }
        VStack(alignment: .leading, spacing: Spacing.space1) {
          heading
          badge
        }
      }
      Text(verbatim: content.amount).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
      if let progress = content.progress {
        ProgressView(value: progress).progressViewStyle(.shadowLinear)
      }
      if !content.details.isEmpty {
        Text(verbatim: content.details.joined(separator: " · ")).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, Spacing.space2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: content.accessibilityLabel))
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      Text(verbatim: content.title).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: content.kind).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private var badge: some View {
    ShadowBadge(Text(verbatim: content.status), intent: content.tone.badgeIntent, systemImage: content.tone.symbol)
  }
}

/// The budgets under way added up in the home currency, said to be approximate when anything converts.
struct ConsolidatedView: View {
  let content: ConsolidatedContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: content.title).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: content.amount).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
      if let left = content.left {
        Label {
          Text(verbatim: left).monospacedDigit()
        } icon: {
          if let symbol = content.tone.symbol { Image(systemName: symbol) }
        }
        .shadowFont(.subheadline)
        .foregroundStyle(content.tone == .danger ? ShadowColor.dangerText : ShadowColor.textSecondary)
      }
      ForEach(content.notes, id: \.self) { note in
        Text(verbatim: note).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension BudgetTone {
  var badgeIntent: ShadowBadgeIntent {
    switch self {
    case .neutral: .neutral
    case .success: .success
    case .warning: .warning
    case .danger: .danger
    }
  }
}
