import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// memoir-web `ExpensesScreen` (`features/finance/expenses-screen.tsx`): the range's spending, this month's budget, the subscriptions' monthly cost and
/// the average day, the expense list, where the money went, and the subscriptions and currencies rails.
struct MoneyView: View {
  @State private var model: MoneyModel
  @Environment(\.locale) private var locale

  init(context: MemoirScreenContext) {
    _model = State(initialValue: MoneyModel(context: context))
  }

  var body: some View {
    @Bindable var list = model.list
    MoneyLoadState(model.overview.state) { overview in
      if let overview {
        MoneyOverviewContent(model: model, overview: overview)
      } else {
        MoneyNoCurrency()
      }
    }
    .navigationTitle(Text(MemoirDestination.money.title))
    .navigationSubtitle(subtitle)
    .searchable(text: $list.search, prompt: Text("Search notes and merchants", tableName: "Money"))
    .toolbar {
      ToolbarItem {
        NavigationLink(value: MemoirRoute.money(.newExpense)) {
          Label(title: { Text("Add expense", tableName: "Money") }, icon: { Image(systemName: "plus") })
        }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(model.overview.state.value == .some(nil))
        .shadowBarItem()
      }
    }
    .shadowScreen(.root)
    .task { await model.run() }
  }

  /// memoir-web `headerMeta`: the range and what it spent, against the budget in the month view.
  private var subtitle: Text {
    guard let overview = model.overview.state.value ?? nil else { return Text(verbatim: "") }
    let spend = overview.spend(model.range)
    let spent = MoneyText.formatted(spend.spent.totalMinor, overview.home, locale: locale)
    let period = MoneyLabels.periodTitle(model.range)
    guard model.range == .month, let budget = overview.budget else { return Text("\(period) · \(spent)", tableName: "Money") }
    return Text("\(period) · \(spent) of \(MoneyText.formatted(budget.budget, locale: locale))", tableName: "Money")
  }
}

