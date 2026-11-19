import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("TaskRouter routes", TestTimeLimit.quick)
struct TaskRouterRouteTests {
  private static func router(_ configuration: TaskRouterConfiguration) throws -> TaskRouter {
    let clock = LedgerTestClock()
    return RoutingFixture.router(configuration, store: try LedgerFixture.store(clock), clock: clock)
  }

  private static func routeError(_ body: () throws(TaskRouterError) -> ModelRoute) -> TaskRouterError? {
    do {
      _ = try body()
      return nil
    } catch {
      return error
    }
  }

  @Test(
    "should route each Anthropic pace to its catalog model, effort and capped output",
    arguments: [
      (Pace.swift, "model-swift", Effort.low, 400),
      (.steady, "model-steady", .medium, 300),
      (.meticulous, "model-meticulous", .high, 600),
    ]
  )
  func anthropicPaces(pace: Pace, model: String, effort: Effort, cap: Int) throws {
    let route = try Self.router(RoutingFixture.configuration(.anthropic)).route(task: .writing, pace: pace)
    #expect(route.provider == .anthropic)
    #expect(route.model == model)
    #expect(route.effort == effort)
    #expect(route.maxOutputTokens == cap)
    #expect(route.contentMode == .standard)
    #expect(route.supportsNativeSchema)
  }

  @Test(
    "should raise the effort one level when thinking deeper, and say whether it could",
    arguments: [(Pace.swift, Effort.low, false), (.steady, .high, true), (.meticulous, .xhigh, true)]
  )
  func anthropicDeeper(pace: Pace, effort: Effort, deepened: Bool) throws {
    let router = try Self.router(RoutingFixture.configuration(.anthropic))
    let route = try router.route(task: .chat, pace: pace, thinksDeeper: true)
    #expect(route.effort == effort)
    #expect(route.model == RoutingFixture.catalog.routes[.chat]?[pace]?.model)
    #expect(route.thinksDeeper)
    #expect(route.deepened == deepened)
    #expect(try router.route(task: .chat, pace: pace).deepened == false)
  }

  @Test("should refuse an Anthropic route whose model the catalog does not describe")
  func anthropicUnknownModel() throws {
    var catalog = RoutingFixture.catalog
    catalog.routes[.review]?[.steady] = CatalogRoute(model: "model-gone", effort: .low, maxOutputTokens: 100)
    let router = try Self.router(RoutingFixture.configuration(.anthropic, catalog: catalog))
    guard case .noRoute(.review, .steady)? = Self.routeError({ () throws(TaskRouterError) in try router.route(task: .review, pace: .steady) }) else {
      Issue.record("expected noRoute")
      return
    }
  }

  @Test("should route each OpenRouter pace to its assigned model with the task's output cap and no effort", arguments: Pace.allCases)
  func openRouterPaces(pace: Pace) throws {
    let route = try Self.router(RoutingFixture.configuration(.openRouter)).route(task: .planning, pace: pace)
    #expect(route.provider == .openRouter)
    #expect(route.model == "or/\(pace.rawValue)")
    #expect(route.effort == nil)
    #expect(route.maxOutputTokens == RoutingFixture.catalog.routes[.planning]?[pace]?.maxOutputTokens)
    #expect(!route.supportsNativeSchema)
  }

  @Test("should take the Meticulous OpenRouter model and cap when thinking deeper", arguments: [(Pace.swift, true), (.steady, true), (.meticulous, false)])
  func openRouterDeeper(pace: Pace, deepened: Bool) throws {
    let route = try Self.router(RoutingFixture.configuration(.openRouter)).route(task: .chat, pace: pace, thinksDeeper: true)
    #expect(route.model == "or/meticulous")
    #expect(route.maxOutputTokens == 600)
    #expect(route.pace == pace)
    #expect(route.deepened == deepened)
  }

