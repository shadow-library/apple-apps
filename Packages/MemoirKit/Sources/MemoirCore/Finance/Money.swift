extension MoneyAmount {
  public func adding(_ other: MoneyAmount) throws(FinanceError) -> MoneyAmount {
    guard other.currency == currency else { throw .currencyMismatch(currency, other.currency) }
    return MoneyAmount(amountMinor: try Self.checked(amountMinor.addingReportingOverflow(other.amountMinor)), currency: currency)
  }

  public func subtracting(_ other: MoneyAmount) throws(FinanceError) -> MoneyAmount {
    guard other.currency == currency else { throw .currencyMismatch(currency, other.currency) }
    return MoneyAmount(amountMinor: try Self.checked(amountMinor.subtractingReportingOverflow(other.amountMinor)), currency: currency)
  }

  public func negated() throws(FinanceError) -> MoneyAmount {
    MoneyAmount(amountMinor: try Self.checked((0 as Int64).subtractingReportingOverflow(amountMinor)), currency: currency)
  }

  public static func sum(_ amounts: some Sequence<MoneyAmount>, in currency: CurrencyCode) throws(FinanceError) -> MoneyAmount {
    var total = MoneyAmount(amountMinor: 0, currency: currency)
    for amount in amounts { total = try total.adding(amount) }
    return total
  }

  static func checked(_ result: (partialValue: Int64, overflow: Bool)) throws(FinanceError) -> Int64 {
    guard !result.overflow else { throw .overflow }
    return result.partialValue
  }
}
