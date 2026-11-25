import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// What the budget form offers, read when it opens: the account's day, the home and enabled currencies, and every live budget's standing, Home stood
/// in for until it is written.
nonisolated struct BudgetFormOptions: Sendable, Equatable {
  let today: LocalDate
  let home: CurrencyCode
  let enabled: [CurrencyCode]
  let standings: BudgetStandings

  /// Nil before the vault has settings.
  static func load(_ context: MemoirScreenContext) async throws -> BudgetFormOptions? {
    let today = try await context.today().date
    return try await context.stores.main.read { transaction in
      let book = try BudgetBook.load(from: transaction)
      guard let settings = book.settings, let standings = try BudgetStandings.make(book, today: today) else { return nil }
      return BudgetFormOptions(today: today, home: settings.defaultCurrency, enabled: settings.enabledCurrencies, standings: standings)
    }
  }

  var budgets: [LiveBudget] { standings.budgets.map(\.budget) }
}

/// Creates a monthly or trip budget, or edits one: its name, limit, trip dates and the owner's one-off threshold. Home keeps its name, currency and kind;
/// a saved budget keeps its currency and kind. Writes go only through `BudgetEdits`, which stages and refuses as the plan says; the form tells the owner
/// beforehand what a change will do.
@MainActor
@Observable
final class BudgetForm {
  enum Kind: String, CaseIterable, Hashable {
    case monthly
    case trip
  }

  let options: BudgetFormOptions
  let editing: LiveBudget?
  let format: AmountFormat
  let locale: Locale
  var kind: Kind {
    didSet { if !currencies.contains(currency), let first = currencies.first { currency = first } }
  }
  var name: String
  private(set) var currency: CurrencyCode
  var limitText: String
  var from: LocalDate
  var through: LocalDate
  var oneOffText: String
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  @ObservationIgnored private let opening: BudgetDraft?
  @ObservationIgnored private let context: MemoirScreenContext

  init(editing budget: LiveBudget? = nil, options: BudgetFormOptions, context: MemoirScreenContext, locale: Locale) {
    self.options = options
    editing = budget
    self.context = context
    self.locale = locale
    let format = AmountFormat(locale: locale)
    self.format = format
    guard let budget else {
      opening = nil
      kind = .trip
      name = ""
      currency = options.home
      limitText = ""
      from = options.today
      through = options.today.adding(days: 6) ?? options.today
      oneOffText = ""
      return
    }
    let draft = BudgetDraft(budget, on: options.today)
    opening = draft
    name = draft.name ?? ""
    currency = draft.currency
    limitText = draft.limitMinor.map { MoneyText.editable($0, draft.currency, format: format) } ?? ""
    oneOffText = draft.oneOffFromMinor.map { MoneyText.editable($0, draft.currency, format: format) } ?? ""
    switch draft.period {
    case .monthly:
      kind = .monthly
      from = options.today
      through = options.today
    case .trip(let start, let end):
      kind = .trip
      from = start
      through = end
    }
  }

  var today: LocalDate { options.today }
  var isEditing: Bool { editing != nil }
  var isHome: Bool { editing?.isHome == true }

  /// The kind and currency are chosen once, when the budget is made.
  var canChangeKindAndCurrency: Bool { editing == nil }

  /// A trip that has started keeps its first day.
  var isStartFixed: Bool {
    guard case .trip(let start, _)? = editing?.record.period else { return false }
    return today >= start
  }

  /// A trip may start at most `BudgetEdits.tripBackdatingDays` before today; nil once its start is fixed.
  var earliestStart: LocalDate? {
    isStartFixed ? nil : today.adding(days: -BudgetEdits.tripBackdatingDays)
  }

  /// The enabled currencies, home first; a monthly budget only in one that has none yet, Home's included.
  var currencies: [CurrencyCode] {
    guard canChangeKindAndCurrency else { return [currency] }
    let enabled = [options.home] + options.enabled.filter { $0 != options.home }
    guard kind == .monthly else { return enabled }
    let taken = Set(options.budgets.filter { $0.record.period == .monthly }.map(\.currency))
    return enabled.filter { !taken.contains($0) }
  }

