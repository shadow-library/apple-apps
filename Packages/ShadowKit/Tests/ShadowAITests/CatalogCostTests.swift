import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCatalog.cost")
struct CatalogCostTests {
  static let catalog = CatalogFixtures.catalog(models: [CatalogFixtures.model("a")])

  struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    let usage: TokenUsage
    let nanoUSD: Int64
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "zero usage", usage: .zero, nanoUSD: 0),
    Case(name: "one million input", usage: TokenUsage(input: 1_000_000), nanoUSD: 3_000_000_000),
    Case(name: "one million output", usage: TokenUsage(output: 1_000_000), nanoUSD: 15_000_000_000),
    Case(name: "one million cache read", usage: TokenUsage(cacheRead: 1_000_000), nanoUSD: 300_000_000),
    Case(name: "one million short cache write", usage: TokenUsage(cacheWriteShort: 1_000_000), nanoUSD: 3_750_000_000),
    Case(name: "one million long cache write", usage: TokenUsage(cacheWriteLong: 1_000_000), nanoUSD: 6_000_000_000),
    Case(name: "one token of input", usage: TokenUsage(input: 1), nanoUSD: 3_000),
    Case(
      name: "mixed", usage: TokenUsage(input: 1_234, output: 567, cacheRead: 89_000, cacheWriteShort: 4_000, cacheWriteLong: 250_000),
      nanoUSD: 3_702_000 + 8_505_000 + 26_700_000 + 15_000_000 + 1_500_000_000),
    Case(name: "negative counts are zero", usage: TokenUsage(input: -5, output: -1_000_000, cacheRead: Int.min, cacheWriteShort: -1, cacheWriteLong: -1), nanoUSD: 0),
    Case(name: "negative offsets nothing", usage: TokenUsage(input: -1_000_000, output: 1_000_000), nanoUSD: 15_000_000_000),
  ]

  @Test(arguments: cases)
  func shouldComputeNanoUSD(_ item: Case) {
    #expect(Self.catalog.cost(of: item.usage, model: "a") == Cost(nanoUSD: item.nanoUSD))
  }

  @Test(arguments: [
    (1, 1, Int64(0)),
    (499_999, 1, Int64(0)),
    (500_000, 1, Int64(1)),
    (500_001, 1, Int64(1)),
    (1_499_999, 1, Int64(1)),
    (1_500_000, 1, Int64(2)),
    (3, 166_666, Int64(0)),
    (3, 166_667, Int64(1)),
  ])
  func shouldRoundHalfUp(tokens: Int, priceNano: Int64, expected: Int64) {
    var pricing = CatalogFixtures.flatPricing
    pricing.input = Cost(nanoUSD: priceNano)
    let catalog = CatalogFixtures.catalog(models: [CatalogFixtures.model("p", pricing: pricing)])
    #expect(catalog.cost(of: TokenUsage(input: tokens), model: "p") == Cost(nanoUSD: expected))
  }

  @Test func shouldRoundEachComponentBeforeSumming() {
    var pricing = CatalogFixtures.flatPricing
    pricing.input = Cost(nanoUSD: 1)
    pricing.output = Cost(nanoUSD: 1)
    let catalog = CatalogFixtures.catalog(models: [CatalogFixtures.model("p", pricing: pricing)])
    #expect(catalog.cost(of: TokenUsage(input: 500_000, output: 500_000), model: "p") == Cost(nanoUSD: 2))
  }

  @Test func shouldReturnNilForAnUnknownModel() {
    #expect(Self.catalog.cost(of: TokenUsage(input: 1), model: "nope") == nil)
  }

  @Test func shouldSaturateInsteadOfTrappingAtIntMax() {
    let usage = TokenUsage(input: .max, output: .max, cacheRead: .max, cacheWriteShort: .max, cacheWriteLong: .max)
    #expect(Self.catalog.cost(of: usage, model: "a") == Cost(nanoUSD: .max))
  }

  @Test func shouldComputeLargeCountsExactlyWhenTheyFit() {
    let tokens = 1_000_000_000_000
    #expect(Self.catalog.cost(of: TokenUsage(input: tokens), model: "a") == Cost(nanoUSD: 3_000_000_000_000_000))
  }

  @Test func shouldTreatNegativePricesAsZero() {
    var pricing = CatalogFixtures.flatPricing
    pricing.input = Cost(nanoUSD: -3_000_000_000)
    let catalog = CatalogFixtures.catalog(models: [CatalogFixtures.model("p", pricing: pricing)])
    #expect(catalog.cost(of: TokenUsage(input: 1_000_000), model: "p") == Cost(nanoUSD: 0))
  }

  static let tiered: ModelCatalog = {
    var long = CatalogFixtures.flatPricing
    long.input = Cost(nanoUSD: 6_000_000_000)
    long.output = Cost(nanoUSD: 30_000_000_000)
    long.cacheRead = Cost(nanoUSD: 600_000_000)
    long.cacheWriteShort = Cost(nanoUSD: 7_500_000_000)
    long.cacheWriteLong = Cost(nanoUSD: 12_000_000_000)
    var model = CatalogFixtures.model("t")
    model.longPrompt = CatalogLongPromptPricing(aboveTokens: 100_000, pricing: long)
    return CatalogFixtures.catalog(models: [model])
  }()

  @Test func shouldUseBasePricesAtAndBelowTheThreshold() {
    #expect(Self.tiered.cost(of: TokenUsage(input: 99_999, output: 1_000), model: "t") == Cost(nanoUSD: 99_999 * 3_000 + 1_000 * 15_000))
    #expect(Self.tiered.cost(of: TokenUsage(input: 100_000, output: 1_000), model: "t") == Cost(nanoUSD: 100_000 * 3_000 + 1_000 * 15_000))
  }

  @Test func shouldRepriceTheWholeRequestAboveTheThreshold() {
    let usage = TokenUsage(input: 100_001, output: 1_000)
    #expect(Self.tiered.cost(of: usage, model: "t") == Cost(nanoUSD: 100_001 * 6_000 + 1_000 * 30_000))
  }

  @Test func shouldCountCacheReadsAndWritesTowardsThePromptLength() {
    let usage = TokenUsage(input: 10, output: 0, cacheRead: 60_000, cacheWriteShort: 20_000, cacheWriteLong: 20_000)
    #expect(Self.tiered.cost(of: usage, model: "t") == Cost(nanoUSD: 10 * 6_000 + 60_000 * 600 + 20_000 * 7_500 + 20_000 * 12_000))
  }

  @Test func shouldNotCountOutputTowardsThePromptLength() {
    let usage = TokenUsage(input: 100_000, output: 500_000)
    #expect(Self.tiered.cost(of: usage, model: "t") == Cost(nanoUSD: 100_000 * 3_000 + 500_000 * 15_000))
  }

  @Test func shouldLeaveAModelWithoutATierUnchanged() {
    #expect(Self.catalog.cost(of: TokenUsage(input: 5_000_000), model: "a") == Cost(nanoUSD: 15_000_000_000))
  }

  @Test func shouldSaturateTheLongPromptLengthInsteadOfTrapping() {
    #expect(Self.tiered.cost(of: TokenUsage(input: .max, cacheRead: .max), model: "t") == Cost(nanoUSD: .max))
  }
}
