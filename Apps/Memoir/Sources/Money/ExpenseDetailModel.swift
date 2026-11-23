import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// memoir-web `ExpenseDetailScreen`: one expense with its amount at home, the rate it is fixed to, its edit history, and delete with undo.
@MainActor
@Observable
final class ExpenseDetailModel {
  /// What was deleted on this screen, kept so undo can write it again: the core re-creates a deleted id with the currency, rate and logging time of its
  /// first write (`ExpenseEdits.create`), and the note and merchant the deletion cleared come from here.
  struct Deletion: Equatable {
    let snapshot: ExpenseRecord
    let source: ExpenseSource
    let canUndo: Bool
  }

  struct HistoryLine: Identifiable, Equatable {
    let id: String
    let text: String
    let when: String
  }

  let id: UUID
  let history = MoneyFeed<ExpenseHistory>()
  let book = MoneyFeed<MoneyBook>()
  private var recordedDeletion: Deletion?
  /// Set while an undo is written; the read showing the expense again ends the deletion, so a later delete elsewhere shows as gone, never undoable.
  private var isRestoring = false
  private(set) var isWorking = false
  private(set) var failure: PresentedError?
  @ObservationIgnored let context: MemoirScreenContext

  init(id: UUID, context: MemoirScreenContext) {
    self.id = id
    self.context = context
  }

  func run() async {
    let stores = context.stores
    async let expense: Void = history.consume(MoneyReads.observeHistory(of: id, in: stores)) { [weak self] history in self?.settle(history) }
    async let money: Void = book.consume(stores.main.observeReads { transaction in try MoneyBook.load(from: transaction) })
    _ = await (expense, money)
  }

  /// The deletion made here, until the read shows the expense again, so neither the delete nor its undo flashes "no longer here".
  var deletion: Deletion? { expense == nil ? recordedDeletion : nil }

  var expense: ExpenseRecord? {
    guard case .readable(let entry) = history.state.value?.expense, !entry.isRemoved else { return nil }
    return entry.record
  }

  /// The history has loaded and holds no expense under this id: deleted elsewhere, or never synced to this device.
  var isGone: Bool {
    guard let history = history.state.value else { return false }
    return expense == nil && recordedDeletion == nil && !history.expense.isUnreadable
  }

  var home: CurrencyCode? { book.state.value?.home }

  var inHome: HomeAmount? {
    guard let expense, let book = book.state.value, let home = book.home else { return nil }
    return HomeConverter(home: home, rates: book.rates).homeAmount(of: expense)
  }

  /// The rate the expense converts at, when it converts into the home currency through one.
  var rate: DecimalText? {
    guard let expense, let book = book.state.value, let home = book.home, expense.currency != home else { return nil }
    return HomeConverter(home: home, rates: book.rates).rate(for: expense)
  }

  /// The expense converts at a rate the owner entered for it.
  var isManualRate: Bool {
    guard let expense, let home else { return false }
    return expense.currency != home && expense.manualRate?.quote == home
  }

  /// Still waiting for a rate, which the owner can enter by hand.
  var isAwaitingRate: Bool { inHome == .awaitingRate }

  var source: ExpenseSource {
    for entry in history.state.value?.entries ?? [] {
      if case .created(let source) = entry.action { return source }
    }
    return .manual
  }

  /// A confirmed subscription cycle's expense, under its derived id.
  var isCycleExpense: Bool {
    history.state.value?.entries.contains { if case .cycleConfirmed = $0.action { true } else { false } } ?? false
  }

  /// memoir-web `isRestorable`: an expense with a receipt or one a subscription cycle wrote is not offered back.
  var canUndoDelete: Bool {
    guard let expense else { return false }
    return expense.receipt == nil && !isCycleExpense
  }

  func categoryName(_ key: CategoryKey) -> String {
    MoneyLabels.categoryName(key, label: book.state.value?.categoryRecords.first { $0.categoryKey == key }?.label)
  }

