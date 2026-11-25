import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

nonisolated enum SettingsField: Hashable, Sendable {
  case title
  case schedule
  case weekStart
  case timeZone
  case intensity
  case homeCurrency
  case currencies
}

struct SettingsFailure: Equatable {
  let field: SettingsField
  let error: PresentedError
}

/// A wake and sleep pair on screen that is not saved yet: one that breaks the window stays here until the next valid pair saves both, since the field that
/// broke it may not be the one that fixes it (`settings-screen.tsx:345-366`).
nonisolated struct ScheduleDraft: Hashable, Sendable {
  var wake: Int
  var sleep: Int

  var window: ScheduleWindow? { ScheduleWindow(start: wake, end: sleep) }
  var problem: SleepWindowProblem? { SleepWindowProblem(wake: wake, sleep: sleep) }
}

/// The home currency is chosen once; a second device that set it first wins and this write changes nothing.
nonisolated enum SettingsRefusal: Error {
  case homeCurrencyFixed
}

/// Settings' reads and writes (`features/settings/settings-screen.tsx`). The time zone, intensity and displayed title feed replay, so they are commands, and
/// replay stages the zone and intensity for the next day; the day window, week start and currencies are fields of the settings record. The home currency
/// is set once, when the record is created, and never changed here: memoir-web locks it at onboarding so history stays comparable. Home's limit is a
/// budget, edited in Money's Budgets.
@MainActor
@Observable
final class SettingsModel {
  let snapshot = ReadObserver<SettingsSnapshot>()
  private(set) var today: MemoirToday?
  private(set) var saving: Set<SettingsField> = []
  var failure: SettingsFailure?
  private(set) var scheduleDraft: ScheduleDraft?

  private let context: MemoirScreenContext
  private let scheduleDelay: Duration
  private var scheduleGeneration = 0

  /// `scheduleDelay` is how long the pickers rest before the window is saved, so a time picker's every step is not a synced change.
  init(context: MemoirScreenContext, scheduleDelay: Duration = .milliseconds(700)) {
    self.context = context
    self.scheduleDelay = scheduleDelay
  }

  var deviceZone: String { context.clock.deviceZone().identifier }

  func run() async {
    let main = context.stores.main
    async let today: Void = followToday()
    await snapshot.run {
      main.observeReads { transaction in try SettingsSnapshot.load(in: transaction) }
    } onValue: { value in
      received(value)
    }
    await today
  }

  var account: AccountSettingsRecord? { snapshot.state.value?.account.record }

  /// The displayed title and the intensity mean something only with Hero.
  var showsHero: Bool { ModuleSelection(settings: account).contains(.hero) }

  var showsMoney: Bool { ModuleSelection(settings: account).contains(.money) }

  /// The pair the pickers show: the draft while one is on screen, else the saved window.
  var shownSchedule: ScheduleDraft? {
    if let scheduleDraft { return scheduleDraft }
    return account.map { ScheduleDraft(wake: $0.schedule.start, sleep: $0.schedule.end) }
  }

  var scheduleProblem: SleepWindowProblem? { scheduleDraft?.problem }

  var unknownZone: (identifier: String, fallbackOffsetMinutes: Int?)? {
    guard case .unknownZone(let identifier, let offset) = today?.source else { return nil }
    return (identifier, offset)
  }

  func failure(for field: SettingsField) -> PresentedError? {
    guard let failure, failure.field == field else { return nil }
    return failure.error
  }

  func setWake(_ minute: Int) async {
    guard let shown = shownSchedule else { return }
    await setSchedule(ScheduleDraft(wake: minute, sleep: shown.sleep))
  }

  func setSleep(_ minute: Int) async {
    guard let shown = shownSchedule else { return }
    await setSchedule(ScheduleDraft(wake: shown.wake, sleep: minute))
  }

  /// Shows the pair at once and saves it once the pickers rest; a save already under way picks up a newer pair when it lands.
  private func setSchedule(_ draft: ScheduleDraft) async {
    guard account != nil else { return }
    scheduleDraft = draft
    scheduleGeneration += 1
    let generation = scheduleGeneration
    guard draft.window != nil else { return }
    if scheduleDelay > .zero { try? await Task.sleep(for: scheduleDelay) }
    guard generation == scheduleGeneration else { return }
    await saveSchedule()
  }

  private func saveSchedule() async {
    while !saving.contains(.schedule), let draft = scheduleDraft, let window = draft.window, let account {
      guard window != account.schedule else {
        scheduleDraft = nil
        return
      }
      let generation = scheduleGeneration
      guard await edit(.schedule, { $0.schedule = window }) else {
        scheduleDraft = nil
        return
      }
      guard generation != scheduleGeneration else { return }
    }
  }

