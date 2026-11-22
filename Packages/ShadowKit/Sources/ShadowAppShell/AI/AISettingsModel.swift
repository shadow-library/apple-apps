import Foundation
import Observation
import ShadowAI
import ShadowStore

@MainActor
@Observable
final class AISettingsModel {
  enum KeyEntry: Equatable {
    case idle
    case checking
    case rejected(PresentedError)
    case unverified(PresentedError)
    case failed(PresentedError)
  }

  let services: AIServices
  let store: VaultStore?
  var keyDrafts: [ModelProviderKind: String] = [:]
  var modelDrafts: [Pace: String] = [:]
  var dailyText = ""
  var monthlyText = ""
  var failure: PresentedError?
  private(set) var entries: [ModelProviderKind: KeyEntry] = [:]
  private(set) var storedKeys: Set<ModelProviderKind> = []
  private(set) var consents: [GrantedConsent] = []
  private(set) var consentsUnavailable = false
  private(set) var modelsFailure: PresentedError?
  private(set) var isLoadingModels = false
  private var keyGenerations: [ModelProviderKind: Int] = [:]

  init(services: AIServices, store: VaultStore?) {
    self.services = services
    self.store = store
    resetDrafts()
  }

  var provider: ModelProviderKind { services.settings.provider }

  var listedModels: [RemoteModel] { services.openRouterModels }

  var assignedModels: [Pace: String] { services.settings.assignments.models }

  func entry(_ provider: ModelProviderKind) -> KeyEntry { entries[provider] ?? .idle }

