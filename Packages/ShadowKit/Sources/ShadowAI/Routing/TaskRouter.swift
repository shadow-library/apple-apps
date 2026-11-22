import Foundation
import OSLog
import ShadowCore
import ShadowStore

public struct TaskRouterConfiguration: Sendable, Equatable {
  /// The provider standard routes use; unrestricted routes always use OpenRouter, also in the demo, which therefore refuses them.
  public var provider: ModelProviderKind
  public var catalog: ModelCatalog
  public var assignments: OpenRouterAssignments
  public var openRouterModels: [RemoteModel]
  public var spendLimits: SpendLimits

  public init(
    provider: ModelProviderKind, catalog: ModelCatalog = .bundled, assignments: OpenRouterAssignments = .init(), openRouterModels: [RemoteModel] = [],
    spendLimits: SpendLimits = .init()
  ) {
    self.provider = provider
    self.catalog = catalog
    self.assignments = assignments
    self.openRouterModels = openRouterModels
    self.spendLimits = spendLimits
  }
}

public struct TaskRouter: Sendable {
  static let logger = Logger(category: "ShadowAI.Routing")

  private enum Gate: Sendable {
    case consentMissing
    case spendUnavailable
    case spend(SpendDecision)
  }

  public let configuration: TaskRouterConfiguration
  private let anthropic: ProviderBinding?
  private let openRouter: ProviderBinding?
  private let demo: DemoModelProvider?
  private let credentials: any ModelCredentialSource
  private let store: VaultStore
  private let requestGuard: @Sendable (ModelRoute) -> ModelRequestGuard?
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let makeID: @Sendable () -> UUID

  public init(
    configuration: TaskRouterConfiguration,
    anthropic: ProviderBinding? = nil,
    openRouter: ProviderBinding? = nil,
    demo: DemoModelProvider? = nil,
    credentials: any ModelCredentialSource,
    store: VaultStore,
    requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard?,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current,
    makeID: @escaping @Sendable () -> UUID = { UUID.v7() }
  ) {
    self.configuration = configuration
    self.anthropic = anthropic
    self.openRouter = openRouter
    self.demo = demo
    self.credentials = credentials
    self.store = store
    self.requestGuard = requestGuard
    self.now = now
    self.calendar = calendar
    self.makeID = makeID
  }

  public func route(task: ModelTask, pace: Pace, thinksDeeper: Bool = false, contentMode: ModelContentMode = .standard) throws(TaskRouterError) -> ModelRoute {
    switch (contentMode, configuration.provider) {
    case (.unrestricted, _): try unrestrictedRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    case (.standard, .anthropic): try anthropicRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    case (.standard, .openRouter): try openRouterRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    case (.standard, .demo): try demoRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    }
  }

  /// Checks the route, key, consent and spend cap once for one product call, so a call kept for later does not see a later revoke or spend; every stream
  /// of the returned call passes the route's request guard, then is ledgered. A demo route needs no key and meets no spend cap.
  public func prepare(_ call: TaskCall) async throws(TaskRouterError) -> RoutedCall {
    do throws(TaskRouterError) {
      let route = try route(task: call.task, pace: call.pace, thinksDeeper: call.thinksDeeper, contentMode: call.contentMode)
      guard let binding = binding(for: route) else { throw .providerMissing(route.provider) }
      if route.provider.needsKey {
        guard let credential = await credentials.credential(for: route.provider), credential.authorizes(binding.origin) else { throw .credentialMissing(route.provider) }
      }
      try await admit(call.consent, provider: route.provider, binding: binding)
      Self.logger.info(
        "Routed a call task=\(route.task.rawValue, privacy: .public) pace=\(route.pace.rawValue, privacy: .public) deepened=\(route.deepened, privacy: .public) mode=\(route.contentMode.rawValue, privacy: .public) provider=\(route.provider.rawValue, privacy: .public) model=\(route.model, privacy: .public) effort=\(route.effort?.rawValue ?? "none", privacy: .public)"
      )
      let ledger = CallLedger(store: store, catalog: configuration.catalog, host: binding.host, route: route, now: now, makeID: makeID)
      return RoutedCall(
        route: route, host: binding.host, ledgered: LedgeredProvider(base: binding.provider, ledger: ledger), requestGuard: requestGuard(route), journal: ledger.journal)
    } catch {
      Self.logger.notice(
        "Refused a call task=\(call.task.rawValue, privacy: .public) pace=\(call.pace.rawValue, privacy: .public) mode=\(call.contentMode.rawValue, privacy: .public) code=\(error.code, privacy: .public)"
      )
      throw error
    }
  }