  /// Every enabled currency already has a monthly budget.
  var isMonthlyUnavailable: Bool { canChangeKindAndCurrency && kind == .monthly && currencies.isEmpty }

  func select(_ currency: CurrencyCode) {
    guard canChangeKindAndCurrency, currencies.contains(currency) else { return }
    self.currency = currency
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var nameIssue: String? {
    guard !isHome, !name.isEmpty, trimmedName.isEmpty else { return nil }
    return String(localized: "Enter a name", table: "Money")
  }

  var limit: Result<Int64, AmountInputRefusal> {
    Self.amount(limitText, currency: currency, format: format)
  }

  var limitIssue: String? {
    guard !limitText.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let refusal) = limit else { return nil }
    return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
  }

  /// Empty is the automatic threshold.
  var oneOff: Result<Int64?, AmountInputRefusal> {
    guard !oneOffText.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(nil) }
    return Self.amount(oneOffText, currency: currency, format: format).map(Optional.some)
  }

  var oneOffIssue: String? {
    guard case .failure(let refusal) = oneOff else { return nil }
    return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
  }

  var period: BudgetPeriodKind {
    kind == .monthly ? .monthly : .trip(from: from, through: through)
  }

  var datesIssue: String? {
    guard kind == .trip else { return nil }
    if through < from { return String(localized: "A trip ends on or after the day it starts.", table: "Money") }
    guard let earliest = earliestStart, from < earliest, startMoved else { return nil }
    return String(localized: "A trip can start on \(MoneyDates.text(earliest, locale: locale)) at the earliest.", table: "Money")
  }

  /// What `BudgetEdits` would write for the draft, or its refusal; nil for a new budget, an amount that does not read, or a draft that moves nothing.
  var preview: Result<BudgetEditPreview, FinanceError>? {
    guard let editing, let draft else { return nil }
    do throws(FinanceError) {
      return try BudgetEdits.preview(draft, of: editing, today: today).map { Result<BudgetEditPreview, FinanceError>.success($0) }
    } catch {
      return .failure(error)
    }
  }

  var refusal: FinanceError? {
    guard case .failure(let error)? = preview else { return nil }
    return error
  }

  var limitChange: BudgetStagedChange? {
    guard case .success(let preview)? = preview else { return nil }
    return preview.limit
  }

  var thresholdChange: BudgetStagedChange? {
    guard case .success(let preview)? = preview else { return nil }
    return preview.oneOff
  }

  /// What saving the limit will do, or why it cannot be saved; nil when the limit does not move.
  var limitNote: String? {
    let money = { (minor: Int64) in MoneyText.formatted(minor, self.currency, locale: self.locale) }
    switch refusal {
    case .limitChangedThisMonth?:
      guard let opening = openingLimitMinor else { return String(localized: "This month’s limit has already changed. Raise it again next month.", table: "Money") }
      return String(localized: "This month’s limit has already changed, so until next month it can go up only as far as \(money(opening)).", table: "Money")
    case .tripLimitLocked?:
      return String(localized: "The trip has started, so its limit can only go down.", table: "Money")
    default:
      break
    }
    switch limitChange {
    case nil:
      return nil
    case .applies(let dropping)?:
      let applies =
        kind == .trip
        ? String(localized: "The new limit counts for the whole trip.", table: "Money")
        : String(localized: "The new limit counts for the whole of this month.", table: "Money")
      guard let dropping else { return applies }
      let dropped = String(
        localized: "The change to \(money(dropping.amountMinor)) planned for \(MoneyDates.text(dropping.from, locale: locale)) is dropped.", table: "Money")
      return [applies, dropped].joined(separator: " ")
    case .staged(let staged, let keeping)?:
      let day = MoneyDates.text(staged.from, locale: locale)
      guard let keeping else { return String(localized: "The new limit starts on \(day).", table: "Money") }
      return String(localized: "A raise waits for next month: the new limit starts on \(day), and this month keeps \(money(keeping)).", table: "Money")
    }
  }

  var thresholdNote: String? {
    guard case .staged(let staged, _)? = thresholdChange else { return nil }
    return String(
      localized: "This threshold starts on \(MoneyDates.text(staged.from, locale: locale)), since a lower one waits for the next month.", table: "Money")
  }

  /// The limit the month opened with, which a raise this month may go back up to.
  private var openingLimitMinor: Int64? {
    guard let editing, let lastMonth = DateSpan.month(of: today)?.start.adding(days: -1) else { return nil }
    return editing.limitMinor(on: lastMonth)
  }

  /// The threshold the budget uses while the field is empty: the owner's, or the automatic one this month.
  var currentThreshold: String? {
    guard let editing, let minor = options.standings.standing(of: editing.id)?.oneOff.minor else { return nil }
    return MoneyText.formatted(minor, currency, locale: locale)
  }

  var draft: BudgetDraft? {
    guard case .success(let limit) = limit, case .success(let oneOff) = oneOff else { return nil }
    guard let opening else {
      return BudgetDraft(name: trimmedName, currency: currency, limitMinor: limit, period: period, oneOffFromMinor: oneOff)
    }
    var draft = opening
    draft.limitMinor = limit
    draft.oneOffFromMinor = oneOff
    guard !isHome else { return draft }
    draft.name = trimmedName
    draft.period = period
    return draft
  }

  var hasChanges: Bool {
    guard let opening else { return !name.isEmpty || !limitText.isEmpty || !oneOffText.isEmpty }
    return draft.map { $0 != opening } ?? true
  }

  var canSave: Bool {
    guard !isSaving, draft != nil, datesIssue == nil, !isMonthlyUnavailable, refusal == nil else { return false }
    guard isHome || !trimmedName.isEmpty else { return false }
    return !isEditing || hasChanges
  }

  /// The budget's id once written; nil when nothing was written, with the failure shown.
  func save() async -> UUID? {
    guard canSave, let draft else { return nil }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      let today = try await context.today().date
      if let editing, let opening {
        let id = editing.id
        try await context.writer.write { _, transaction in
          _ = try BudgetEdits.update(id, today: today, in: &transaction) { Self.apply(draft, changedFrom: opening, to: &$0) }
        }
        return id
      }
      let id = UUID.v7(at: context.clock.now())
      try await context.writer.write { _, transaction in
        _ = try BudgetEdits.create(draft, id: id, today: today, in: &transaction)
      }
      return id
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
  }

  /// Every budget but Home can be deleted; its expenses count by the assignment rule again.
  func delete() async -> Bool {
    guard let editing, !editing.isHome, !isSaving else { return false }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    let id = editing.id
    do {
      try await context.writer.write { _, transaction in try BudgetEdits.delete(id, in: &transaction) }
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }

  func edited() {
    failure = nil
  }

  /// Only the fields the owner moved, so a change written elsewhere while the form was open stays.
  private nonisolated static func apply(_ draft: BudgetDraft, changedFrom opening: BudgetDraft, to current: inout BudgetDraft) {
    if draft.name != opening.name { current.name = draft.name }
    if draft.period != opening.period { current.period = draft.period }
    if draft.limitMinor != opening.limitMinor { current.limitMinor = draft.limitMinor }
    if draft.oneOffFromMinor != opening.oneOffFromMinor { current.oneOffFromMinor = draft.oneOffFromMinor }
  }

  private var startMoved: Bool {
    guard case .trip(let start, _)? = editing?.record.period else { return true }
    return from != start
  }

  private static func amount(_ text: String, currency: CurrencyCode, format: AmountFormat) -> Result<Int64, AmountInputRefusal> {
    do throws(AmountInputRefusal) {
      return .success(try AmountInput.minorUnits(text, currency: currency, format: format))
    } catch {
      return .failure(error)
    }
  }
}
