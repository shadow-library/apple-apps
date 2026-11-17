import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import ShadowAI

struct StaticCredentials: ModelCredentialSource {
  let credentials: [ModelProviderKind: ProviderCredential]

  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    credentials[provider]
  }
}

enum RoutingFixture {
  static let anthropicOrigin = url("https://api.example.com")
  static let openRouterOrigin = url("https://router.example.com")
  static let consent = AIConsentRequirement(dataClass: "novel", disclosure: "novel-text/v1")

  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()

  static let catalog = ModelCatalog(
    revision: 1,
    models: [
      CatalogFixtures.model("model-swift", efforts: [.low], maxOutput: 1_000),
      CatalogFixtures.model("model-steady", efforts: [.low, .medium, .high], maxOutput: 300),
      CatalogFixtures.model("model-meticulous", efforts: [.low, .medium, .high, .xhigh], maxOutput: 1_000),
    ],
    routes: Dictionary(
      uniqueKeysWithValues: ModelTask.allCases.map { task in
        (
          task,
          [
            .swift: CatalogRoute(model: "model-swift", effort: .low, maxOutputTokens: 400),
            .steady: CatalogRoute(model: "model-steady", effort: .medium, maxOutputTokens: 500),
            .meticulous: CatalogRoute(model: "model-meticulous", effort: .high, maxOutputTokens: 600),
          ]
        )
      }
    )
  )

  static let assignments = OpenRouterAssignments(models: [.swift: "or/swift", .steady: "or/steady", .meticulous: "or/meticulous"], unrestricted: "or/unrestricted")

  static let schema: JSONValue = [
    "type": "object",
    "properties": ["answer": ["type": "string"]],
    "required": ["answer"],
    "additionalProperties": false,
  ]

  static func url(_ text: String) -> URL {
    guard let url = URL(string: text) else { preconditionFailure("valid URL \(text)") }
    return url
  }

  static func credential(_ origin: URL) -> ProviderCredential {
    guard let credential = ProviderCredential(origin: origin, secret: "sk-test") else { preconditionFailure("valid credential") }
    return credential
  }

  static let allCredentials = StaticCredentials(credentials: [.anthropic: credential(anthropicOrigin), .openRouter: credential(openRouterOrigin)])

  static func binding(_ kind: ModelProviderKind, _ provider: any ModelProvider) -> ProviderBinding {
    guard let binding = ProviderBinding(origin: kind == .anthropic ? anthropicOrigin : openRouterOrigin, provider: provider) else { preconditionFailure("valid binding") }
    return binding
  }

  static func configuration(
    _ provider: ModelProviderKind = .anthropic, assignments: OpenRouterAssignments = assignments, openRouterModels: [RemoteModel] = [], limits: SpendLimits = .init(),
    catalog: ModelCatalog = catalog
  ) -> TaskRouterConfiguration {
    TaskRouterConfiguration(provider: provider, catalog: catalog, assignments: assignments, openRouterModels: openRouterModels, spendLimits: limits)
  }

  static func router(
    _ configuration: TaskRouterConfiguration = configuration(), anthropic: (any ModelProvider)? = nil, openRouter: (any ModelProvider)? = nil,
    credentials: StaticCredentials = allCredentials, store: VaultStore, clock: LedgerTestClock,
    requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard? = { _ in nil }
  ) -> TaskRouter {
    TaskRouter(
      configuration: configuration, anthropic: anthropic.map { binding(.anthropic, $0) }, openRouter: openRouter.map { binding(.openRouter, $0) }, credentials: credentials,
      store: store, requestGuard: requestGuard, now: clock.function, calendar: utc)
  }

  static func grantConsent(host: String, consent: AIConsentRequirement = consent, in store: VaultStore) async throws {
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
    }
  }

  static func call(_ task: ModelTask = .chat, pace: Pace = .steady, deeper: Bool = false, mode: ModelContentMode = .standard) -> TaskCall {
    TaskCall(task: task, pace: pace, thinksDeeper: deeper, contentMode: mode, consent: consent)
  }

  static func drain(_ stream: ModelStream) async -> (events: [ModelEvent], error: ModelError?) {
    var events: [ModelEvent] = []
    do throws(ModelError) {
      for try await event in stream { events.append(event) }
      return (events, nil)
    } catch {
      return (events, error)
    }
  }
}
