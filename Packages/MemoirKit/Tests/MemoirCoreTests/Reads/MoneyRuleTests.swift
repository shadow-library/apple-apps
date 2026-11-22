import Foundation
import Testing

@testable import MemoirCore

@Suite("Money rules", TestTimeLimit.quick)
struct MoneyRuleTests {
  private static let english = AmountFormat(decimalSeparator: ".", groupingSeparator: ",")
  private static let german = AmountFormat(decimalSeparator: ",", groupingSeparator: ".")

  private static func parse(_ text: String, _ currency: String, _ format: AmountFormat = english) throws(AmountInputRefusal) -> Int64 {
    try AmountInput.minorUnits(text, currency: MoneyReadsFixture.currency(currency), format: format)
  }

  @Test func shouldReadAmountsWithTheLocalesSeparatorsAndTheCurrencysExponent() throws {
    #expect(try Self.parse("12.50", "EUR") == 1250)
    #expect(try Self.parse("1,234.56", "USD") == 123_456)
    #expect(try Self.parse("1.234,56", "EUR", Self.german) == 123_456)
    #expect(try Self.parse("  7 ", "EUR") == 700)
    #expect(try Self.parse(".5", "EUR") == 50)
    #expect(try Self.parse("5.", "EUR") == 500)
    #expect(try Self.parse("1,00,000", "INR") == 10_000_000, "Indian grouping: two digits between the earlier separators")
    #expect(try Self.parse("1 234,5", "EUR", AmountFormat(decimalSeparator: ",", groupingSeparator: "\u{202F}")) == 123_450, "a typed space stands for French grouping")
    #expect(try Self.parse("1'234.50", "CHF", AmountFormat(decimalSeparator: ".", groupingSeparator: "\u{2019}")) == 123_450)
    #expect(try Self.parse("\u{0661}\u{0662}", "EUR") == 1200, "decimal digits of other scripts read as digits")
  }

  @Test func shouldApplyIsoExponentsZeroAndThree() throws {
    #expect(try Self.parse("1,234", "JPY") == 1234)
    #expect(try Self.parse("12.00", "JPY") == 12, "zeros past the exponent are exact")
    #expect(throws: AmountInputRefusal.tooPrecise(allowedPlaces: 0)) { try Self.parse("12.5", "JPY") }
    #expect(try Self.parse("1.234", "KWD") == 1234, "three decimal places: one dinar and 234 fils")
    #expect(try Self.parse("1.5", "KWD") == 1500)
    #expect(throws: AmountInputRefusal.tooPrecise(allowedPlaces: 3)) { try Self.parse("1.2345", "KWD") }
    #expect(throws: AmountInputRefusal.tooPrecise(allowedPlaces: 2)) { try Self.parse("1.234", "USD") }
  }

  /// memoir-web `parseAmountToMinor` (`lib/data/finance.rules.ts:61-81`) reads `1.234` as 1234 and `12abc34` as 1234 by stripping and guessing; the
  /// native reader refuses what it would have to guess.
  @Test func shouldRefuseWhatTheWebWouldGuessWithATypedReason() {
    #expect(throws: AmountInputRefusal.empty) { try Self.parse("", "EUR") }
    #expect(throws: AmountInputRefusal.empty) { try Self.parse(" . ", "EUR") }
    #expect(throws: AmountInputRefusal.negative) { try Self.parse("-5", "EUR") }
    #expect(throws: AmountInputRefusal.negative) { try Self.parse("\u{2212}5", "EUR") }
    #expect(throws: AmountInputRefusal.unexpectedCharacter("a")) { try Self.parse("12abc34", "EUR") }
    #expect(throws: AmountInputRefusal.unexpectedCharacter("+")) { try Self.parse("+5", "EUR") }
    #expect(throws: AmountInputRefusal.unexpectedCharacter(" ")) { try Self.parse("1 234", "EUR") }
    #expect(throws: AmountInputRefusal.repeatedDecimalSeparator) { try Self.parse("1.2.3", "EUR") }
    #expect(throws: AmountInputRefusal.misplacedGrouping) { try Self.parse("1,5", "EUR") }
    #expect(throws: AmountInputRefusal.misplacedGrouping) { try Self.parse("12.5", "EUR", Self.german) }
    #expect(throws: AmountInputRefusal.misplacedGrouping) { try Self.parse("1,000.5,0", "EUR") }
    #expect(throws: AmountInputRefusal.misplacedGrouping) { try Self.parse(",500", "EUR") }
    #expect(throws: AmountInputRefusal.misplacedGrouping) { try Self.parse("1,000,", "EUR") }
    #expect(throws: AmountInputRefusal.outOfRange) { try Self.parse("92233720368547758.08", "EUR") }
    #expect(throws: AmountInputRefusal.unknownCurrency(MoneyReadsFixture.currency("XAU"))) { try Self.parse("1", "XAU") }
    #expect(throws: Never.self) { try Self.parse("92233720368547758.07", "EUR") }
  }

