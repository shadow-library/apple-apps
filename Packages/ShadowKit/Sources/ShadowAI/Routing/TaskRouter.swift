import Foundation
import OSLog
import ShadowCore
import ShadowStore

public struct TaskRouterConfiguration: Sendable, Equatable {
  /// The provider standard routes use; unrestricted routes always use OpenRouter.
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
  private let credentials: any ModelCredentialSource
  private let store: VaultStore
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let makeID: @Sendable () -> UUID

  public init(
    configuration: TaskRouterConfiguration,
    anthropic: ProviderBinding? = nil,
    openRouter: ProviderBinding? = nil,
    credentials: any ModelCredentialSource,
    store: VaultStore,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current,
    makeID: @escaping @Sendable () -> UUID = { UUID.v7() }
  ) {
    self.configuration = configuration
    self.anthropic = anthropic
    self.openRouter = openRouter
    self.credentials = credentials
    self.store = store
    self.now = now
    self.calendar = calendar
    self.makeID = makeID
  }

  public func route(task: ModelTask, pace: Pace, thinksDeeper: Bool = false, contentMode: ModelContentMode = .standard) throws(TaskRouterError) -> ModelRoute {
    switch (contentMode, configuration.provider) {
    case (.unrestricted, _): try unrestrictedRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    case (.standard, .anthropic): try anthropicRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    case (.standard, .openRouter): try openRouterRoute(task: task, pace: pace, thinksDeeper: thinksDeeper)
    }
  }

  /// Checks the route, key, consent and spend cap once for one product call, so a call kept for later does not see a later revoke or spend; every stream
  /// of the returned call is ledgered.
  public func prepare(_ call: TaskCall) async throws(TaskRouterError) -> RoutedCall {
    do throws(TaskRouterError) {
      let route = try route(task: call.task, pace: call.pace, thinksDeeper: call.thinksDeeper, contentMode: call.contentMode)
      guard let binding = binding(for: route.provider) else { throw .providerMissing(route.provider) }
      guard let credential = await credentials.credential(for: route.provider), credential.authorizes(binding.origin) else { throw .credentialMissing(route.provider) }
      try await admit(call.consent, provider: route.provider, binding: binding)
      Self.logger.info(
        "Routed a call task=\(route.task.rawValue, privacy: .public) pace=\(route.pace.rawValue, privacy: .public) deepened=\(route.deepened, privacy: .public) mode=\(route.contentMode.rawValue, privacy: .public) provider=\(route.provider.rawValue, privacy: .public) model=\(route.model, privacy: .public) effort=\(route.effort?.rawValue ?? "none", privacy: .public)"
      )
      let ledger = CallLedger(store: store, catalog: configuration.catalog, host: binding.host, route: route, now: now, makeID: makeID)
      return RoutedCall(route: route, host: binding.host, provider: LedgeredProvider(base: binding.provider, ledger: ledger), journal: ledger.journal)
    } catch {
      Self.logger.notice(
        "Refused a call task=\(call.task.rawValue, privacy: .public) pace=\(call.pace.rawValue, privacy: .public) mode=\(call.contentMode.rawValue, privacy: .public) code=\(error.code, privacy: .public)"
      )
      throw error
    }
  }

  private func binding(for provider: ModelProviderKind) -> ProviderBinding? {
    switch provider {
    case .anthropic: anthropic
    case .openRouter: openRouter
    }
  }

  private func admit(_ consent: AIConsentRequirement, provider: ModelProviderKind, binding: ProviderBinding) async throws(TaskRouterError) {
    let (now, calendar, limits, host) = (now(), calendar, configuration.spendLimits, binding.host)
    let gate: Gate
    do {
      gate = try await store.read { transaction in
        guard try AIConsent.isGranted(provider: host, dataClass: consent.dataClass, currentSummary: consent.disclosure, in: transaction) else { return Gate.consentMissing }
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
