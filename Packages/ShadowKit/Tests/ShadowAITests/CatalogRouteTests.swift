import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCatalog.route")
struct CatalogRouteTests {
  static let catalog: ModelCatalog = {
    var routes = CatalogFixtures.routes(model: "a", effort: .medium)
    routes[.writing]?[.swift] = CatalogRoute(model: "a", effort: .high, maxOutputTokens: 500)
    routes[.chat]?[.swift] = CatalogRoute(model: "plain", effort: nil, maxOutputTokens: 500)
    routes[.review]?[.swift] = CatalogRoute(model: "sparse", effort: .high, maxOutputTokens: 500)
    routes[.review]?[.steady] = CatalogRoute(model: "ghost", effort: .low, maxOutputTokens: 500)
    return CatalogFixtures.catalog(
      models: [
        CatalogFixtures.model("a", efforts: [.low, .medium, .high]), CatalogFixtures.model("plain", efforts: []), CatalogFixtures.model("sparse", efforts: [.low, .high, .max]),
      ],
      routes: routes
    )
  }()

  @Test func shouldReturnTheRouteAsListedWithoutDeeper() {
    #expect(Self.catalog.route(for: .planning, pace: .steady) == CatalogRoute(model: "a", effort: .medium, maxOutputTokens: 500))
  }

  @Test func shouldRaiseEffortOneLevelWhenDeeper() {
    #expect(Self.catalog.route(for: .planning, pace: .steady, deeper: true)?.effort == .high)
  }

  @Test func shouldKeepEffortWhenModelIsAtItsTopLevel() {
    #expect(Self.catalog.route(for: .writing, pace: .swift, deeper: true)?.effort == .high)
  }

  @Test func shouldKeepEffortWhenTheNextLevelIsNotAccepted() {
    #expect(Self.catalog.route(for: .review, pace: .swift, deeper: true)?.effort == .high)
  }

  @Test func shouldStayWithoutEffortWhenTheRouteHasNone() {
    #expect(Self.catalog.route(for: .chat, pace: .swift, deeper: true)?.effort == nil)
  }

  @Test func shouldKeepEffortWhenTheModelIsUnknown() {
    #expect(Self.catalog.route(for: .review, pace: .steady, deeper: true)?.effort == .low)
  }

  @Test func shouldReturnNilForAMissingRoute() {
    var catalog = Self.catalog
    catalog.routes[.helper] = nil
    #expect(catalog.route(for: .helper, pace: .swift) == nil)
    #expect(catalog.route(for: .helper, pace: .swift, deeper: true) == nil)
  }

  @Test func shouldNotChangeOtherFieldsWhenDeeper() {
    let route = Self.catalog.route(for: .planning, pace: .swift, deeper: true)
    #expect(route?.model == "a")
    #expect(route?.maxOutputTokens == 500)
  }
}
