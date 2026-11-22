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

/// The five onboarding steps (`features/onboarding/onboarding-screen.tsx`). Where the reference saves the day with `onboarding.complete` and then creates
/// the quest, failing between them, here the settings record, the first time zone and the quest with its record are one write, so a failure leaves nothing
/// half done. Every command in it is stamped in the chosen zone, the clock the account's first day is lived in.
@MainActor
@Observable
final class OnboardingModel {
  private(set) var step = OnboardingStep.day
  var draft: OnboardingDraft
  var nameTouched = false
  var startTimeTouched = false
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  /// The sync status of this device, which the view follows; `.off` when sync is not set up.
  var syncStatus = SyncStatus.off

  private let context: MemoirScreenContext

  init(context: MemoirScreenContext, locale: Locale = .current) {
    self.context = context
    draft = OnboardingDraft(currency: SettingsCurrencies.standard(for: locale), timeZone: context.clock.deviceZone().identifier)
  }

  var deviceZone: String { context.clock.deviceZone().identifier }

  var problem: OnboardingProblem? { draft.problem(at: step) }

  /// The account's first day: today in the chosen zone.
  var today: LocalDate? {
    try? context.clock.today(in: Self.zone(draft.timeZone)).date
  }

  var firstDay: LocalDate? { today.flatMap(draft.firstDay(from:)) }

  var startsToday: Bool { firstDay != nil && firstDay == today }

  var syncHold: OnboardingSyncHold? { OnboardingSyncHold(syncStatus) }

  func setName(_ name: String) {
    draft.name = String(name.prefix(OnboardingDraft.nameLimit))
    nameTouched = true
  }

  func setStartMinute(_ minute: Int?) {
    draft.startMinute = minute
    startTimeTouched = true
  }

  /// Goes on when the step has no problem; otherwise marks the step's field so its problem shows.
  func advance() {
    if let problem {
      if problem == .nameRequired { nameTouched = true }
      if problem == .anchorNeedsTime { startTimeTouched = true }
      return
    }
    guard let next = step.next else { return }
    failure = nil
    step = next
  }

  func back() {
    guard let previous = step.previous, !isSaving else { return }
    failure = nil
    step = previous
  }

  /// True once the vault is set up, by this write or by another device's data that arrived first. Held while sync is still bringing another device's data
  /// or waiting for its key.
  @discardableResult
  func finish() async -> Bool {
    guard step == .ready, !isSaving, syncHold == nil, OnboardingStep.allCases.allSatisfy({ draft.problem(at: $0) == nil }), let settings = draft.settings else { return false }
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
        try settings.create(in: &transaction)
        let issuer = clock.issuer(in: zone)
        let quest = try draft.quest(startingOn: try clock.today(in: zone).date)
        try issuer.issue(.accountSetTimeZone(change), in: &transaction)
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

  /// The chosen zone as the account's zone in force from its first day; replay applies a first zone at once.
  private static func zone(_ identifier: String) -> AccountZone {
    AccountZone(inForce: identifier, openDay: nil, lastRecordedOffsetMinutes: nil, staged: nil)
  }
}
