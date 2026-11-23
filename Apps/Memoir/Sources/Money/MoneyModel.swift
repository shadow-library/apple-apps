import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// Which expenses a list shows: a range of the account's day, a search on note and merchant, and a category.
nonisolated struct ExpenseListScope: Hashable, Sendable {
  var range: FinanceRange = .month
  var search = ""
  var category: CategoryKey?
}

/// The expenses of one range of the account's day, searched on note and merchant and filtered to a category, newest first and paged.
@MainActor
@Observable
final class ExpenseListModel {
  static let overviewPageSize = 8
  static let pageSize = 50
  static let searchDelay: Duration = .milliseconds(250)

  let listing = MoneyFeed<ExpenseListing>()
  var range: FinanceRange {
    didSet { if range != oldValue { restart() } }
  }
  var search = "" {
    didSet { if search != oldValue { restartAfterTyping() } }
  }
  var category: CategoryKey? {
    didSet { if category != oldValue { restart() } }
  }
  private(set) var limit: Int
  private(set) var today: LocalDate?
  @ObservationIgnored let context: MemoirScreenContext
  @ObservationIgnored private let pageSize: Int
  @ObservationIgnored private var typing: Task<Void, Never>?

  init(context: MemoirScreenContext, scope: ExpenseListScope = ExpenseListScope(), pageSize: Int = ExpenseListModel.pageSize) {
    self.context = context
    range = scope.range
    search = scope.search
    category = scope.category
    self.pageSize = pageSize
    limit = pageSize
  }

  var scope: ExpenseListScope { ExpenseListScope(range: range, search: search, category: category) }

  var query: ExpenseQuery? {
    guard let today, let span = range.period(containing: today), let page = try? PageRequest(offset: 0, limit: limit) else { return nil }
    return ExpenseQuery(span: span, search: search, category: category, page: page)
  }

  func showMore() {
    limit += pageSize
    restart(resettingLimit: false)
  }

  func follow(today: LocalDate) {
    guard today != self.today else { return }
    self.today = today
    restart(resettingLimit: false)
  }

  /// Follows the account's day on its own, for a screen that shows only the list.
  func run() async {
    defer { stop() }
    do {
      for try await today in context.observeToday() { follow(today: today.date) }
    } catch {
      listing.fail(error)
    }
  }

  func stop() {
    typing?.cancel()
    listing.stop()
  }

  /// Waits for a pause in typing before reading again.
  private func restartAfterTyping() {
    typing?.cancel()
    typing = Task { [weak self] in
      try? await Task.sleep(for: Self.searchDelay)
      guard !Task.isCancelled else { return }
      self?.restart()
    }
  }

  private func restart(resettingLimit: Bool = true) {
    if resettingLimit { limit = pageSize }
    guard let query else { return }
    let stores = context.stores
    listing.follow { MoneyReads.observeExpenses(in: stores, matching: query) }
  }
}

/// The Money screen: the three ranges' spending, this month's budget, the subscriptions' monthly cost and the expense list, all for the account's day.
@MainActor
@Observable
final class MoneyModel {
  let overview = MoneyFeed<MoneyOverview?>()
  let subscriptions = MoneyFeed<SubscriptionsOverview?>()
  let list: ExpenseListModel
  @ObservationIgnored let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
    list = ExpenseListModel(context: context, pageSize: ExpenseListModel.overviewPageSize)
  }

  var range: FinanceRange {
    get { list.range }
    set { list.range = newValue }
  }

  func run() async {
    defer {
      overview.stop()
      subscriptions.stop()
      list.stop()
    }
    var followed: LocalDate?
    do {
      for try await today in context.observeToday() where today.date != followed {
        followed = today.date
        let stores = context.stores
        let date = today.date
        overview.follow { MoneyReads.observeOverview(in: stores, today: date) }
        subscriptions.follow { MoneyReads.observeSubscriptions(in: stores, today: date) }
        list.follow(today: date)
      }
    } catch {
      overview.fail(error)
    }
  }

  func subscriptionName(_ id: UUID) -> String? {
    subscriptions.state.value??.items.first { $0.subscription.id == id }?.subscription.name
  }
}
