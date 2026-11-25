import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// Savings and the goals they fill on the account's day, read in one transaction with the expenses a forecast names as what pushed a goal back and the
/// labels the owner gave the categories those and a lever name.
nonisolated struct SavingsSnapshot: Sendable, Equatable {
  let overview: SavingsOverview
  let causes: [UUID: ExpenseRecord]
  let labels: [CategoryKey: String]

  /// Nil before the vault has settings, which name the home currency.
  static func load(in transaction: ReadTransaction, clock: MemoirClock) throws -> SavingsSnapshot? {
    let today = try clock.today(in: try AccountZone.load(in: transaction)).date
    guard let overview = try SavingsOverview.make(try SavingsBook.load(from: transaction), today: today) else { return nil }
    var causes = [UUID: ExpenseRecord]()
    for case .pushedBack(_, let cause) in overview.forecasts.map(\.state) {
      if let expense = try ExpenseRecord.read(id: cause, in: transaction).entry?.record { causes[cause] = expense }
    }
    let named = Set(overview.forecasts.compactMap(\.lever?.category) + causes.values.map(\.category))
    var labels = [CategoryKey: String]()
    if !named.isEmpty {
      for record in try ExpenseCategoryRecord.listing(in: transaction).entries.map(\.record) where named.contains(record.categoryKey) {
        labels[record.categoryKey] = record.label
      }
    }
    return SavingsSnapshot(overview: overview, causes: causes, labels: labels)
  }

  var home: CurrencyCode { overview.home }
  var active: [GoalShare] { overview.allocation.active }

  /// Every goal not deleted: the active ones in fill order, then the bought and abandoned ones, then those in another currency.
  var goals: [SavingsGoalRecord] {
    overview.allocation.active.map(\.goal) + overview.allocation.settled.map(\.goal) + overview.allocation.otherCurrency
  }

  func goal(_ id: UUID) -> SavingsGoalRecord? {
    goals.first { $0.id == id }
  }

  /// At most `SavingsRules.maximumActiveGoals` are active; two devices adding at once can leave more, which stay until one is finished or set aside.
  var canAddGoal: Bool { activeCount < SavingsRules.maximumActiveGoals }

  /// Every active goal, as `GoalEdits` counts them against the limit: those filling and those in another currency.
  var activeCount: Int { active.count + otherCurrencyActive.count }

  /// Active goals in a currency other than home (made while two devices disagreed on it), which take no share but still count, move and can be bought or
  /// set aside.
  var otherCurrencyActive: [SavingsGoalRecord] { overview.allocation.otherCurrency.filter { $0.state == .known(.active) } }

  /// The bought and set-aside goals, in any currency.
  var settled: [SavingsGoalRecord] {
    overview.allocation.settled.map(\.goal) + overview.allocation.otherCurrency.filter { $0.state != .known(.active) }
  }

  /// The expense a forecast names as what pushed a goal back, by its note, its merchant or its category.
  func causeTitle(_ id: UUID) -> String? {
    causes[id].map { $0.note ?? $0.merchant ?? categoryName($0.category) }
  }

  func categoryName(_ key: CategoryKey) -> String {
    MoneyLabels.categoryName(key, label: labels[key])
  }

  func forecastLine(_ forecast: GoalForecast, locale: Locale) -> String {
    GoalCopy.forecast(forecast, today: overview.today, home: home, cause: causeTitle, category: categoryName, locale: locale)
  }
}

/// Savings for one screen, followed through every commit, a day turn's included.
@MainActor
@Observable
final class SavingsModel {
  let snapshot = MoneyFeed<SavingsSnapshot?>()
  @ObservationIgnored let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
  }

  var value: SavingsSnapshot? { snapshot.state.value ?? nil }

  func run() async {
    let main = context.stores.main
    let clock = context.clock
    await snapshot.consume(main.observeReads { transaction in try SavingsSnapshot.load(in: transaction, clock: clock) })
  }
}

/// What a goal action came to, for the line under the goals.
nonisolated enum GoalActionNotice: Equatable, Sendable {
  case bought(rewarded: Bool)
  case abandoned
  case deleted
}

/// The goals screens' writes, each through `GoalEdits` in one write: reordering the active goals, marking one bought, setting one aside and deleting one.
@MainActor
@Observable
final class GoalsModel {
  let savings: SavingsModel
  private(set) var working: Set<UUID> = []
  private(set) var failure: PresentedError?
  private(set) var notice: GoalActionNotice?
  @ObservationIgnored let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
    savings = SavingsModel(context: context)
  }

  func run() async {
    await savings.run()
  }

  /// SwiftUI's move of one goal (`onMove`), its destination an offset in the list before the move, as the index among the others.
  nonisolated static func target(from source: Int, to destination: Int) -> Int {
    destination > source ? destination - 1 : destination
  }

  /// The goal a move places the moved one after, among the goals listed: nil to move it first. The list holds only the goals filling, so the move names
  /// its neighbour (`GoalEdits.reorder(_:after:)`) and a goal in another currency between them keeps its place.
  nonisolated static func previous(of source: Int, to destination: Int, in listed: [UUID]) -> UUID? {
    var others = listed
    others.remove(at: source)
    let index = min(max(target(from: source, to: destination), 0), others.count)
    return index > 0 ? others[index - 1] : nil
  }

  @discardableResult
  func move(from sources: IndexSet, to destination: Int) async -> Bool {
    guard sources.count == 1, let source = sources.first, let listed = savings.value?.active.map(\.id), listed.indices.contains(source) else { return false }
    let id = listed[source]
    let previous = Self.previous(of: source, to: destination, in: listed)
    guard previous != (source > 0 ? listed[source - 1] : nil) else { return false }
    return await perform(id) { _, transaction in
      _ = try GoalEdits.reorder(id, after: previous, in: &transaction)
      return nil
    }
  }

  @discardableResult
  func markBought(_ id: UUID) async -> Bool {
    await perform(id) { issuer, transaction in
      .bought(rewarded: try GoalEdits.markBought(id, issuer: issuer, in: &transaction) != nil)
    }
  }

  @discardableResult
  func abandon(_ id: UUID) async -> Bool {
    await perform(id) { _, transaction in
      _ = try GoalEdits.abandon(id, in: &transaction)
      return .abandoned
    }
  }

  @discardableResult
  func delete(_ id: UUID) async -> Bool {
    await perform(id) { _, transaction in
      try GoalEdits.delete(id, in: &transaction)
      return .deleted
    }
  }

  func dismissNotice() {
    notice = nil
  }

  private func perform(_ id: UUID, _ body: @escaping @Sendable (CommandIssuer, inout WriteTransaction) throws -> GoalActionNotice?) async -> Bool {
    guard !working.contains(id) else { return false }
    working.insert(id)
    failure = nil
    notice = nil
    defer { working.remove(id) }
    do {
      notice = try await context.writer.write(body)
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }
}
