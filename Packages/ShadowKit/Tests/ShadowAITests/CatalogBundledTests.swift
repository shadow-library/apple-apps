import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCatalog.bundled")
struct CatalogBundledTests {
  @Test func shouldHaveNoProblems() {
    #expect(ModelCatalog.bundled.problems() == [])
  }

  @Test func shouldCoverEveryTaskAndPace() {
    for task in ModelTask.allCases {
      for pace in Pace.allCases {
        #expect(ModelCatalog.bundled.route(for: task, pace: pace) != nil, "\(task) at \(pace)")
      }
    }
  }

  @Test func shouldRoundTripThroughEncoded() throws {
    let bundled = ModelCatalog.bundled
    #expect(!bundled.models.isEmpty)
    #expect(try ModelCatalog(decoding: bundled.encoded()) == bundled)
  }

  @Test func shouldUseTheCurrentFormat() {
    #expect(ModelCatalog.bundled.format == ModelCatalog.currentFormat)
  }

  @Test func shouldRaiseEffortWithPaceForEveryTask() throws {
    for task in ModelTask.allCases {
      let efforts = try Pace.allCases.map { try #require(ModelCatalog.bundled.route(for: task, pace: $0)?.effort) }
      #expect(efforts == efforts.sorted(), "\(task)")
    }
  }

  @Test func shouldUseTheSameFastModelForHelperAtEveryPace() {
    let models = Set(Pace.allCases.compactMap { ModelCatalog.bundled.route(for: .helper, pace: $0)?.model })
    #expect(models == ["claude-haiku-5-5"])
  }

  @Test func shouldPriceOneMillionInputTokensAtTheListedPrice() throws {
    let sonnet = try #require(ModelCatalog.bundled.model("claude-sonnet-5-5"))
    #expect(ModelCatalog.bundled.cost(of: TokenUsage(input: 1_000_000), model: sonnet.id) == Cost(nanoUSD: 2_000_000_000))
    #expect(ModelCatalog.bundled.cost(of: TokenUsage(cacheRead: 1_000_000), model: sonnet.id) == Cost(nanoUSD: 100_000_000))
  }

  @Test func shouldReadBundledJSONWithoutRetiredModelsInRoutes() {
    let resolution = ModelCatalog.bundled.resolved(available: nil, on: CatalogFixtures.date("2026-11-16"))
    #expect(resolution.notices == [])
    #expect(resolution.catalog == ModelCatalog.bundled)
  }

  @Test func shouldPriceHaikuByPromptLength() throws {
    let haiku = try #require(ModelCatalog.bundled.model("claude-haiku-5-5"))
    #expect(haiku.longPrompt?.aboveTokens == 100_000)
    #expect(ModelCatalog.bundled.cost(of: TokenUsage(input: 100_000), model: haiku.id) == Cost(nanoUSD: 10_000_000))
    #expect(ModelCatalog.bundled.cost(of: TokenUsage(input: 100_001), model: haiku.id) == Cost(nanoUSD: 50_000_500))
    #expect(ModelCatalog.bundled.cost(of: TokenUsage(output: 1_000_000), model: haiku.id) == Cost(nanoUSD: 500_000_000))
  }

  @Test func shouldNotBundleMythosModels() {
    #expect(ModelCatalog.bundled.models.allSatisfy { !$0.id.contains("mythos") && !$0.successors.contains { $0.contains("mythos") } })
  }

  @Test func shouldRoundTripATierThroughJSON() throws {
    var catalog = ModelCatalog.bundled
    #expect(try ModelCatalog(decoding: catalog.encoded()).model("claude-haiku-5-5")?.longPrompt != nil)
    catalog.models = catalog.models.map {
      var model = $0
      model.longPrompt = nil
      return model
    }
    let decoded = try ModelCatalog(decoding: catalog.encoded())
    #expect(decoded == catalog)
    #expect(!String(decoding: catalog.encoded(), as: UTF8.self).contains("longPrompt"))
  }

  static let expectedModelIDs: Set<String> = [
    "claude-fable-5-2", "claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
    "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5-5", "claude-haiku-4-5",
  ]

  static func components(_ pricing: ModelPricing) -> [Int64] {
    [pricing.input, pricing.output, pricing.cacheRead, pricing.cacheWriteShort, pricing.cacheWriteLong].map(\.nanoUSD)
  }

  @Test func shouldPinTheExactSetOfModelIDs() {
    let ids = ModelCatalog.bundled.models.map(\.id)
    #expect(Set(ids) == Self.expectedModelIDs)
    #expect(ids.count == Self.expectedModelIDs.count)
  }

  @Test func shouldOrderEveryModelsPricesAsTheProviderDoes() {
    for model in ModelCatalog.bundled.models {
      let price = model.pricing
      #expect(Self.components(price).allSatisfy { $0 > 0 }, "\(model.id) has a non-positive price")
      #expect(price.cacheRead < price.input, "\(model.id) cache read")
      #expect(price.input < price.cacheWriteShort, "\(model.id) short write")
      #expect(price.cacheWriteShort < price.cacheWriteLong, "\(model.id) long write")
      #expect(price.input < price.output, "\(model.id) output")
    }
  }

  @Test func shouldPriceEveryLongPromptTierAboveItsBase() {
    for model in ModelCatalog.bundled.models {
      guard let longPrompt = model.longPrompt else { continue }
      #expect(longPrompt.aboveTokens >= 1, "\(model.id) threshold")
      for (long, base) in zip(Self.components(longPrompt.pricing), Self.components(model.pricing)) {
        #expect(long > base, "\(model.id) long-prompt price")
      }
    }
  }

  @Test func shouldPinWhichModelsHaveATierAndWhichSupportJSONSchema() {
    let tiered = ModelCatalog.bundled.models.filter { $0.longPrompt != nil }.map(\.id)
    #expect(tiered == ["claude-haiku-5-5"])
    let schema = Set(ModelCatalog.bundled.models.filter(\.supportsJSONSchema).map(\.id))
    #expect(schema == Self.expectedModelIDs.subtracting(["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6"]))
  }
}
