import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCatalog.resolved")
struct CatalogResolutionTests {
  static let today = CatalogFixtures.date("2026-11-16")
  static let future = "2027-06-01"
  static let past = "2026-11-15"

  static func catalog(_ models: [CatalogModel], routedTo id: String = "a", effort: Effort? = .high, maxOutput: Int = 900) -> ModelCatalog {
    CatalogFixtures.catalog(models: models, routes: CatalogFixtures.routes(model: id, effort: effort, maxOutput: maxOutput))
  }

  @Test func shouldReplaceARetiredModelWithAnAvailableSuccessor() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b")])
    let resolution = catalog.resolved(available: ["a", "b"], on: Self.today)
    #expect(resolution.notices == [.replaced(model: "a", by: "b")])
    #expect(resolution.catalog.routes.values.flatMap(\.values).allSatisfy { $0.model == "b" })
    #expect(resolution.catalog.models == catalog.models)
  }

  @Test func shouldNotTreatTheRetirementDayItselfAsRetired() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: "2026-11-16", successors: ["b"]), CatalogFixtures.model("b")])
    #expect(catalog.resolved(available: nil, on: Self.today).notices == [.retiringSoon(model: "a", on: Self.today, daysLeft: 0)])
  }

  @Test func shouldFollowAChainOfTwoSuccessors() {
    let catalog = Self.catalog([
      CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]),
      CatalogFixtures.model("b", retiresOn: Self.past, successors: ["c"]),
      CatalogFixtures.model("c"),
    ])
    let resolution = catalog.resolved(available: nil, on: Self.today)
    #expect(resolution.notices == [.replaced(model: "a", by: "c")])
    #expect(resolution.catalog.route(for: .chat, pace: .swift)?.model == "c")
  }

  @Test func shouldSkipASuccessorThatIsRetiredOrUnavailable() {
    let catalog = Self.catalog([
      CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b", "c", "d"]),
      CatalogFixtures.model("b", retiresOn: Self.past),
      CatalogFixtures.model("c"),
      CatalogFixtures.model("d"),
    ])
    #expect(catalog.resolved(available: ["d"], on: Self.today).notices == [.replaced(model: "a", by: "d")])
  }

  @Test func shouldPreferTheFirstSuccessorOverTheChainOfALaterOne() {
    let catalog = Self.catalog([
      CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b", "d"]),
      CatalogFixtures.model("b", retiresOn: Self.past, successors: ["c"]),
      CatalogFixtures.model("c"),
      CatalogFixtures.model("d"),
    ])
    #expect(catalog.resolved(available: nil, on: Self.today).notices == [.replaced(model: "a", by: "c")])
  }

  @Test func shouldKeepTheRouteAndReportUnavailableWhenNoSuccessorWorks() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", retiresOn: Self.past)])
    let resolution = catalog.resolved(available: nil, on: Self.today)
    #expect(resolution.notices == [.unavailable(model: "a")])
    #expect(resolution.catalog.routes == catalog.routes)
  }

  @Test func shouldReplaceAModelMissingFromTheProviderList() {
    let catalog = Self.catalog([CatalogFixtures.model("a", successors: ["b"]), CatalogFixtures.model("b")])
    let resolution = catalog.resolved(available: ["b"], on: Self.today)
    #expect(resolution.notices == [.replaced(model: "a", by: "b")])
  }

  @Test func shouldReportUnavailableWhenTheSuccessorIsMissingFromTheProviderList() {
    let catalog = Self.catalog([CatalogFixtures.model("a", successors: ["b"]), CatalogFixtures.model("b")])
    #expect(catalog.resolved(available: ["zzz"], on: Self.today).notices == [.unavailable(model: "a")])
  }

  @Test func shouldTrustEveryModelWhenNoProviderListIsKnown() {
    let catalog = Self.catalog([CatalogFixtures.model("a", successors: ["b"]), CatalogFixtures.model("b")])
    let resolution = catalog.resolved(available: nil, on: Self.today)
    #expect(resolution.notices == [])
    #expect(resolution.catalog == catalog)
  }

  @Test func shouldTreatAnEmptyProviderListAsNothingAvailable() {
    let catalog = Self.catalog([CatalogFixtures.model("a")])
    #expect(catalog.resolved(available: [], on: Self.today).notices == [.unavailable(model: "a")])
  }

  @Test func shouldReportAModelThatIsNotInTheCatalogAsUnavailable() {
    let catalog = CatalogFixtures.catalog(models: [CatalogFixtures.model("a")], routes: CatalogFixtures.routes(model: "ghost"))
    #expect(catalog.resolved(available: nil, on: Self.today).notices == [.unavailable(model: "ghost")])
  }

  @Test func shouldSurviveASuccessorCycle() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", retiresOn: Self.past, successors: ["a"])])
    #expect(catalog.resolved(available: nil, on: Self.today).notices == [.unavailable(model: "a")])
  }

  @Test func shouldKeepAnAcceptedEffortAndCapOnTheReplacement() {
    let catalog = Self.catalog(
      [CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", efforts: [.low, .medium, .high], maxOutput: 2_000)],
      effort: .medium,
      maxOutput: 900
    )
    #expect(catalog.resolved(available: nil, on: Self.today).catalog.route(for: .writing, pace: .steady) == CatalogRoute(model: "b", effort: .medium, maxOutputTokens: 900))
  }

  @Test func shouldLowerTheCapAndMoveEffortToTheNearestAcceptedLevel() {
    let catalog = Self.catalog(
      [CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", efforts: [.low, .max], maxOutput: 400)],
      effort: .high,
      maxOutput: 900
    )
    #expect(catalog.resolved(available: nil, on: Self.today).catalog.route(for: .writing, pace: .steady) == CatalogRoute(model: "b", effort: .low, maxOutputTokens: 400))
  }

  @Test func shouldDropEffortWhenTheReplacementAcceptsNone() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", efforts: [])])
    #expect(catalog.resolved(available: nil, on: Self.today).catalog.route(for: .writing, pace: .steady)?.effort == nil)
  }

  @Test func shouldRaiseTheLowestAcceptedLevelWhenEverythingAcceptedIsAbove() {
    let catalog = Self.catalog(
      [CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", efforts: [.high, .max])],
      effort: .low
    )
    #expect(catalog.resolved(available: nil, on: Self.today).catalog.route(for: .writing, pace: .steady)?.effort == .high)
  }

  @Test(arguments: [
    ("2026-12-18", nil as Int?),
    ("2026-12-17", nil as Int?),
    ("2026-12-16", 30),
    ("2026-11-17", 1),
    ("2026-11-16", 0),
    ("2026-11-15", nil as Int?),
  ])
  func shouldWarnOnlyWithinThirtyDays(retiresOn: String, daysLeft: Int?) {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: retiresOn)])
    let notices = catalog.resolved(available: nil, on: Self.today).notices
    let retiring = notices.filter { if case .retiringSoon = $0 { true } else { false } }
    if let daysLeft {
      #expect(retiring == [.retiringSoon(model: "a", on: CatalogFixtures.date(retiresOn), daysLeft: daysLeft)])
    } else {
      #expect(retiring == [])
    }
  }

  @Test func shouldWarnAboutThirtyOneDaysOutNever() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: "2026-12-17")])
    #expect(catalog.resolved(available: nil, on: Self.today).notices == [])
  }

  @Test func shouldWarnAboutTheSuccessorWhenItRetiresSoon() {
    let catalog = Self.catalog([CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]), CatalogFixtures.model("b", retiresOn: "2026-12-01")])
    #expect(
      catalog.resolved(available: nil, on: Self.today).notices == [.retiringSoon(model: "b", on: CatalogFixtures.date("2026-12-01"), daysLeft: 15), .replaced(model: "a", by: "b")]
    )
  }

  @Test func shouldNotWarnAboutModelsNoRouteUses() {
    let catalog = Self.catalog([CatalogFixtures.model("a"), CatalogFixtures.model("z", retiresOn: "2026-11-20")])
    #expect(catalog.resolved(available: nil, on: Self.today).notices == [])
  }

  @Test func shouldListNoticesInAStableOrderWithoutDuplicates() {
    var routes = CatalogFixtures.routes(model: "a")
    routes[.chat]?[.swift] = CatalogRoute(model: "c", effort: nil, maxOutputTokens: 10)
    routes[.helper]?[.swift] = CatalogRoute(model: "e", effort: nil, maxOutputTokens: 10)
    routes[.helper]?[.steady] = CatalogRoute(model: "d", effort: nil, maxOutputTokens: 10)
    let catalog = CatalogFixtures.catalog(
      models: [
        CatalogFixtures.model("a", retiresOn: Self.past, successors: ["b"]),
        CatalogFixtures.model("b"),
        CatalogFixtures.model("c", retiresOn: "2026-11-20"),
        CatalogFixtures.model("d", retiresOn: "2026-11-18"),
        CatalogFixtures.model("e", retiresOn: Self.past),
      ],
      routes: routes
    )
    let expected: [CatalogNotice] = [
      .retiringSoon(model: "d", on: CatalogFixtures.date("2026-11-18"), daysLeft: 2),
      .retiringSoon(model: "c", on: CatalogFixtures.date("2026-11-20"), daysLeft: 4),
      .replaced(model: "a", by: "b"),
      .unavailable(model: "e"),
    ]
    for _ in 0..<20 {
      #expect(catalog.resolved(available: nil, on: Self.today).notices == expected)
    }
  }
}
