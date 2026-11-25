import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// memoir-web `ExpenseEntryPanel` (`features/finance/expense-entry-panel.tsx`): the amount typed in the owner's locale and read exactly, the currency
/// (fixed once saved), the category, the date, the note and the merchant, and, for a foreign currency, a rate the owner types for this expense alone,
/// read exactly in their locale (`RateInput`), the budget it counts in, and the part paid from savings with the goal it buys. Writes go only through
/// `ExpenseEdits`, which holds a draw on savings to the one-off rule, what is available and a goal's cooling-off.
@MainActor
@Observable
final class ExpenseForm {
  enum Mode: Equatable {
    case create
    case edit(ExpenseRecord)
  }

  let mode: Mode
  let options: MoneyOptions
  let format: AmountFormat
  var amountText: String
  /// Empty for the reference rate; the home currency per one unit of the expense's currency otherwise.
  var rateText: String
  private(set) var currency: CurrencyCode
  var category: CategoryKey
  var occurredOn: LocalDate
  var note: String
  var merchant: String
  /// Nil before the vault has settings.
  var budget: BudgetPick?
  /// Empty for nothing from savings; the part paid from savings in the expense's currency otherwise.
  var fromSavingsText: String
  var goal: UUID?
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  /// The receipt being added with a new expense; nil when editing, since a saved expense's receipt is fixed.
  let receipt: ReceiptDraft?
  @ObservationIgnored private let writer: MemoirWriter
  @ObservationIgnored private let stores: MemoirStores
  @ObservationIgnored private let original: ExpenseRecord?
  @ObservationIgnored private let originalRateText: String

  init(mode: Mode, options: MoneyOptions, context: MemoirScreenContext, locale: Locale, receipt: ReceiptDraft? = nil) {
    self.mode = mode
    self.options = options
    writer = context.writer
    stores = context.stores
    format = AmountFormat(locale: locale)
    switch mode {
    case .create:
      original = nil
      self.receipt = receipt
      amountText = ""
      rateText = ""
      originalRateText = ""
      currency = options.home ?? options.currencies(including: nil).first ?? MoneyOptions.referenceCurrencies[0]
      category = MoneyBook.uncategorised ?? MoneyBook.builtInCategories[0]
      occurredOn = options.today
      note = ""
      merchant = ""
      budget = BudgetPick(budgets: options.budgets, stored: nil)
      fromSavingsText = ""
      goal = nil
    case .edit(let expense):
      original = expense
      self.receipt = nil
      amountText = MoneyText.editable(expense.amountMinor, expense.currency, format: format)
      let manual = expense.manualRate.flatMap { $0.quote == options.home ? $0.rate : nil }
      let shownRate = manual.map { MoneyText.editableRate($0, format: AmountFormat(locale: locale)) } ?? ""
      rateText = shownRate
      originalRateText = shownRate
      currency = expense.currency
      category = expense.category
      occurredOn = expense.occurredOn
      note = expense.note ?? ""
      merchant = expense.merchant ?? ""
      budget = BudgetPick(budgets: options.budgets, stored: expense.budget)
      let editableFormat = AmountFormat(locale: locale)
      fromSavingsText = expense.fromSavingsMinor.map { MoneyText.editable($0, expense.currency, format: editableFormat) } ?? ""
      goal = expense.goal
    }
  }

  /// A confirmed cycle's expense counts where its subscription's override says unless it has one of its own.
  var subscriptionOverride: UUID? {
    original?.cycle.flatMap { options.subscriptionBudgets[$0.subscription] }
  }

  var isEditing: Bool { original != nil }

  /// memoir-web `LOCKED_CURRENCY_HELPER`: a saved expense keeps its currency (`FIN_006`).
  var canChangeCurrency: Bool { original == nil }

  var currencies: [CurrencyCode] { options.currencies(including: currency) }

  func select(_ currency: CurrencyCode) {
    guard canChangeCurrency, currency != self.currency else { return }
    self.currency = currency
    rateText = ""
  }

  var categories: [CategoryEntry] { options.categories(including: category) }

  /// memoir-web `latestDate`: today, or the saved date when it is later.
  var latestDate: LocalDate { max(options.today, original?.occurredOn ?? options.today) }

  var amount: Result<Int64, AmountInputRefusal> {
    do throws(AmountInputRefusal) {
      return .success(try AmountInput.minorUnits(amountText, currency: currency, format: format))
    } catch {
      return .failure(error)
    }
  }

  /// The expense converts into another currency, so the owner may give its rate.
  var offersRate: Bool {
    guard let home = options.home else { return false }
    return currency != home
  }

