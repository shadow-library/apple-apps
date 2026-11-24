import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore
import ShadowSyncRuntime

/// Why onboarding waits for sync before it writes. The settings record merges field by field with the last writer winning, so a device that turned sync on
/// and is still waiting for its key or for the other device's data would replace that device's home currency, day and currencies, and add a second first
/// quest and a second first time zone.
nonisolated enum OnboardingSyncHold: Hashable, Sendable {
  case arriving
  case awaitingKey

  init?(_ status: SyncStatus) {
    switch status {
    case .syncing: self = .arriving
    case .attentionNeeded(.awaitingKey), .attentionNeeded(.keysMissing), .attentionNeeded(.writingKeyMissing): self = .awaitingKey
    case .off, .upToDate, .attentionNeeded: return nil
    }
  }
}

/// The vault gained data while onboarding was open, as when sync brought another device's: nothing is written and onboarding gives way.
nonisolated enum OnboardingRefusal: Error {
  case alreadySetUp
}

/// The onboarding steps (`features/onboarding/onboarding-screen.tsx`), on the path the chosen modules need. Where the reference saves the day with
/// `onboarding.complete` and then creates the quest, failing between them, here the settings record, the first time zone, Home and, with Quests, the quest
/// with its record are one write, so a failure leaves nothing half done. Every command in it is stamped in the chosen zone, the clock the account's first
/// day is lived in.
@MainActor
@Observable
final class OnboardingModel {
  private(set) var step = OnboardingStep.purpose
  var draft: OnboardingDraft
  /// The steps whose problem shows by its field: once the owner edited the field or tried to go on.
  private(set) var touched: Set<OnboardingStep> = []
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  /// The sync status of this device, which the view follows; `.off` when sync is not set up.
  var syncStatus = SyncStatus.off

  private let context: MemoirScreenContext

  init(context: MemoirScreenContext, locale: Locale = .current) {
    self.context = context
    draft = OnboardingDraft(
      currency: SettingsCurrencies.standard(for: locale), timeZone: context.clock.deviceZone().identifier, format: AmountFormat(locale: locale))
  }

  var deviceZone: String { context.clock.deviceZone().identifier }

  var path: [OnboardingStep] { draft.path }

  var problem: OnboardingProblem? { draft.problem(at: step) }

  /// The step's problem once its field was touched.
  var shownProblem: OnboardingProblem? { touched.contains(step) ? problem : nil }

  var next: OnboardingStep? { neighbour(by: 1) }

  var previous: OnboardingStep? { neighbour(by: -1) }

  /// The account's first day: today in the chosen zone.
  var today: LocalDate? {
    try? context.clock.today(in: Self.zone(draft.timeZone)).date
  }

  var firstDay: LocalDate? { today.flatMap(draft.firstDay(from:)) }

  var startsToday: Bool { firstDay != nil && firstDay == today }

  var syncHold: OnboardingSyncHold? { OnboardingSyncHold(syncStatus) }

  /// Offered before anything is chosen, so App Review and a first look reach the demo without setting up a vault; entering it writes nothing here.
  var offersDemo: Bool { step == .purpose }

  func choose(_ preset: OnboardingPreset) {
    draft.purpose = .preset(preset)
  }

  /// Starts from what was chosen, or from every module.
  func chooseCustom() {
    if case .custom = draft.purpose { return }
    draft.purpose = .custom(draft.purpose?.modules ?? Set(MemoirModule.allCases))
  }

  /// A module turned on or off by hand; a selection `ModuleSelection` refuses stays on screen with its reason.
  func setModule(_ module: MemoirModule, enabled: Bool) {
    guard case .custom(var modules) = draft.purpose else { return }
    if enabled { modules.insert(module) } else { modules.remove(module) }
    draft.purpose = .custom(modules)
    touched.insert(.purpose)
  }

  func setName(_ name: String) {
    draft.name = String(name.prefix(OnboardingDraft.nameLimit))
    touched.insert(.quest)
  }

  func setStartMinute(_ minute: Int?) {
    draft.startMinute = minute
    touched.insert(.strictness)
  }

  /// The limit's problem waits until the owner tries to go on, so a half-typed amount is not called wrong.
  func setBudgetText(_ text: String) {
    draft.budgetText = text
    touched.remove(.budget)
  }

  /// Goes on when the step has no problem; otherwise marks the step's field so its problem shows.
  func advance() {
    if problem != nil {
      touched.insert(step)
      return
    }
    guard let next else { return }
    failure = nil
    step = next
  }

  func back() {
    guard let previous, !isSaving else { return }
    failure = nil
    step = previous
  }

  /// True once the vault is set up, by this write or by another device's data that arrived first. Held while sync is still bringing another device's data
  /// or waiting for its key. Only the steps on the path are asked and written.
  @discardableResult
  func finish() async -> Bool {
    guard step == .ready, !isSaving, syncHold == nil, draft.isComplete, let settings = draft.settings else { return false }
    isSaving = true
    defer { isSaving = false }
    failure = nil
    let draft = draft
    let clock = context.clock
    do {
      let zone = Self.zone(draft.timeZone)
      let change = try TimeZoneChange(identifier: draft.timeZone)
      try await context.writer.write { _, transaction in
        guard try OnboardingStanding.isNeeded(in: transaction) else { throw OnboardingRefusal.alreadySetUp }
        let today = try clock.today(in: zone).date
        var account = settings
        if draft.scoresMoney { account.moneyScoredFrom = today }
        try account.create(in: &transaction)
        let issuer = clock.issuer(in: zone)
        try issuer.issue(.accountSetTimeZone(change), in: &transaction)
        try HomeBudget.ensure(on: today, in: &transaction)
        if let limit = draft.homeLimitMinor { try BudgetEdits.update(HomeBudget.id, today: today, in: &transaction) { $0.limitMinor = limit } }
        guard draft.path.contains(.quest) else { return }
        let quest = try draft.quest(startingOn: today)
        try issuer.issue(.questCreate(quest.creation), content: quest.record, in: &transaction)
        try quest.record.create(in: &transaction)
      }
      return true
    } catch MemoirWriteError.store(.aborted(let inner)) where inner is OnboardingRefusal {
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }

  private func neighbour(by offset: Int) -> OnboardingStep? {
    let path = path
    guard let index = path.firstIndex(of: step), path.indices.contains(index + offset) else { return nil }
    return path[index + offset]
  }

  /// The chosen zone as the account's zone in force from its first day; replay applies a first zone at once.
  private static func zone(_ identifier: String) -> AccountZone {
    AccountZone(inForce: identifier, openDay: nil, lastRecordedOffsetMinutes: nil, staged: nil)
  }
}