  @Test func shouldTakeTheSeparatorsFromALocale() throws {
    let german = AmountFormat(locale: Locale(identifier: "de_DE"))
    #expect(german.decimalSeparator == ",")
    #expect(try Self.parse("1.234,56", "EUR", german) == 123_456)
    #expect(try Self.parse("1,234.56", "USD", AmountFormat(locale: Locale(identifier: "en_US"))) == 123_456)
  }

  /// `financePeriod` and `previousStretch` (`finance.rules.ts:226-243`).
  @Test func shouldPortTheFinancePeriodsAndPreviousStretches() {
    let today = MoneyReadsFixture.date("2026-03-31")
    #expect(FinanceRange.week.period(containing: today) == DateSpan(start: MoneyReadsFixture.date("2026-03-30"), end: MoneyReadsFixture.date("2026-04-05")))
    #expect(FinanceRange.month.period(containing: today) == DateSpan(start: MoneyReadsFixture.date("2026-03-01"), end: MoneyReadsFixture.date("2026-03-31")))
    #expect(FinanceRange.year.period(containing: today) == DateSpan(start: MoneyReadsFixture.date("2026-01-01"), end: MoneyReadsFixture.date("2026-12-31")))
    #expect(FinanceRange.month.previousStretch(before: today) == DateSpan(start: MoneyReadsFixture.date("2026-02-01"), end: MoneyReadsFixture.date("2026-02-28")))
    #expect(FinanceRange.week.previousStretch(before: today) == DateSpan(start: MoneyReadsFixture.date("2026-03-23"), end: MoneyReadsFixture.date("2026-03-24")))
    #expect(
      FinanceRange.year.previousStretch(before: MoneyReadsFixture.date("2028-02-29"))
        == DateSpan(start: MoneyReadsFixture.date("2027-01-01"), end: MoneyReadsFixture.date("2027-02-28")))
    #expect(
      FinanceRange.month.previousStretch(before: MoneyReadsFixture.date("2026-01-14"))
        == DateSpan(start: MoneyReadsFixture.date("2025-12-01"), end: MoneyReadsFixture.date("2025-12-14")))
    #expect(FinanceRange.week.period(containing: MoneyReadsFixture.date("2026-03-29"))?.start == MoneyReadsFixture.date("2026-03-23"), "a Sunday belongs to the week before")
  }

  /// `spendDelta` (`finance.rules.ts:249-252`).
  @Test func shouldGiveNoDeltaWithoutEarlierSpending() {
    #expect(SpendDelta.fraction(current: 500, previous: 0) == nil)
    #expect(SpendDelta.fraction(current: 150, previous: 100) == Fraction(numerator: 1, denominator: 2))
    #expect(SpendDelta.fraction(current: 50, previous: 100) == Fraction(numerator: -1, denominator: 2))
  }

  /// `deriveDueState` with `REMINDER_LEAD_DAYS` (`finance.rules.ts:31-37,133-149`).
  @Test func shouldDeriveTheDueStateWithTheReminderWindow() {
    #expect(SubscriptionStanding.dueState(active: false, confirmed: false, daysUntilDue: -3, window: 7) == SubscriptionDueState.none)
    #expect(SubscriptionStanding.dueState(active: true, confirmed: true, daysUntilDue: -3, window: 7) == SubscriptionDueState.none)
    #expect(SubscriptionStanding.dueState(active: true, confirmed: false, daysUntilDue: -1, window: 7) == .overdue)
    #expect(SubscriptionStanding.dueState(active: true, confirmed: false, daysUntilDue: 0, window: 0) == .due)
    #expect(SubscriptionStanding.dueState(active: true, confirmed: false, daysUntilDue: 7, window: 7) == .upcoming)
    #expect(SubscriptionStanding.dueState(active: true, confirmed: false, daysUntilDue: 8, window: 7) == SubscriptionDueState.none)
    #expect(SubscriptionStanding.dueState(active: true, confirmed: false, daysUntilDue: 2, window: 1) == SubscriptionDueState.none)
    #expect(SubscriptionReminderLead.allCases.map(\.days) == [0, 1, 2, 3, 7])
  }

  /// `expenseChanges` (`finance.rules.ts:357-367`): only the owner-visible fields that moved, an empty text being no text.
  @Test func shouldDiffAnExpenseEdit() {
    let before = MoneyReadsFixture.expense(1, 1250, "EUR", on: "2026-11-20", merchant: "Café", note: "")
    var after = before
    after.amountMinor = 1500
    after.note = "lunch"
    after.merchant = ""
    after.occurredOn = MoneyReadsFixture.date("2026-11-19")
    #expect(
      ExpenseFieldChange.changes(from: before, to: after) == [
        .amount(from: 1250, to: 1500), .occurredOn(from: MoneyReadsFixture.date("2026-11-20"), to: MoneyReadsFixture.date("2026-11-19")), .note(from: nil, to: "lunch"),
        .merchant(from: "Café", to: nil),
      ])
    var blank = before
    blank.note = nil
    #expect(ExpenseFieldChange.changes(from: before, to: blank).isEmpty, "an empty note and no note are the same")
    for change in ExpenseFieldChange.changes(from: before, to: after) { #expect(ExpenseFieldChange(stored: change.stored) == change) }
  }
}
