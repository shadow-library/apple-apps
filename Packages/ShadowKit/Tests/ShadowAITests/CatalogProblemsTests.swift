import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCatalog.problems")
struct CatalogProblemsTests {
  struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    let catalog: ModelCatalog
    let expected: [String]
    var testDescription: String { name }
  }

  static func without(_ task: ModelTask, _ pace: Pace, in catalog: ModelCatalog) -> ModelCatalog {
    var copy = catalog
    copy.routes[task]?[pace] = nil
    return copy
  }

  static func replacing(_ task: ModelTask, _ pace: Pace, with route: CatalogRoute, in catalog: ModelCatalog) -> ModelCatalog {
    var copy = catalog
    copy.routes[task]?[pace] = route
    return copy
  }

  static func tier(aboveTokens: Int, _ change: (inout ModelPricing) -> Void = { _ in }) -> ModelCatalog {
    var pricing = CatalogFixtures.flatPricing
    change(&pricing)
    var model = CatalogFixtures.model("a")
    model.longPrompt = CatalogLongPromptPricing(aboveTokens: aboveTokens, pricing: pricing)
    return CatalogFixtures.catalog(models: [model], routes: CatalogFixtures.routes(model: "a"))
  }

  static let valid = CatalogFixtures.catalog(models: [CatalogFixtures.model("a", successors: ["b"]), CatalogFixtures.model("b")], routes: CatalogFixtures.routes(model: "a"))

  static let negative = ModelPricing(
    input: Cost(nanoUSD: -1),
    output: CatalogFixtures.flatPricing.output,
    cacheRead: CatalogFixtures.flatPricing.cacheRead,
    cacheWriteShort: CatalogFixtures.flatPricing.cacheWriteShort,
    cacheWriteLong: CatalogFixtures.flatPricing.cacheWriteLong
  )

  static let cases: [Case] = [
    Case(name: "valid", catalog: valid, expected: []),
    Case(name: "missing route", catalog: without(.review, .steady, in: valid), expected: ["The review task has no route for the steady pace."]),
    Case(
      name: "unknown model",
      catalog: replacing(.chat, .swift, with: CatalogRoute(model: "zzz", effort: nil, maxOutputTokens: 10), in: valid),
      expected: ["The chat route at the swift pace uses zzz, which is not in the catalog."]
    ),
    Case(
      name: "unaccepted effort",
      catalog: replacing(.chat, .swift, with: CatalogRoute(model: "a", effort: .max, maxOutputTokens: 10), in: valid),
      expected: ["The chat route at the swift pace asks for max effort, which a does not accept."]
    ),
    Case(
      name: "effort on a model without efforts",
      catalog: CatalogFixtures.catalog(models: [CatalogFixtures.model("a", efforts: [])], routes: CatalogFixtures.routes(model: "a", effort: .low)),
      expected: ModelTask.allCases.flatMap { task in Pace.allCases.map { "The \(task.rawValue) route at the \($0.rawValue) pace asks for low effort, which a does not accept." } }
    ),
    Case(
      name: "cap above the model limit",
      catalog: replacing(.writing, .meticulous, with: CatalogRoute(model: "a", effort: .low, maxOutputTokens: 1_001), in: valid),
      expected: ["The writing route at the meticulous pace has an output cap of 1001, above the 1000 that a allows."]
    ),
    Case(
      name: "cap below one",
      catalog: replacing(.helper, .swift, with: CatalogRoute(model: "a", effort: .low, maxOutputTokens: 0), in: valid),
      expected: ["The helper route at the swift pace has an output cap below 1."]
    ),
    Case(
      name: "successor missing",
      catalog: CatalogFixtures.catalog(models: [CatalogFixtures.model("a", successors: ["ghost"])], routes: CatalogFixtures.routes(model: "a")),
      expected: ["The model a names ghost as a successor, but ghost is not in the catalog."]
    ),
    Case(
      name: "successor cycle",
      catalog: CatalogFixtures.catalog(
        models: [
          CatalogFixtures.model("a", successors: ["b"]), CatalogFixtures.model("b", successors: ["c"]), CatalogFixtures.model("c", successors: ["b"]),
          CatalogFixtures.model("d", successors: ["a"]),
        ], routes: CatalogFixtures.routes(model: "a")),
      expected: ["The model b is part of a successor cycle.", "The model c is part of a successor cycle."]
    ),
    Case(
      name: "self successor",
      catalog: CatalogFixtures.catalog(models: [CatalogFixtures.model("a", successors: ["a"])], routes: CatalogFixtures.routes(model: "a")),
      expected: ["The model a is part of a successor cycle."]
    ),
    Case(
      name: "negative price",
      catalog: CatalogFixtures.catalog(models: [CatalogFixtures.model("a", pricing: negative)], routes: CatalogFixtures.routes(model: "a")),
      expected: ["The model a has a negative input price."]
    ),
    Case(name: "long prompt threshold below one", catalog: tier(aboveTokens: 0), expected: ["The model a has a long-prompt threshold below 1."]),
    Case(
      name: "negative long prompt price",
      catalog: tier(aboveTokens: 10) { $0.output = Cost(nanoUSD: -1) },
      expected: ["The model a has a negative long-prompt output price."]
    ),
    Case(
      name: "long prompt price below base",
      catalog: tier(aboveTokens: 10) { $0.cacheRead = Cost(nanoUSD: 1) },
      expected: ["The model a has a long-prompt cache read price below its base price, which is suspicious."]
    ),
    Case(name: "valid long prompt tier", catalog: tier(aboveTokens: 10) { $0.input = Cost(nanoUSD: 9_000_000_000) }, expected: []),
    Case(
      name: "duplicate model",
      catalog: CatalogFixtures.catalog(models: [CatalogFixtures.model("a"), CatalogFixtures.model("a")], routes: CatalogFixtures.routes(model: "a")),
      expected: ["The model a is listed more than once."]
    ),
  ]

  @Test(arguments: cases)
  func shouldReportExactlyTheBrokenRule(_ item: Case) {
    #expect(item.catalog.problems() == item.expected)
  }

  @Test func shouldReportEveryMissingRouteForAnEmptyCatalog() {
    #expect(ModelCatalog(revision: 0, models: [], routes: [:]).problems().count == ModelTask.allCases.count * Pace.allCases.count)
  }
}
