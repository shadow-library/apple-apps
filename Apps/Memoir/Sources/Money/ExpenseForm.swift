import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// memoir-web `ExpenseEntryPanel` (`features/finance/expense-entry-panel.tsx`): the amount typed in the owner's locale and read exactly, the currency
/// (fixed once saved), the category, the date, the note and the merchant, and, for a foreign currency, a rate the owner types for this expense alone,
/// read exactly in their locale (`RateInput`). Writes go only through `ExpenseEdits`.
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
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  /// The receipt being added with a new expense; nil when editing, since a saved expense's receipt is fixed.
  let receipt: ReceiptDraft?
  @ObservationIgnored private let writer: MemoirWriter
  @ObservationIgnored private let original: ExpenseRecord?
  @ObservationIgnored private let originalRateText: String

  init(mode: Mode, options: MoneyOptions, context: MemoirScreenContext, locale: Locale, receipt: ReceiptDraft? = nil) {
    self.mode = mode
    self.options = options
    writer = context.writer
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
    }
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
    guard let original else { return !amountText.isEmpty || !rateText.isEmpty || !note.isEmpty || !merchant.isEmpty || receipt?.hasPhoto == true }
    return edited(original).map { $0 != original } ?? true
  }

  var canSave: Bool {
    guard !isSaving, case .success = amount, case .success = manualRate, occurredOn <= latestDate, receipt?.blocksSave != true else { return false }
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

  func edited() {
    failure = nil
  }

  /// The expense's id once written; `nil` when the amount does not read or the write failed, with the failure shown.
  func save() async -> UUID? {
    guard canSave, case .success(let minor) = amount, case .success(let manualRate) = manualRate else { return nil }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      if let original {
        let id = original.id
        let fields = Fields(minor: minor, category: category, occurredOn: occurredOn, note: Self.text(note), merchant: Self.text(merchant), manualRate: manualRate)
        _ = try await writer.write { issuer, transaction in
          try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { expense in fields.apply(to: &expense) }
        }
        return id
      }
      let now = writer.clock.now()
      let expense = ExpenseRecord(
        id: UUID.v7(at: now), amountMinor: minor, currency: currency, occurredOn: occurredOn, category: category, merchant: Self.text(merchant), note: Self.text(note),
        manualRate: manualRate, loggedAtMillis: MemoirClock.millis(now))
      guard let receipt else {
        return try await writer.write { issuer, transaction in try ExpenseEdits.create(expense, issuer: issuer, in: &transaction).expense.id }
      }
      do throws(ReceiptWriteError) {
        return try await ReceiptWrites.create(expense, attaching: receipt.attachment, blobs: receipt.blobs, writer: writer).id
      } catch {
        failure = ReceiptCopy.presented(error)
        return nil
      }
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
  }

  private func edited(_ expense: ExpenseRecord) -> ExpenseRecord? {
    guard case .success(let minor) = amount, case .success(let manualRate) = manualRate else { return nil }
    var edited = expense
    Fields(minor: minor, category: category, occurredOn: occurredOn, note: Self.text(note), merchant: Self.text(merchant), manualRate: manualRate).apply(to: &edited)
    return edited
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

    func apply(to expense: inout ExpenseRecord) {
      expense.amountMinor = minor
      expense.category = category
      expense.occurredOn = occurredOn
      expense.note = note
      expense.merchant = merchant
      expense.manualRate = manualRate
    }
  }
}