  func delete() async {
    guard let expense, deletion == nil, !isWorking else { return }
    let deleted = Deletion(snapshot: expense, source: source, canUndo: canUndoDelete)
    let id = id
    isWorking = true
    failure = nil
    recordedDeletion = deleted
    defer { isWorking = false }
    do {
      _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.delete(id, issuer: issuer, in: &transaction) }
    } catch {
      recordedDeletion = nil
      failure = WritingErrors.presented(error)
    }
  }

  func undo() async {
    guard let deletion, deletion.canUndo, !isWorking else { return }
    isWorking = true
    failure = nil
    isRestoring = true
    defer { isWorking = false }
    do {
      _ = try await context.writer.write { issuer, transaction in
        try ExpenseEdits.create(deletion.snapshot, source: deletion.source, issuer: issuer, in: &transaction).expense
      }
    } catch {
      isRestoring = false
      failure = WritingErrors.presented(error)
    }
  }

  private func settle(_ history: ExpenseHistory) {
    guard isRestoring, case .readable(let entry) = history.expense, !entry.isRemoved else { return }
    isRestoring = false
    recordedDeletion = nil
  }

  /// memoir-web `describeAuditEntry`, newest first, one line per moved field.
  func historyLines(locale: Locale) -> [HistoryLine] {
    guard let history = history.state.value else { return [] }
    let currency = expense?.currency ?? deletion?.snapshot.currency
    return history.entries.flatMap { entry in
      let when = MoneyDates.moment(millis: entry.instantMillis, offsetMinutes: entry.utcOffsetMinutes, locale: locale)
      return describe(entry.action, currency: currency, locale: locale).enumerated().map { index, text in
        HistoryLine(id: "\(entry.command.uuidString)-\(index)", text: text, when: when)
      }
    }
  }

  private func describe(_ action: ExpenseHistoryAction, currency: CurrencyCode?, locale: Locale) -> [String] {
    switch action {
    case .created: [String(localized: "Created", table: "Money")]
    case .deleted: [String(localized: "Deleted", table: "Money")]
    case .cycleConfirmed: [String(localized: "Subscription charge confirmed", table: "Money")]
    case .receiptScanned: [String(localized: "Receipt scanned", table: "Money")]
    case .updated(let changes?) where !changes.isEmpty: changes.map { describe($0, currency: currency, locale: locale) }
    case .updated: [String(localized: "Edited", table: "Money")]
    }
  }

  /// memoir-web `describeAuditChange`.
  private func describe(_ change: ExpenseFieldChange, currency: CurrencyCode?, locale: Locale) -> String {
    let amount = { (minor: Int64) in currency.map { MoneyText.formatted(minor, $0, locale: locale) } ?? String(minor) }
    let quoted = { (text: String) in String(localized: "“\(text)”", table: "Money") }
    switch change {
    case .amount(let from, let to): return Self.moved(String(localized: "Amount", table: "Money"), amount(from), amount(to))
    case .occurredOn(let from, let to):
      return Self.moved(String(localized: "Date", table: "Money"), MoneyDates.text(from, locale: locale), MoneyDates.text(to, locale: locale))
    case .category(let from, let to): return Self.moved(String(localized: "Category", table: "Money"), categoryName(from), categoryName(to))
    case .note(let from, let to): return Self.moved(String(localized: "Note", table: "Money"), from.map(quoted), to.map(quoted))
    case .merchant(let from, let to): return Self.moved(String(localized: "Merchant", table: "Money"), from.map(quoted), to.map(quoted))
    case .manualRate(let from, let to):
      let rate = { (manual: ManualRate) in MoneyText.rate(manual.rate, locale: locale) }
      return Self.moved(String(localized: "Rate you entered", table: "Money"), from.map(rate), to.map(rate))
    }
  }

  private static func moved(_ field: String, _ from: String?, _ to: String?) -> String {
    switch (from, to) {
    case (nil, nil): String(localized: "\(field) changed", table: "Money")
    case (nil, let to?): String(localized: "\(field) added: \(to)", table: "Money")
    case (let from?, nil): String(localized: "\(field) removed (was \(from))", table: "Money")
    case (let from?, let to?): String(localized: "\(field) \(from) → \(to)", table: "Money")
    }
  }
}

extension MemoirReading {
  fileprivate var isUnreadable: Bool {
    guard case .unreadable = self else { return false }
    return true
  }
}
