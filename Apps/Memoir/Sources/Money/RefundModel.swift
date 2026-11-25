import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore

enum RefundLabels {
  static func badge(_ state: ExpenseRefundState, currency: CurrencyCode, locale: Locale) -> String {
    switch state {
    case .full: String(localized: "Refunded", table: "Money")
    case .partial(let refundedMinor): String(localized: "Refunded \(MoneyText.formatted(refundedMinor, currency, locale: locale))", table: "Money")
    }
  }
}

enum RefundMode: Hashable, CaseIterable {
  case full
  case partial
}

enum RefundRefusal: Error, Equatable {
  case unreadable(AmountInputRefusal)
  case notPositive
  case exceeds(left: Int64)
}

@MainActor
@Observable
final class RefundModel {
  let expense: ExpenseRecord
  let format: AmountFormat
  let locale: Locale
  var mode: RefundMode = .full
  var amountText = "" {
    didSet { failure = nil }
  }
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  @ObservationIgnored private let context: MemoirScreenContext

  init(expense: ExpenseRecord, context: MemoirScreenContext, locale: Locale) {
    self.expense = expense
    self.context = context
    self.locale = locale
    format = AmountFormat(locale: locale)
  }

  var currency: CurrencyCode { expense.currency }
  var left: Int64 { expense.amountMinor }

  var refundMinor: Result<Int64, RefundRefusal> {
    guard mode == .partial else { return .success(left) }
    let typed: Int64
    do throws(AmountInputRefusal) {
      typed = try AmountInput.minorUnits(amountText, currency: currency, format: format)
    } catch {
      return .failure(.unreadable(error))
    }
    guard typed > 0 else { return .failure(.notPositive) }
    guard typed <= left else { return .failure(.exceeds(left: left)) }
    return .success(typed)
  }

  var amountIssue: String? {
    guard mode == .partial, !amountText.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let refusal) = refundMinor else { return nil }
    switch refusal {
    case .unreadable(let refusal): return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
    case .notPositive: return String(localized: "A refund has to be more than zero.", table: "Money")
    case .exceeds(let left): return String(localized: "That is more than the \(MoneyText.formatted(left, currency, locale: locale)) left on this expense.", table: "Money")
    }
  }

  var canSave: Bool {
    guard !isSaving, left > 0, case .success = refundMinor else { return false }
    return true
  }

  /// What the refund hands back of the part this expense drew from savings: the core clamps that part to what the expense still holds.
  var returnedToSavings: Int64? {
    guard let drawn = expense.fromSavingsMinor, drawn > 0, case .success(let refunded) = refundMinor else { return nil }
    let returned = drawn - min(drawn, left - refunded)
    return returned > 0 ? returned : nil
  }

  func save() async -> Bool {
    guard canSave, case .success(let refunded) = refundMinor else { return false }
    let id = expense.id
    let amount: RefundAmount = mode == .full ? .full : .partial(refunded)
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.refund(id, amount: amount, issuer: issuer, in: &transaction) }
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }
}