/// Before the vault has settings there is no home currency to total in.
private struct MoneyNoCurrency: View {
  var body: some View {
    ShadowContentUnavailable(
      Text("No base currency yet", tableName: "Money"), systemImage: "banknote",
      message: Text("Money totals are kept in your base currency. Choose it in Settings, under Day and money.", tableName: "Money")
    ) {
      NavigationLink(value: MemoirRoute.destination(.settings)) { Text("Open Settings", tableName: "Money") }
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct MoneyOverviewContent: View {
  let model: MoneyModel
  let overview: MoneyOverview
  @Environment(\.locale) private var locale

  var body: some View {
    let spend = overview.spend(model.range)
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let note = MoneyNotes.pending(spend.spent.pending) {
          ShadowCallout(Text(verbatim: note), intent: .warning, systemImage: "clock.badge.questionmark")
        }
        if overview.unreadable > 0 {
          ShadowCallout(
            Text("Some money records can’t be read", tableName: "Money"),
            message: Text("They were written by a newer version of Memoir. Update the app to see them.", tableName: "Money"), intent: .warning)
        }
        ShadowStatisticGrid {
          ShadowStatistic(
            Text(verbatim: MoneyLabels.spentTitle(model.range)), value: money(spend.spent.totalMinor), caption: Text(verbatim: MoneyLabels.comparison(spend)))
          budgetStatistic(spend)
          ShadowStatistic(
            Text("Subscriptions a month", tableName: "Money"), value: money(overview.subscriptions.monthlyMinor),
            caption: Text(verbatim: MoneyNotes.subscriptions(overview, name: model.subscriptionName, locale: locale)))
          ShadowStatistic(Text("Average day", tableName: "Money"), value: money(spend.averagePerDayMinor), caption: Text(verbatim: MoneyNotes.daysLogged(spend.daysLogged)))
        }
        ShadowAdaptiveColumns {
          ExpensesCard(list: model.list, home: overview.home)
          BreakdownCard(spend: spend, home: overview.home)
          SubscriptionsRail(overview: overview)
          if spend.currencies.contains(where: { $0.currency != overview.home }) { CurrenciesRail(spend: spend, home: overview.home) }
        }
      }
      .padding(Spacing.space4)
    }
  }

  private func money(_ minor: Int64) -> Text {
    Text(verbatim: MoneyText.formatted(minor, overview.home, locale: locale)).monospacedDigit()
  }

  /// memoir-web `BudgetKpi`: what is left of the month's budget, or how far over it the month is, whichever range is shown.
  @ViewBuilder
  private func budgetStatistic(_ spend: RangeSpend) -> some View {
    if let budget = overview.budget {
      let over = budget.leftMinor < 0
      let monthly = model.range == .month
      let label: Text =
        switch (over, monthly) {
        case (true, true): Text("Over budget", tableName: "Money")
        case (true, false): Text("Over this month’s budget", tableName: "Money")
        case (false, true): Text("Left of budget", tableName: "Money")
        case (false, false): Text("Left of this month’s budget", tableName: "Money")
        }
      ShadowStatistic(label, value: money(budget.leftMinor == .min ? .max : abs(budget.leftMinor)), caption: Text(verbatim: budgetNote(budget, monthly: monthly)))
    } else {
      ShadowStatistic(
        Text("Monthly budget", tableName: "Money"), value: Text("No monthly budget", tableName: "Money"),
        caption: Text("Set a budget in Settings, under Day and money.", tableName: "Money"))
    }
  }

  private func budgetNote(_ budget: BudgetStanding, monthly: Bool) -> String {
    let days = MoneyNotes.daysLeft(budget.daysLeft)
    let pending = MoneyNotes.leftOut(awaitingRate: budget.spend.awaitingRate, unconvertible: budget.spend.unconvertible)
    guard monthly else { return ([String(localized: "Budget is monthly", table: "Money"), days] + pending).joined(separator: " · ") }
    let spent = MoneyText.formatted(budget.spend.spentMinor, overview.home, locale: locale)
    let of = String(localized: "\(spent) of \(MoneyText.formatted(budget.budget, locale: locale))", table: "Money")
    return ([of, days] + pending).joined(separator: " · ")
  }
}

/// The range's expenses, the first page of them, with the range control and the category filter.
private struct ExpensesCard: View {
  @Bindable var list: ExpenseListModel
  let home: CurrencyCode
  @Environment(\.locale) private var locale

  var body: some View {
    MoneyCard(Text("Expenses", tableName: "Money")) {
      Picker(selection: $list.range) {
        ForEach(FinanceRange.allCases, id: \.self) { range in Text(verbatim: MoneyLabels.rangeTitle(range)).tag(range) }
      } label: {
        Text("Range", tableName: "Money")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    } content: {
      if let category = list.category {
        ShadowTag(Text(verbatim: MoneyLabels.categoryName(category)), removeLabel: Text("Remove the category filter", tableName: "Money")) { list.category = nil }
      }
      MoneyLoadState(list.listing.state) { listing in
        ExpenseRows(listing: listing, list: list, locale: locale)
      }
      .frame(minHeight: Spacing.space10)
    }
  }
}

/// The rows of a listing and what to say when it is empty, shared by the Money screen and the full list.
struct ExpenseRows: View {
  let listing: ExpenseListing
  let list: ExpenseListModel
  let locale: Locale

  var body: some View {
    if listing.rows.items.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text(verbatim: emptyTitle).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        MoneyProse(emptyMessage)
        NavigationLink(value: MemoirRoute.money(.newExpense)) { Text("Add expense", tableName: "Money") }
      }
    } else {
      VStack(spacing: 0) {
        ForEach(listing.rows.items, id: \.expense.id) { row in
          NavigationLink(value: MemoirRoute.money(.expense(row.expense.id))) {
            ExpenseRowView(content: ExpenseRowContent(row, home: listing.home, categoryName: { MoneyLabels.categoryName($0) }, locale: locale))
          }
          .buttonStyle(.plain)
        }
      }
      HStack {
        Text("Showing \(listing.rows.items.count) of \(listing.rows.total)", tableName: "Money")
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        Spacer()
        if listing.rows.hasMore {
          if list.limit <= ExpenseListModel.overviewPageSize {
            NavigationLink(value: MemoirRoute.money(.expenses(list.scope))) { Text("Show all", tableName: "Money") }
          } else {
            Button {
              list.showMore()
            } label: {
              Text("Show more", tableName: "Money")
            }
          }
        }
      }
    }
  }

