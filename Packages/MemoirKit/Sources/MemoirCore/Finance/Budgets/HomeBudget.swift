import Foundation
import ShadowStore

public enum HomeBudgetEnsured: Equatable, Sendable {
  case created(BudgetRecord)
  case present(BudgetRecord)
  /// Home keeps the currency it was first written in, which the account's default currency no longer names (two devices set up the vault in
  /// different currencies). Home is left as it is.
  case currencyDiffers(BudgetRecord, account: CurrencyCode)
  case unreadable(MemoirUnreadable)
  case waitingForSettings
}

/// Home is every vault's monthly budget in the home currency, under one derived id so every device makes the same one.
public enum HomeBudget {
  public static let id = BudgetRecord.homeID

  /// Writes only Home's currency, period and creation day, without marking it present: a device that has not yet received Home writes nothing that
  /// could undo a limit set on another device. Until a limit is written, Home's limit is the account's monthly budget, which is never written back.
  @discardableResult
  public static func ensure(on today: LocalDate, in transaction: inout WriteTransaction) throws(FinanceError) -> HomeBudgetEnsured {
    guard let settings = try FinanceLedger.settings(in: transaction) else { return .waitingForSettings }
    let reading: MemoirReading<MemoirEntry<BudgetRecord>>
    do throws(StoreError) {
      reading = try BudgetRecord.read(id: id, in: transaction)
    } catch {
      throw FinanceError(error)
    }
    switch reading {
    case .unreadable(let reason):
      return .unreadable(reason)
    case .readable(let entry):
      guard entry.record.currency == settings.defaultCurrency else { return .currencyDiffers(entry.record, account: settings.defaultCurrency) }
      return .present(entry.record)
    case .absent:
      let home = BudgetRecord(id: id, currency: settings.defaultCurrency, period: .monthly, createdOn: today)
      do throws(MemoirRecordError) {
        try home.createKeepingRemoval(in: &transaction)
      } catch {
        throw FinanceError(error)
      }
      return .created(home)
    }
  }

  static func accountLimitMinor(_ settings: AccountSettingsRecord?, currency: CurrencyCode) -> Int64? {
    guard let budget = settings?.effectiveMonthlyBudget, budget.currency == currency else { return nil }
    return budget.amountMinor
  }
}