  /// The consent a call in `contentMode` still needs from the host `route` sends it to (OpenRouter for unrestricted, else the configured provider), read
  /// now; nil once granted, or when no provider is bound (the call itself is then refused), so work that has to call can wait before it starts.
  public func missingConsent(_ consent: AIConsentRequirement, contentMode: ModelContentMode = .standard) async throws(TaskRouterError) -> AIConsentRequest? {
    let provider = contentMode == .unrestricted ? ModelProviderKind.openRouter : configuration.provider
    guard let host = binding(for: provider)?.host else { return nil }
    let granted: Bool
    do {
      granted = try await store.read { transaction in
        try AIConsent.isGranted(provider: host, dataClass: consent.dataClass, currentSummary: consent.disclosure, in: transaction)
      }
    } catch {
      throw .ledger(error)
    }
    return granted ? nil : AIConsentRequest(provider: provider, host: host, dataClass: consent.dataClass, disclosure: consent.disclosure)
  }

  /// The spend cap a call would meet now, read as `prepare` reads it, so work that has to call can wait before it starts.
  public func spendDecision() async throws(TaskRouterError) -> SpendDecision {
    guard configuration.provider != .demo else { return .allowed }
    let (now, calendar, limits) = (now(), calendar, configuration.spendLimits)
    let summary: SpendSummary?
    do {
      summary = try await store.read { transaction in try Spend.summary(in: transaction, now: now, calendar: calendar) }
    } catch {
      throw .ledger(error)
    }
    guard let summary else { throw .spendUnavailable }
    return Spend.decision(for: summary, limits: limits)
  }

  private func binding(for provider: ModelProviderKind) -> ProviderBinding? {
    switch provider {
    case .anthropic: anthropic
    case .openRouter: openRouter
    case .demo: demo.flatMap { ProviderBinding(origin: DemoModelProvider.origin, provider: $0) }
    }
  }

  private func binding(for route: ModelRoute) -> ProviderBinding? {
    guard route.provider == .demo else { return binding(for: route.provider) }
    return demo.flatMap { ProviderBinding(origin: DemoModelProvider.origin, provider: $0.answering(route.task)) }
  }

  private func admit(_ consent: AIConsentRequirement, provider: ModelProviderKind, binding: ProviderBinding) async throws(TaskRouterError) {
    let (now, calendar, limits, host) = (now(), calendar, configuration.spendLimits, binding.host)
    let gate: Gate
    do {
      gate = try await store.read { transaction in
        guard try AIConsent.isGranted(provider: host, dataClass: consent.dataClass, currentSummary: consent.disclosure, in: transaction) else { return Gate.consentMissing }
        guard provider != .demo else { return Gate.spend(.allowed) }
        guard let summary = try Spend.summary(in: transaction, now: now, calendar: calendar) else { return Gate.spendUnavailable }
        return Gate.spend(Spend.decision(for: summary, limits: limits))
      }
    } catch {
      throw .ledger(error)
    }
    switch gate {
    case .consentMissing:
      throw .consentRequired(AIConsentRequest(provider: provider, host: host, dataClass: consent.dataClass, disclosure: consent.disclosure))
    case .spendUnavailable: throw .spendUnavailable
    case .spend(.allowed): return
    case .spend(.dailyLimitReached(let spent, let limit)): throw .dailySpendLimitReached(spent: spent, limit: limit)
    case .spend(.monthlyLimitReached(let spent, let limit)): throw .monthlySpendLimitReached(spent: spent, limit: limit)
    }
  }

