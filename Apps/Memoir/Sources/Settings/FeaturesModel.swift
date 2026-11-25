import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// Settings › Features: the vault's modules, changed only through `ModuleChanges` with the writer's clock. Turning Quests off asks first when it would
/// pause quests, and turning Quests on turns Hero on with it, since Quests need Hero. A vault without settings chooses its home currency first. After a
/// change the owner's vault reroutes sync and stops reading Health as `MemoirModuleEffects` decides; the demo's changes only its own vault.
@MainActor
@Observable
final class FeaturesModel {
  struct Confirmation: Equatable {
    let changes: [MemoirModule: Bool]
    let pausing: Int
  }

  let standing = ReadObserver<AccountStanding>()
  private(set) var pending: [MemoirModule: Bool]?
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  var confirmation: Confirmation?

  private let context: MemoirScreenContext
  private let effects: MemoirModuleEffects?

  init(context: MemoirScreenContext, effects: MemoirModuleEffects?) {
    self.context = context
    self.effects = context.isDemo ? nil : effects
  }

  func run() async {
    let main = context.stores.main
    await standing.run { main.observeReads { transaction in try AccountStanding.load(in: transaction) } }
  }

  var selection: ModuleSelection { ModuleSelection(settings: standing.state.value?.record) }

  /// What the toggle shows: the change being written, else the vault's modules.
  func isOn(_ module: MemoirModule) -> Bool {
    pending?[module] ?? selection.contains(module)
  }

  var canChange: Bool { standing.state.value?.record != nil && !isSaving && confirmation == nil }

  func set(_ module: MemoirModule, enabled: Bool) async {
    guard canChange, selection.contains(module) != enabled else { return }
    let changes = Self.changes(turning: module, enabled: enabled, in: selection)
    isSaving = true
    failure = nil
    let preview: ModuleChange
    do {
      preview = try await context.writer.modules.preview(changes)
    } catch {
      isSaving = false
      failure = Self.presented(error)
      return
    }
    isSaving = false
    guard preview.pausedQuests.isEmpty else {
      confirmation = Confirmation(changes: changes, pausing: preview.pausedQuests.count)
      return
    }
    await apply(changes)
  }

  func confirm() async {
    guard let confirmation else { return }
    self.confirmation = nil
    await apply(confirmation.changes)
  }

  func cancelConfirmation() {
    confirmation = nil
  }

  func setHomeCurrency(_ currency: CurrencyCode) async {
    guard standing.state.value == .unset, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    failure = nil
    do {
      try await SettingsModel.createSettings(currency, through: context.writer)
    } catch {
      failure = SettingsModel.presented(error)
    }
  }

  /// Quests need Hero, so turning Quests on brings Hero with it; every other refusal is the owner's to resolve.
  static func changes(turning module: MemoirModule, enabled: Bool, in selection: ModuleSelection) -> [MemoirModule: Bool] {
    guard module == .quests, enabled, !selection.contains(.hero) else { return [module: enabled] }
    return [.quests: true, .hero: true]
  }

  private func apply(_ changes: [MemoirModule: Bool]) async {
    guard !isSaving else { return }
    isSaving = true
    pending = changes
    failure = nil
    let change: ModuleChange
    do {
      change = try await context.writer.modules.apply(changes)
    } catch {
      isSaving = false
      pending = nil
      failure = Self.presented(error)
      return
    }
    isSaving = false
    pending = nil
    await effects?.settle(change, in: context.stores)
  }

  static func presented(_ error: ModuleChangeError) -> PresentedError? {
    switch error {
    case .settingsAbsent: PresentedError(headline: String(localized: "Choose your home currency first.", table: "Settings"), detail: nil)
    case .refused(let refusal): PresentedError(headline: SettingsCopy.refusal(refusal), detail: nil)
    case .store(let error): WritingErrors.presented(error)
    case .record(let error): WritingErrors.presented(error)
    case .issue(let error): WritingErrors.presented(error)
    case .clock(let error): WritingErrors.presented(error)
    }
  }
}
