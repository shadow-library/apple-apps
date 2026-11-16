import Foundation

@testable import ShadowAI

enum CatalogFixtures {
  static let flatPricing = ModelPricing(
    input: Cost(nanoUSD: 3_000_000_000),
    output: Cost(nanoUSD: 15_000_000_000),
    cacheRead: Cost(nanoUSD: 300_000_000),
    cacheWriteShort: Cost(nanoUSD: 3_750_000_000),
    cacheWriteLong: Cost(nanoUSD: 6_000_000_000)
  )

  static func date(_ text: String) -> CatalogDate {
    guard let date = CatalogDate(text) else { preconditionFailure("Bad fixture date \(text)") }
    return date
  }

  static func model(
    _ id: String,
    efforts: [Effort] = [.low, .medium, .high],
    maxOutput: Int = 1_000,
    pricing: ModelPricing = flatPricing,
    retiresOn: String? = nil,
    successors: [String] = []
  ) -> CatalogModel {
    CatalogModel(
      id: id,
      contextTokens: 100_000,
      maxOutputTokens: maxOutput,
      efforts: efforts,
      supportsJSONSchema: true,
      pricing: pricing,
      retiresOn: retiresOn.map(date),
      successors: successors
    )
  }

  static func routes(model: String, effort: Effort? = .medium, maxOutput: Int = 500) -> [ModelTask: [Pace: CatalogRoute]] {
    Dictionary(
      uniqueKeysWithValues: ModelTask.allCases.map { task in
        (task, Dictionary(uniqueKeysWithValues: Pace.allCases.map { ($0, CatalogRoute(model: model, effort: effort, maxOutputTokens: maxOutput)) }))
      }
    )
  }

  static func catalog(models: [CatalogModel], routes: [ModelTask: [Pace: CatalogRoute]]? = nil) -> ModelCatalog {
    ModelCatalog(revision: 1, models: models, routes: routes ?? self.routes(model: models.first?.id ?? "a"))
  }
}