  /// Think deeper raises the effort one level, as the plan's AI layer says.
  private func anthropicRoute(task: ModelTask, pace: Pace, thinksDeeper: Bool) throws(TaskRouterError) -> ModelRoute {
    let catalog = configuration.catalog
    guard let base = catalog.route(for: task, pace: pace), let route = catalog.route(for: task, pace: pace, deeper: thinksDeeper), let model = catalog.model(route.model) else {
      throw .noRoute(task: task, pace: pace)
    }
    let cap = min(route.maxOutputTokens, model.maxOutputTokens)
    guard cap >= 1 else { throw .noRoute(task: task, pace: pace) }
    return ModelRoute(
      task: task, pace: pace, thinksDeeper: thinksDeeper, deepened: route.effort != base.effort, contentMode: .standard, provider: .anthropic, model: model.id,
      effort: route.effort, maxOutputTokens: cap, supportsNativeSchema: model.supportsJSONSchema)
  }

  /// The demo takes the catalog's output cap, so progress reads as it would with a real model, and the prompt form of structured output, so it sees every
  /// schema whole.
  private func demoRoute(task: ModelTask, pace: Pace, thinksDeeper: Bool) throws(TaskRouterError) -> ModelRoute {
    guard let cap = configuration.catalog.routes[task]?[pace]?.maxOutputTokens, cap >= 1 else { throw .noRoute(task: task, pace: pace) }
    return ModelRoute(
      task: task, pace: pace, thinksDeeper: thinksDeeper, deepened: false, contentMode: .standard, provider: .demo, model: DemoModelProvider.model, effort: nil,
      maxOutputTokens: cap, supportsNativeSchema: false)
  }

  /// OpenRouter routes carry no effort, so Think deeper takes the Meticulous model and cap, as the reference sends the performant tier for that turn
  /// (novel-forge-web/src/lib/chat-model.ts:42,53); without a Meticulous model it keeps the pace's own.
  private func openRouterRoute(task: ModelTask, pace: Pace, thinksDeeper: Bool) throws(TaskRouterError) -> ModelRoute {
    let own = assignedRoute(task: task, pace: pace)
    let deeper = thinksDeeper ? assignedRoute(task: task, pace: .meticulous) : nil
    guard let chosen = deeper ?? own else { throw .noRoute(task: task, pace: pace) }
    let deepened = deeper.map { $0.model != own?.model || $0.maxOutputTokens != own?.maxOutputTokens } ?? false
    return ModelRoute(
      task: task, pace: pace, thinksDeeper: thinksDeeper, deepened: deepened, contentMode: .standard, provider: .openRouter, model: chosen.model, effort: nil,
      maxOutputTokens: chosen.maxOutputTokens, supportsNativeSchema: chosen.supportsNativeSchema)
  }

  /// Think deeper has nothing to raise here: the novel has one unrestricted model and it takes no effort.
  private func unrestrictedRoute(task: ModelTask, pace: Pace, thinksDeeper: Bool) throws(TaskRouterError) -> ModelRoute {
    guard let model = configuration.assignments.unrestricted?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { throw .unrestrictedModelMissing }
    guard let cap = configuration.catalog.routes[task]?[pace]?.maxOutputTokens, let route = openRouterModel(model, cap: cap) else { throw .noRoute(task: task, pace: pace) }
    return ModelRoute(
      task: task, pace: pace, thinksDeeper: thinksDeeper, deepened: false, contentMode: .unrestricted, provider: .openRouter, model: route.model, effort: nil,
      maxOutputTokens: route.maxOutputTokens, supportsNativeSchema: route.supportsNativeSchema)
  }

  private func assignedRoute(task: ModelTask, pace: Pace) -> OpenRouterModelRoute? {
    guard let cap = configuration.catalog.routes[task]?[pace]?.maxOutputTokens, let model = configuration.assignments.route(for: pace, maxOutputTokens: cap)?.model else {
      return nil
    }
    return openRouterModel(model, cap: cap)
  }

  /// Native schema mode only for a model the published list says supports it.
  private func openRouterModel(_ model: String, cap: Int) -> OpenRouterModelRoute? {
    let listed = configuration.openRouterModels.first { $0.id == model }
    let clamped = min(cap, listed?.maxOutputTokens ?? cap)
    guard clamped >= 1 else { return nil }
    return OpenRouterModelRoute(model: model, maxOutputTokens: clamped, supportsNativeSchema: listed?.supportsJSONSchema == true)
  }
}

private struct OpenRouterModelRoute {
  let model: String
  let maxOutputTokens: Int
  let supportsNativeSchema: Bool
}