  func setWeekStart(_ start: WeekStart) async {
    guard let account, WeekStart(stored: account.weekStart) != start else { return }
    await edit(.weekStart) { $0.weekStart = start.rawValue }
  }

  /// Staged to the next day when a zone is in force; the first zone applies at once.
  @discardableResult
  func setTimeZone(_ identifier: String) async -> Bool {
    guard let value = snapshot.state.value else { return false }
    guard identifier != value.chosenZone else { return true }
    let change: TimeZoneChange
    do {
      change = try TimeZoneChange(identifier: identifier)
    } catch {
      failure = WritingErrors.presented(error).map { SettingsFailure(field: .timeZone, error: $0) }
      return false
    }
    return await issue(.timeZone, .accountSetTimeZone(change))
  }

  func setIntensity(_ mode: IntensityMode) async {
    guard let value = snapshot.state.value, mode != value.chosenIntensity else { return }
    await issue(.intensity, .accountSetIntensityMode(IntensityModeChange(mode: mode)))
  }

  /// Nil shows no title. A title not yet earned is refused here with the reference's code, as memoir-web refuses it before sending.
  func displayTitle(_ title: TitleID?) async {
    guard let value = snapshot.state.value, title != value.displayedTitle else { return }
    if let title, value.titles.first(where: { $0.id == title })?.earnedOn == nil {
      failure = WritingErrors.presented(ReplayRefusal.titleNotEarned(title)).map { SettingsFailure(field: .title, error: $0) }
      return
    }
    await issue(.title, .titleDisplay(TitleDisplay(title: title)))
  }

  /// Only while the vault has no settings record, as on a vault that has data from before onboarding existed.
  func setHomeCurrency(_ currency: CurrencyCode) async {
    guard snapshot.state.value?.account == .unset, !saving.contains(.homeCurrency) else { return }
    saving.insert(.homeCurrency)
    defer { saving.remove(.homeCurrency) }
    failure = nil
    do {
      try await Self.createSettings(currency, through: context.writer)
    } catch {
      failure = Self.presented(error).map { SettingsFailure(field: .homeCurrency, error: $0) }
    }
  }

  /// Creates the settings record with its home currency, refused once another device has created it.
  nonisolated static func createSettings(_ currency: CurrencyCode, through writer: MemoirWriter) async throws(MemoirWriteError) {
    try await writer.write { _, transaction in
      guard case .absent = try AccountSettingsRecord.read(key: .accountSettings, in: transaction) else { throw SettingsRefusal.homeCurrencyFixed }
      try AccountSettingsRecord(defaultCurrency: currency, enabledCurrencies: [currency]).create(in: &transaction)
    }
  }

  /// The home currency is always enabled.
  func setCurrency(_ currency: CurrencyCode, enabled: Bool) async {
    guard let account, currency != account.defaultCurrency, account.enabledCurrencies.contains(currency) != enabled else { return }
    await edit(.currencies) { record in
      var currencies = Set(record.enabledCurrencies)
      if enabled { currencies.insert(currency) } else { currencies.remove(currency) }
      record.enabledCurrencies = SettingsCurrencies.ordered(currencies, home: record.defaultCurrency)
    }
  }

  private func received(_ value: SettingsSnapshot) {
    if let draft = scheduleDraft, draft.window != nil, draft.window == value.account.record?.schedule { scheduleDraft = nil }
  }

  @discardableResult
  private func edit(_ field: SettingsField, _ change: @escaping @Sendable (inout AccountSettingsRecord) -> Void) async -> Bool {
    guard !saving.contains(field) else { return false }
    saving.insert(field)
    defer { saving.remove(field) }
    failure = nil
    do {
      try await context.writer.write { _, transaction in
        _ = try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { record in change(&record) }
      }
      return true
    } catch {
      failure = WritingErrors.presented(error).map { SettingsFailure(field: field, error: $0) }
      return false
    }
  }

  @discardableResult
  private func issue(_ field: SettingsField, _ body: MemoirCommandBody) async -> Bool {
    guard !saving.contains(field) else { return false }
    saving.insert(field)
    defer { saving.remove(field) }
    failure = nil
    do {
      try await context.writer.issue(body)
      return true
    } catch {
      failure = WritingErrors.presented(error).map { SettingsFailure(field: field, error: $0) }
      return false
    }
  }

  static func presented(_ error: MemoirWriteError) -> PresentedError? {
    if case .store(.aborted(let inner)) = error, inner is SettingsRefusal {
      return PresentedError(headline: String(localized: "Your home currency is already set.", table: "Settings"), detail: nil)
    }
    return WritingErrors.presented(error)
  }

  private func followToday() async {
    do {
      for try await today in context.observeToday() { self.today = today }
    } catch {
      today = nil
    }
  }
}