  @Test("should keep the pace's own OpenRouter model when Meticulous has none assigned")
  func openRouterDeeperUnassigned() throws {
    let assignments = OpenRouterAssignments(models: [.swift: "or/swift", .meticulous: "  "])
    let route = try Self.router(RoutingFixture.configuration(.openRouter, assignments: assignments)).route(task: .chat, pace: .swift, thinksDeeper: true)
    #expect(route.model == "or/swift")
    #expect(route.maxOutputTokens == 400)
    #expect(!route.deepened)
  }

  @Test("should clamp the cap and use native schema mode only where the published model list says so", arguments: [true, false, nil] as [Bool?])
  func openRouterListedModel(supportsJSONSchema: Bool?) throws {
    let listed = RemoteModel(id: "or/steady", maxOutputTokens: 120, supportsJSONSchema: supportsJSONSchema)
    let route = try Self.router(RoutingFixture.configuration(.openRouter, openRouterModels: [listed])).route(task: .chat, pace: .steady)
    #expect(route.maxOutputTokens == 120)
    #expect(route.supportsNativeSchema == (supportsJSONSchema == true))
  }

  @Test("should refuse an OpenRouter pace with no assigned model")
  func openRouterUnassigned() throws {
    let router = try Self.router(RoutingFixture.configuration(.openRouter, assignments: OpenRouterAssignments(models: [.swift: "or/swift"])))
    guard case .noRoute(.chat, .meticulous)? = Self.routeError({ () throws(TaskRouterError) in try router.route(task: .chat, pace: .meticulous) }) else {
      Issue.record("expected noRoute")
      return
    }
  }

  @Test("should send every unrestricted task to the unrestricted model on OpenRouter, whichever provider is chosen", arguments: ModelTask.allCases)
  func unrestrictedRoutesToAssignment(task: ModelTask) throws {
    let route = try Self.router(RoutingFixture.configuration(.anthropic)).route(task: task, pace: .swift, thinksDeeper: true, contentMode: .unrestricted)
    #expect(route.provider == .openRouter)
    #expect(route.model == "or/unrestricted")
    #expect(route.effort == nil)
    #expect(route.contentMode == .unrestricted)
    #expect(!route.deepened)
  }

  @Test("should fail loudly when no unrestricted model is assigned, never using a standard one", arguments: [nil, "", "   "] as [String?])
  func unrestrictedUnassigned(unrestricted: String?) throws {
    let assignments = OpenRouterAssignments(models: RoutingFixture.assignments.models, unrestricted: unrestricted)
    for provider in ModelProviderKind.allCases {
      let router = try Self.router(RoutingFixture.configuration(provider, assignments: assignments))
      guard case .unrestrictedModelMissing? = Self.routeError({ () throws(TaskRouterError) in try router.route(task: .writing, pace: .steady, contentMode: .unrestricted) })
      else {
        Issue.record("expected unrestrictedModelMissing for \(provider)")
        continue
      }
    }
  }

  @Test("should take each adapter's origin for its binding")
  func adapterBindings() throws {
    let credentials = RoutingFixture.allCredentials
    let anthropic = AnthropicProvider(credential: credentials.credentialLoader(for: .anthropic), transport: StubHTTPExchangeTransport())
    let configuration = OpenRouterConfiguration(origin: RoutingFixture.openRouterOrigin)
    let openRouter = OpenRouterProvider(configuration: configuration, credential: credentials.credentialLoader(for: .openRouter), transport: StubHTTPExchangeTransport())
    #expect(ProviderBinding(anthropic: anthropic)?.host == "api.anthropic.com")
    #expect(ProviderBinding(openRouter: openRouter)?.host == "router.example.com")
  }

  @Test("should fail loudly when the catalog gives an unrestricted task no output cap")
  func unrestrictedWithoutTaskRoute() throws {
    var catalog = RoutingFixture.catalog
    catalog.routes[.review] = nil
    let router = try Self.router(RoutingFixture.configuration(.openRouter, catalog: catalog))
    guard case .noRoute(.review, .steady)? = Self.routeError({ () throws(TaskRouterError) in try router.route(task: .review, pace: .steady, contentMode: .unrestricted) }) else {
      Issue.record("expected noRoute")
      return
    }
  }
}
