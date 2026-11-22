import Foundation
import MemoirCore
import Testing

@testable import Memoir

@MainActor
@Suite("MoneyText", TestTimeLimit.quick)
struct MoneyFormatTests {
  @Test("should format minor units exactly with each currency's places in the owner's locale")
  func formatsExactly() {
    #expect(MoneyText.formatted(1840, MoneyFixture.yen, locale: MoneyFixture.english) == "¥1,840")
    #expect(MoneyText.formatted(1234, MoneyFixture.dinar, locale: MoneyFixture.english).contains("1.234"))
    #expect(MoneyText.formatted(1840, MoneyFixture.euro, locale: MoneyFixture.german) == "18,40\u{a0}€")
    #expect(MoneyText.formatted(Int64.max, MoneyFixture.euro, locale: MoneyFixture.english) == "€92,233,720,368,547,758.07")
    #expect(MoneyText.formatted(-5, MoneyFixture.euro, locale: MoneyFixture.english) == "-€0.05")
  }

  @Test("should show a saved amount so the amount field reads it back exactly")
  func roundTripsEditableAmounts() throws {
    let cases: [(Int64, CurrencyCode, Locale, String)] = [
      (5, MoneyFixture.euro, MoneyFixture.english, "0.05"),
      (123_450, MoneyFixture.euro, MoneyFixture.german, "1234,50"),
      (1840, MoneyFixture.yen, MoneyFixture.english, "1840"),
      (1234, MoneyFixture.dinar, MoneyFixture.english, "1.234"),
    ]
    for (minor, currency, locale, text) in cases {
      let format = AmountFormat(locale: locale)
      #expect(MoneyText.editable(minor, currency, format: format) == text)
      #expect(try AmountInput.minorUnits(text, currency: currency, format: format) == minor)
    }
  }

  @Test("should show a rate's exact digits with the locale's decimal separator")
  func formatsRates() throws {
    #expect(MoneyText.rate(try #require(DecimalText("0.0862")), locale: MoneyFixture.german) == "0,0862")
    #expect(MoneyText.rate(try #require(DecimalText("1234.12345678")), locale: MoneyFixture.english) == "1234.12345678")
  }

  @Test("should round a change to a whole percentage, halves up")
  func roundsPercentages() throws {
    #expect(MoneyText.percent(try #require(Fraction(numerator: 1, denominator: 200))) == 1)
    #expect(MoneyText.percent(try #require(Fraction(numerator: -1, denominator: 3))) == 33)
    #expect(MoneyText.percent(try #require(Fraction(numerator: 1, denominator: 201))) == 0)
  }

  @Test("should show a civil date as that day whatever the device's zone")
  func showsCivilDates() throws {
    let day = try #require(LocalDate(isoString: "2026-03-02"))
    #expect(MoneyDates.text(day, locale: MoneyFixture.english) == "Mar 2, 2026")
    #expect(MoneyDates.localDate(MoneyDates.pickerDate(day)) == day)
  }
}