  func canSubmitKey(_ provider: ModelProviderKind) -> Bool {
    entry(provider) != .checking && !(keyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var missingModelPaces: [Pace] {
    guard provider == .openRouter else { return [] }
    return Pace.allCases.filter { assignedModels[$0]?.isEmpty != false }
  }

  func modelIssue(_ pace: Pace) -> ModelIdentifierIssue? {
    guard case .failure(let issue) = ModelIdentifierInput.parse(modelDrafts[pace] ?? "") else { return nil }
    return issue
  }

  var dailyIssue: SpendCapIssue? {
    switch (SpendCapInput.parse(dailyText), SpendCapInput.parse(monthlyText)) {
    case (.failure(let issue), _): issue
    case (.success(let daily?), .success(let monthly?)) where daily > monthly: .dailyAboveMonthly
    default: nil
    }
  }

  var monthlyIssue: SpendCapIssue? {
    guard case .failure(let issue) = SpendCapInput.parse(monthlyText) else { return nil }
    return issue
  }

  var hasModelChanges: Bool { currentAssignments() != services.settings.assignments.models }

  var canSaveModels: Bool { hasModelChanges && Pace.allCases.allSatisfy { modelIssue($0) == nil } }

  var hasCapChanges: Bool { dailyText != SpendCapInput.text(for: services.settings.limits.daily) || monthlyText != SpendCapInput.text(for: services.settings.limits.monthly) }

  var canSaveCaps: Bool { hasCapChanges && dailyIssue == nil && monthlyIssue == nil }

  func load() async {
    refreshStoredKeys()
    await refreshConsents()
    await loadModels()
  }

  func select(_ provider: ModelProviderKind) {
    services.update { $0.provider = provider }
  }

  func keyDraftChanged(_ provider: ModelProviderKind) {
    guard entry(provider) != .checking else { return }
    entries[provider] = nil
  }

  func submitKey(for provider: ModelProviderKind) async {
    guard canSubmitKey(provider), let credential = services.keys.makeCredential(keyDrafts[provider] ?? "", for: provider) else {
      if entry(provider) != .checking { entries[provider] = .rejected(Self.malformedKey) }
      return
    }
    entries[provider] = .checking
    let generation = keyGenerations[provider, default: 0]
    let status: CredentialStatus
    do {
      status = try await services.validate(credential, for: provider)
    } catch {
      guard keyGenerations[provider, default: 0] == generation else { return }
      entries[provider] = error == .cancelled ? .idle : .unverified(AIErrors.presented(error, app: services.identity))
      return
    }
    guard keyGenerations[provider, default: 0] == generation else { return }
    switch status {
    case .valid: await persist(credential, for: provider)
    case .invalid: entries[provider] = .rejected(AIErrors.presented(ModelError.authentication, app: services.identity))
    case .unverified(let error): entries[provider] = .unverified(AIErrors.presented(error, app: services.identity))
    }
  }

  func saveUnverified(for provider: ModelProviderKind) async {
    guard case .unverified = entry(provider), let credential = services.keys.makeCredential(keyDrafts[provider] ?? "", for: provider) else { return }
    await persist(credential, for: provider)
  }

  func removeKey(_ provider: ModelProviderKind) async {
    keyGenerations[provider, default: 0] += 1
    entries[provider] = nil
    do {
      try services.keys.remove(provider)
    } catch {
      failure = AIErrors.presented(error, app: services.identity)
      return
    }
    keyDrafts[provider] = nil
    storedKeys.remove(provider)
    guard provider == .openRouter else { return }
    services.forgetOpenRouterModels()
    modelsFailure = nil
  }

  func saveModels() {
    guard canSaveModels else { return }
    var assignments = services.settings.assignments
    assignments.models = currentAssignments()
    services.update { $0.assignments = assignments }
    modelDrafts = Dictionary(uniqueKeysWithValues: Pace.allCases.map { ($0, assignments.models[$0] ?? "") })
  }

  func choose(_ model: RemoteModel, for pace: Pace) {
    modelDrafts[pace] = model.id
  }

  func saveCaps() {
    guard canSaveCaps, case .success(let daily) = SpendCapInput.parse(dailyText), case .success(let monthly) = SpendCapInput.parse(monthlyText) else { return }
    services.update { $0.limits = SpendLimits(daily: daily, monthly: monthly) }
    dailyText = SpendCapInput.text(for: daily)
    monthlyText = SpendCapInput.text(for: monthly)
  }

  func loadModels() async {
    guard storedKeys.contains(.openRouter), !isLoadingModels else { return }
    isLoadingModels = true
    defer { isLoadingModels = false }
    do {
      try await services.refreshOpenRouterModels()
      if !storedKeys.contains(.openRouter) { services.forgetOpenRouterModels() }
      modelsFailure = nil
    } catch {
      modelsFailure = error == .cancelled ? nil : AIErrors.presented(error, app: services.identity)
    }
  }

  func refreshConsents() async {
    guard let store else {
      consentsUnavailable = true
      return
    }
    do {
      consents = try await services.grantedConsents(in: store)
      consentsUnavailable = false
    } catch {
      consentsUnavailable = true
    }
  }

  func revoke(_ consent: GrantedConsent) async {
    guard let store else { return }
    do {
      try await services.revoke(consent, in: store)
    } catch {
      failure = AIErrors.presented(error, app: services.identity)
      return
    }
    await refreshConsents()
  }

  private func persist(_ credential: ProviderCredential, for provider: ModelProviderKind) async {
    do {
      try services.keys.save(credential, for: provider)
    } catch {
      entries[provider] = .failed(AIErrors.presented(error, app: services.identity))
      return
    }
    keyDrafts[provider] = nil
    entries[provider] = nil
    storedKeys.insert(provider)
    guard provider == .openRouter else { return }
    await loadModels()
  }

  private func refreshStoredKeys() {
    do {
      storedKeys = Set(try ModelProviderKind.keyed.filter { try services.keys.contains($0) })
    } catch {
      failure = AIErrors.presented(error, app: services.identity)
    }
  }

  private func currentAssignments() -> [Pace: String] {
    var models: [Pace: String] = [:]
    for pace in Pace.allCases {
      guard case .success(let model?) = ModelIdentifierInput.parse(modelDrafts[pace] ?? "") else { continue }
      models[pace] = model
    }
    return models
  }

  private func resetDrafts() {
    let settings = services.settings
    modelDrafts = Dictionary(uniqueKeysWithValues: Pace.allCases.map { ($0, settings.assignments.models[$0] ?? "") })
    dailyText = SpendCapInput.text(for: settings.limits.daily)
    monthlyText = SpendCapInput.text(for: settings.limits.monthly)
  }

  private static var malformedKey: PresentedError {
    PresentedError(headline: String(localized: "This does not look like a key. Paste it again without extra characters.", table: "AISettings", bundle: .module), detail: nil)
  }
}