  private var emptyTitle: String {
    if !list.search.isEmpty { return String(localized: "Nothing matches “\(list.search)”", table: "Money") }
    if let category = list.category { return String(localized: "No \(MoneyLabels.categoryName(category)) expenses in this range", table: "Money") }
    return String(localized: "No expenses in this range", table: "Money")
  }

  private var emptyMessage: Text {
    list.search.isEmpty
      ? Text("Add one when you spend something. Ten seconds is the whole cost.", tableName: "Money")
      : Text("Try a shorter word, or widen the range.", tableName: "Money")
  }
}

/// memoir-web "Where it went": each category's share against the largest; a category opens its expenses.
private struct BreakdownCard: View {
  let spend: RangeSpend
  let home: CurrencyCode
  @Environment(\.locale) private var locale

  var body: some View {
    MoneyCard(Text("Where it went", tableName: "Money")) {
      NavigationLink(value: MemoirRoute.money(.categories)) { Text("Manage categories", tableName: "Money") }
    } content: {
      if spend.categories.isEmpty {
        MoneyProse(Text("Nothing logged in this range yet.", tableName: "Money"))
      }
      ForEach(spend.categories, id: \.category) { slice in
        NavigationLink(value: MemoirRoute.money(.expenses(ExpenseListScope(range: spend.range, category: slice.category)))) {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: "\(MoneyLabels.categoryName(slice.category)) · \(slice.count.formatted())").shadowFont(.subheadline)
              Spacer()
              Text(verbatim: MoneyText.formatted(slice.totalMinor, home, locale: locale)).shadowFont(.subheadline).monospacedDigit()
            }
            let pending = MoneyNotes.leftOut(slice.pending)
            if !pending.isEmpty {
              Text(verbatim: pending.joined(separator: " · ")).shadowFont(.caption).foregroundStyle(ShadowColor.warningText)
            }
            ProgressView(value: Double(slice.totalMinor > 0 ? max(slice.percentOfLargest, 2) : 0), total: 100).progressViewStyle(.shadowLinear)
              .accessibilityHidden(true)
          }
          .foregroundStyle(ShadowColor.textPrimary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

private struct SubscriptionsRail: View {
  let overview: MoneyOverview
  @Environment(\.locale) private var locale

  var body: some View {
    MoneyCard(Text("Subscriptions", tableName: "Money")) {
      NavigationLink(value: MemoirRoute.money(.subscriptions)) { Text("All \(overview.subscriptions.activeCount)", tableName: "Money") }
    } content: {
      let monthly = MoneyText.formatted(overview.subscriptions.monthlyMinor, overview.home, locale: locale)
      MoneyProse(
        Text(
          "\(monthly) a month across everything active. Nothing is ever charged for you — each cycle waits for your confirmation.", tableName: "Money"))
    }
  }
}

/// memoir-web "Multi-currency": each foreign currency's spending as typed, and what of it converted home or still waits for a rate.
private struct CurrenciesRail: View {
  let spend: RangeSpend
  let home: CurrencyCode
  @Environment(\.locale) private var locale

  var body: some View {
    MoneyCard(Text("Multi-currency", tableName: "Money")) {
      MoneyProse(
        Text(
          "Your base currency is \(home.code). Foreign spend is stored in the original currency and converted at the rate on the day — the original is never overwritten.",
          tableName: "Money"))
      ForEach(spend.currencies.filter { $0.currency != home }, id: \.currency) { total in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: total.currency.code).shadowFont(.subheadline)
          Spacer()
          VStack(alignment: .trailing, spacing: Spacing.space05) {
            Text(verbatim: MoneyText.formatted(total.totalMinor, total.currency, locale: locale)).shadowFont(.subheadline).monospacedDigit()
            Text(verbatim: MoneyNotes.converted(total, locale: locale)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// The Money screens' sentences that count things, with their plurals in `Money.xcstrings`.
enum MoneyNotes {
  /// Decision 7: what the totals leave out instead of adding it as nothing.
  static func pending(_ pending: PendingConversions) -> String? {
    var parts = [String]()
    if pending.awaitingRate > 0 {
      parts.append(String(localized: "\(pending.awaitingRate) expenses wait for an exchange rate and are left out of these totals.", table: "Money"))
    }
    if pending.unconvertible > 0 {
      parts.append(String(localized: "\(pending.unconvertible) expenses can’t be converted and are left out of these totals.", table: "Money"))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  static func daysLogged(_ days: Int) -> String {
    String(localized: "\(days) days logged", table: "Money")
  }

  static func daysLeft(_ days: Int) -> String {
    String(localized: "\(days) days left in the month", table: "Money")
  }

  static func converted(_ total: CurrencyTotal, locale: Locale) -> String {
    var parts = [String]()
    if total.home.pending.count < total.count {
      parts.append(String(localized: "≈ \(MoneyText.formatted(total.home.totalMinor, total.home.home, locale: locale))", table: "Money"))
    }
    return (parts + leftOut(total.home.pending)).joined(separator: " · ")
  }

  /// Short counts of what a sum left out, for a caption.
  static func leftOut(_ pending: PendingConversions) -> [String] {
    leftOut(awaitingRate: pending.awaitingRate, unconvertible: pending.unconvertible)
  }

  static func leftOut(awaitingRate: Int, unconvertible: Int) -> [String] {
    var parts = [String]()
    if awaitingRate > 0 { parts.append(String(localized: "\(awaitingRate) rate pending", table: "Money")) }
    if unconvertible > 0 { parts.append(String(localized: "\(unconvertible) can’t be converted", table: "Money")) }
    return parts
  }

  /// memoir-web `unconvertedSubscriptionsNote`.
  static func unconvertedSubscriptions(_ pending: PendingConversions) -> String? {
    guard pending.count > 0 else { return nil }
    let currencies = pending.currencies.map(\.code).joined(separator: "/")
    guard !currencies.isEmpty else { return String(localized: "\(pending.count) not converted", table: "Money") }
    return String(localized: "\(pending.count) not converted — no \(currencies) rate yet", table: "Money")
  }

  /// memoir-web `subscriptionsKpiNote`.
  static func subscriptions(_ overview: MoneyOverview, name: (UUID) -> String?, locale: Locale) -> String {
    let active = String(localized: "\(overview.subscriptions.activeCount) active", table: "Money")
    if let unconverted = unconvertedSubscriptions(overview.subscriptions.pending) { return [active, unconverted].joined(separator: " · ") }
    switch overview.highlight {
    case nil:
      return active
    case .next(let id, let due):
      let day = MoneyDates.text(due, locale: locale, showsYear: false)
      guard let name = name(id) else { return [active, String(localized: "next on \(day)", table: "Money")].joined(separator: " · ") }
      return [active, String(localized: "next \(name) on \(day)", table: "Money")].joined(separator: " · ")
    case .overdue(_, _, let count) where count > 1:
      return [active, String(localized: "\(count) charges waiting to be confirmed", table: "Money")].joined(separator: " · ")
    case .overdue(let id, let due, _):
      let day = MoneyDates.text(due, locale: locale, showsYear: false)
      let subject = name(id) ?? String(localized: "A subscription", table: "Money")
      return [active, String(localized: "\(subject) was due \(day)", table: "Money")].joined(separator: " · ")
    }
  }
}
