import Foundation
import ShadowAI
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Settings input and errors")
struct SettingsInputTests {
  private let english = Locale(identifier: "en_US")
  private let german = Locale(identifier: "de_DE")

  @Test(
    "should parse dollar amounts into exact nano dollars", arguments: [("5", 5_000_000_000), ("2.50", 2_500_000_000), (" 0.0001 ", 100_000), ("1000000", 1_000_000_000_000_000)])
  func shouldParseDollarAmountsIntoExactNanoDollars(text: String, nano: Int64) {
    #expect(SpendCapInput.parse(text, locale: english) == .success(Cost(nanoUSD: nano)))
  }

  @Test("should read the locale's decimal separator")
  func shouldReadTheLocaleDecimalSeparator() {
    #expect(SpendCapInput.parse("2,5", locale: german) == .success(Cost(nanoUSD: 2_500_000_000)))
    #expect(SpendCapInput.parse("2.5", locale: german) == .failure(.invalid))
  }

  @Test("should treat an empty field as no cap")
  func shouldTreatAnEmptyFieldAsNoCap() {
    #expect(SpendCapInput.parse("  ", locale: english) == .success(nil))
    #expect(SpendCapInput.text(for: nil, locale: english).isEmpty)
  }

  @Test(
    "should reject unusable amounts",
    arguments: [
      ("abc", SpendCapIssue.invalid), ("1,000", .invalid), ("-5", .invalid), ("1.23456", .invalid), (".", .invalid), ("0", .notPositive), ("0.00", .notPositive),
      ("1000000.01", .tooLarge), ("99999999999999999999", .tooLarge),
    ])
  func shouldRejectUnusableAmounts(text: String, issue: SpendCapIssue) {
    #expect(SpendCapInput.parse(text, locale: english) == .failure(issue))
  }

  @Test("should round-trip a cap through its text")
  func shouldRoundTripACapThroughItsText() {
    let cost = Cost(nanoUSD: 12_340_000_000)
    #expect(SpendCapInput.text(for: cost, locale: german) == "12,34")
    #expect(SpendCapInput.parse(SpendCapInput.text(for: cost, locale: german), locale: german) == .success(cost))
  }

  @Test("should trim a model identifier and reject one with whitespace or control characters")
  func shouldTrimAModelIdentifierAndRejectWhitespaceOrControlCharacters() {
    #expect(ModelIdentifierInput.parse("  vendor/model:free ") == .success("vendor/model:free"))
    #expect(ModelIdentifierInput.parse("") == .success(nil))
    #expect(ModelIdentifierInput.parse("a b") == .failure(.invalid))
    #expect(ModelIdentifierInput.parse("a\u{0}b") == .failure(.invalid))
    #expect(ModelIdentifierInput.parse(String(repeating: "a", count: 201)) == .failure(.invalid))
  }

  @Test("should give every router error a headline and keep its code as the detail")
  func shouldGiveEveryRouterErrorAHeadlineAndKeepItsCodeAsDetail() {
    let request = AIConsentRequest(provider: .openRouter, host: "openrouter.ai", dataClass: "novel-text", disclosure: "novel-text/v1")
    let cost = Cost(nanoUSD: 5 * Cost.nanoUSDPerUSD)
    let errors: [TaskRouterError] = [
      .noRoute(task: .chat, pace: .steady), .unrestrictedModelMissing, .providerMissing(.anthropic), .credentialMissing(.openRouter), .consentRequired(request),
      .dailySpendLimitReached(spent: cost, limit: cost), .monthlySpendLimitReached(spent: cost, limit: cost), .spendUnavailable, .ledger(.invalidChange("x")),
    ]
    for error in errors {
      let presented = AIErrors.presented(error)
      #expect(!presented.headline.isEmpty)
      #expect(presented.detail == error.code)
      #expect(!presented.headline.contains("routing."))
    }
  }

  @Test("should name the provider and the limit in refusals")
  func shouldNameTheProviderAndTheLimitInRefusals() {
    #expect(AIErrors.headline(for: .credentialMissing(.openRouter)).contains("OpenRouter"))
    #expect(AIErrors.headline(for: .dailySpendLimitReached(spent: .zero, limit: Cost(nanoUSD: 5 * Cost.nanoUSDPerUSD))).contains("5"))
  }
}