  /// No rate typed is the reference rate; a typed one converts this expense alone. Until the field is edited, a saved expense keeps its own, even one
  /// into another currency than home, which the field cannot show.
  var manualRate: Result<ManualRate?, RateInputRefusal> {
    guard rateText != originalRateText, offersRate, let home = options.home else { return .success(original?.manualRate) }
    guard !rateText.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(nil) }
    do throws(RateInputRefusal) {
      return .success(ManualRate(rate: try RateInput.rate(rateText, format: format).text, quote: home))
    } catch {
      return .failure(error)
    }
  }

  var rateIssue: String? {
    guard case .failure(let refusal) = manualRate else { return nil }
    return MoneyLabels.rateIssue(refusal, format: format)
  }

  /// Shown once something is typed, as memoir-web marks the field only when it holds text.
  var amountIssue: String? {
    guard !amountText.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let refusal) = amount else { return nil }
    return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
  }

  var hasChanges: Bool {
    guard let original else {
      return !amountText.isEmpty || !rateText.isEmpty || !note.isEmpty || !merchant.isEmpty || receipt?.hasPhoto == true || budget?.override != nil
        || !fromSavingsText.isEmpty || goal != nil
    }
    return edited(original).map { $0 != original } ?? true
  }

  var canSave: Bool {
    guard !isSaving, case .success = amount, case .success = manualRate, case .success = fromSavings, occurredOn <= latestDate, receipt?.blocksSave != true
    else { return false }
    return original == nil || hasChanges
  }

  /// memoir-web `previewText` without the estimate, which needs a rate this device may not have.
  func preview(locale: Locale) -> String? {
    guard case .success(let minor) = amount else { return nil }
    let typed = MoneyText.formatted(minor, currency, locale: locale)
    guard let home = options.home, currency != home else { return String(localized: "\(typed) will be saved.", table: "Money") }
    if case .success(let manual?) = manualRate, let exchange = try? ExchangeRate(manual.rate),
      let converted = try? HomeConversion.convert(MoneyAmount(amountMinor: minor, currency: currency), to: home, at: exchange)
    {
      let estimate = MoneyText.formatted(converted, locale: locale)
      return String(localized: "\(typed) ≈ \(estimate) at \(MoneyText.rate(manual.rate, locale: locale)), the rate you entered.", table: "Money")
    }
    if let rate = original?.rate, rate.quote == home, let exchange = try? ExchangeRate(rate.rate),
      let converted = try? HomeConversion.convert(MoneyAmount(amountMinor: minor, currency: currency), to: home, at: exchange)
    {
      let estimate = MoneyText.formatted(converted, locale: locale)
      let rateText = MoneyText.rate(rate.rate, locale: locale)
      return String(localized: "\(typed) ≈ \(estimate) at \(rateText), the rate this expense is locked to.", table: "Money")
    }
    if original != nil { return String(localized: "\(typed) is kept as typed. Its \(home.code) value follows once the rate is known.", table: "Money") }
    let day = MoneyDates.text(occurredOn, locale: locale, showsYear: false)
    return String(localized: "\(typed) is saved as typed. Its \(home.code) value uses the rate on \(day), once it is known.", table: "Money")
  }

  var fromSavings: Result<Int64?, AmountInputRefusal> {
    guard !fromSavingsText.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(nil) }
    do throws(AmountInputRefusal) {
      return .success(try AmountInput.minorUnits(fromSavingsText, currency: currency, format: format))
    } catch {
      return .failure(error)
    }
  }

  var fromSavingsIssue: String? {
    guard case .failure(let refusal) = fromSavings else { return nil }
    return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
  }

  /// The active goals, and the one the expense already names when it no longer fills, so opening and saving never drops it.
  var goalChoices: [GoalChoice] {
    guard let savings = options.savings else { return [] }
    var choices = savings.activeGoals.map { GoalChoice(id: $0.id, name: $0.name) }
    if let stored = original?.goal, !choices.contains(where: { $0.id == stored }) {
      let name = savings.goal(stored).map { String(localized: "\($0.name) (no longer filling)", table: "Money") }
      choices.append(GoalChoice(id: stored, name: name ?? String(localized: "A deleted goal", table: "Money")))
    }
    return choices
  }

  /// The budget the expense counts in, as the chip assigns it, whose one-off threshold a draw that buys no goal must reach.
  var assignedBudget: LiveBudget? {
    guard let budget else { return nil }
    let id = budget.assignment(currency: currency, on: occurredOn, subscriptionOverride: subscriptionOverride).budget
    return options.budgets.budget(id) ?? (id == HomeBudget.id ? options.budgets.home : nil)
  }

  /// The currencies a refusal of the draw counts in: the budget's for the one-off threshold, home for what is available.
  var savingsAmounts: SavingsAmounts? {
    guard let home = options.savings?.home else { return nil }
    return SavingsAmounts(budget: assignedBudget?.currency ?? home, home: home)
  }

  /// What the core holds a draw on savings to, said before saving: a goal's purchase needs no one-off but waits out the cooling-off, any other draw is a
  /// one-off of the budget's threshold; what is available; and that a draw in a currency without a rate waits for it.
  func savingsNotes(locale: Locale) -> [String] {
    guard let savings = options.savings else { return [] }
    var notes = [String]()
    if goal != nil {
      notes.append(
        String(
          localized: "Buying a goal needn’t be a one-off. A goal can be bought from \(SavingsRules.coolingOffDays) days after it was made.", table: "Money"))
    } else if let budget = assignedBudget {
      let name = BudgetCopy.name(of: budget)
      if let threshold = savings.oneOffThreshold(of: budget, on: occurredOn).minor {
        let amount = MoneyText.formatted(threshold, budget.currency, locale: locale)
        notes.append(String(localized: "Only a one-off can be paid from savings: in \(name), \(amount) or more.", table: "Money"))
      } else {
        notes.append(String(localized: "\(name) has no one-off amount yet, so only a goal’s purchase can be paid from savings.", table: "Money"))
      }
    }
    let available = SavingsCopy.available(savings.overview.balance, locale: locale)
    notes.append(
      (original?.fromSavingsMinor ?? 0) > 0
        ? String(localized: "\(available), besides what this expense already draws.", table: "Money") : available)
    if offersRate, case .success(nil) = manualRate, original?.rate == nil {
      notes.append(String(localized: "A part from savings in \(currency.code) needs a rate: one you enter, or the day’s reference rate once it’s known.", table: "Money"))
    }
    return notes
  }

  func edited() {
    failure = nil
  }

  /// The expense's id once written; `nil` when the amount does not read or the write failed, with the failure shown.
  func save() async -> UUID? {
    guard canSave, case .success(let minor) = amount, case .success(let manualRate) = manualRate, case .success(let fromSavings) = fromSavings else {
      return nil
    }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      let moved = budget?.movedOverride
      if let original {
        let id = original.id
        let fields = fields(minor: minor, manualRate: manualRate, fromSavings: fromSavings, budget: budget.map(\.written) ?? original.budget)
        _ = try await writer.write { issuer, transaction in
          try BudgetPick.requireLive(moved, in: transaction)
          return try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { expense in fields.apply(to: &expense) }
        }
        return id
      }
      let now = writer.clock.now()
      let expense = ExpenseRecord(
        id: UUID.v7(at: now), amountMinor: minor, currency: currency, occurredOn: occurredOn, category: category, merchant: Self.text(merchant), note: Self.text(note),
        manualRate: manualRate, budget: budget?.override, fromSavingsMinor: fromSavings, goal: goal, loggedAtMillis: MemoirClock.millis(now))
      guard let receipt else {
        return try await writer.write { issuer, transaction in
          try BudgetPick.requireLive(moved, in: transaction)
          return try ExpenseEdits.create(expense, issuer: issuer, in: &transaction).expense.id
        }
      }
      do throws(ReceiptWriteError) {
        return try await ReceiptWrites.create(expense, attaching: receipt.attachment, blobs: receipt.blobs, writer: writer).id
      } catch {
        failure = ReceiptCopy.presented(error)
        return nil
      }
    } catch {
      failure = WritingErrors.presented(error, savings: savingsAmounts)
      if BudgetPick.isAbsentBudget(error), let budgets = try? await MoneyOptions.budgets(in: stores) { budget?.refresh(budgets) }
      return nil
    }
  }

  private func edited(_ expense: ExpenseRecord) -> ExpenseRecord? {
    guard case .success(let minor) = amount, case .success(let manualRate) = manualRate, case .success(let fromSavings) = fromSavings else { return nil }
    var edited = expense
    fields(minor: minor, manualRate: manualRate, fromSavings: fromSavings, budget: budget.map(\.written) ?? expense.budget).apply(to: &edited)
    return edited
  }

  private func fields(minor: Int64, manualRate: ManualRate?, fromSavings: Int64?, budget: UUID?) -> Fields {
    Fields(
      minor: minor, category: category, occurredOn: occurredOn, note: Self.text(note), merchant: Self.text(merchant), manualRate: manualRate, budget: budget,
      fromSavings: fromSavings, goal: goal)
  }

  private static func text(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private nonisolated struct Fields: Sendable {
    let minor: Int64
    let category: CategoryKey
    let occurredOn: LocalDate
    let note: String?
    let merchant: String?
    let manualRate: ManualRate?
    let budget: UUID?
    let fromSavings: Int64?
    let goal: UUID?

    func apply(to expense: inout ExpenseRecord) {
      expense.amountMinor = minor
      expense.category = category
      expense.occurredOn = occurredOn
      expense.note = note
      expense.merchant = merchant
      expense.manualRate = manualRate
      expense.budget = budget
      expense.fromSavingsMinor = fromSavings
      expense.goal = goal
    }
  }
}
