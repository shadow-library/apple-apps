import Foundation
import MemoirCore

/// Every step onboarding can show. memoir-web's five (`HEADINGS`, `onboarding-screen.tsx:45-51`) are the day, the first quest, when it happens, how strict
/// it is and the summary; here the purpose comes first, the home currency has its own step, and Home's limit has one while Money is chosen.
nonisolated enum OnboardingStep: Hashable, Sendable, CaseIterable {
  case purpose
  case day
  case currency
  case quest
  case schedule
  case strictness
  case budget
  case ready

  /// The steps the chosen modules need, in order: the quest's three only with Quests, Home's limit only with Money.
  static func path(for modules: Set<MemoirModule>) -> [OnboardingStep] {
    var steps: [OnboardingStep] = [.purpose, .day, .currency]
    if modules.contains(.quests) { steps += [.quest, .schedule, .strictness] }
    if modules.contains(.money) { steps.append(.budget) }
    return steps + [.ready]
  }
}

nonisolated enum OnboardingRecurrence: Hashable, Sendable, CaseIterable {
  case daily
  case chosen
  case count
}

/// The answers to "What do you want Memoir for?" that choose the modules in one tap.
nonisolated enum OnboardingPreset: Hashable, Sendable, CaseIterable {
  case habits
  case spending
  case both
  case everything

  var modules: Set<MemoirModule> {
    switch self {
    case .habits: [.hero, .quests]
    case .spending: [.money]
    case .both: [.hero, .quests, .money]
    case .everything: Set(MemoirModule.allCases)
    }
  }
}

nonisolated enum OnboardingPurpose: Hashable, Sendable {
  case preset(OnboardingPreset)
  case custom(Set<MemoirModule>)

  var modules: Set<MemoirModule> {
    switch self {
    case .preset(let preset): preset.modules
    case .custom(let modules): modules
    }
  }
}

/// What keeps a step from going on (`problems`, `onboarding-screen.tsx:178-184`), with the modules `ModuleSelection` refuses and a limit that is no amount.
nonisolated enum OnboardingProblem: Equatable, Sendable {
  case modules(ModuleSelectionError)
  case sleepWindow(SleepWindowProblem)
  case nameRequired
  case noDays
  case anchorNeedsTime
  case budgetAmount(AmountInputRefusal)
  case budgetZero
}

/// The first quest as the reference drafts it (`draft()`, `onboarding-screen.tsx:200-225`): ten minutes, untimed unless it is an anchor, no reminder.
nonisolated struct OnboardingQuest: Sendable {
  let record: QuestRecord
  let creation: QuestCreation
}

/// Everything the steps decide; nothing is written until the last one. A step left off the path by a later change of purpose keeps its answers, which
/// the write ignores, so choosing Quests again brings them back.
nonisolated struct OnboardingDraft: Hashable, Sendable {
  static let moduleOrder: [MemoirModule] = [.quests, .hero, .money, .journal, .meals, .body]
  static let strictnessOrder: [Strictness] = [.optional, .goal, .routine, .anchor]
  static let statOrder: [StatAffinity] = [.body, .mind, .wealth, .discipline]
  static let weekdays: [LocalDate.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
  /// `SPREAD_DAYS` (`onboarding-screen.tsx:75-83`): how a count a week falls across the week.
  static let spreadDays: [Set<LocalDate.Weekday>] = [
    [.monday], [.tuesday, .friday], [.monday, .wednesday, .friday], [.monday, .tuesday, .thursday, .friday],
    [.monday, .tuesday, .wednesday, .thursday, .friday], [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday], Set(weekdays),
  ]
  static let nameLimit = 120
  static let questMinutes = 10
  static let lightWeekDays = 3
  static let timesPerWeek = 1...7
  static let standardWake = 6 * 60 + 30
  static let standardSleep = 22 * 60 + 30
  static let standardAnchorStart = 7 * 60

  var purpose: OnboardingPurpose?
  var currency: CurrencyCode
  var timeZone: String
  var wakeMinute = standardWake
  var sleepMinute = standardSleep
  var name = ""
  var stat = StatAffinity.mind
  var strictness = Strictness.goal
  var recurrence = OnboardingRecurrence.chosen
  var chosenDays: Set<LocalDate.Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
  var timesPerWeek = 4
  var startMinute: Int?
  var budgetText = ""
  let format: AmountFormat

  init(currency: CurrencyCode, timeZone: String, format: AmountFormat) {
    self.currency = currency
    self.timeZone = timeZone
    self.format = format
  }

  var modules: Set<MemoirModule> { purpose?.modules ?? [] }

  var path: [OnboardingStep] { OnboardingStep.path(for: modules) }

  var selection: Result<ModuleSelection, ModuleSelectionError> {
    Result { () throws(ModuleSelectionError) in try ModuleSelection(modules) }
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// `scheduledDays` (`onboarding-screen.tsx:105-109`).
  var scheduledDays: Set<LocalDate.Weekday> {
    switch recurrence {
    case .daily: Set(Self.weekdays)
    case .count: Self.spreadDays[min(max(timesPerWeek, Self.timesPerWeek.lowerBound), Self.timesPerWeek.upperBound) - 1]
    case .chosen: chosenDays
    }
  }

  var orderedScheduledDays: [LocalDate.Weekday] { Self.weekdays.filter(scheduledDays.contains) }

  /// Only an anchor keeps a start time (`onboarding-screen.tsx:160`).
  var questStartMinute: Int? { strictness == .anchor ? startMinute : nil }

  /// Home's limit in the home currency's minor units, read exactly through `AmountInput`; an empty field leaves Home without a limit until one is set.
  var budgetLimit: Result<Int64?, AmountInputRefusal> {
    let trimmed = budgetText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .success(nil) }
    return Result { () throws(AmountInputRefusal) in try AmountInput.minorUnits(trimmed, currency: currency, format: format) }
  }

  func problem(at step: OnboardingStep) -> OnboardingProblem? {
    switch step {
    case .purpose:
      guard case .failure(let refusal) = selection else { return nil }
      return .modules(refusal)
    case .day: return SleepWindowProblem(wake: wakeMinute, sleep: sleepMinute).map(OnboardingProblem.sleepWindow)
    case .currency, .ready: return nil
    case .quest: return trimmedName.isEmpty ? .nameRequired : nil
    case .schedule: return scheduledDays.isEmpty ? .noDays : nil
    case .strictness: return strictness == .anchor && startMinute == nil ? .anchorNeedsTime : nil
    case .budget:
      switch budgetLimit {
      case .failure(let refusal): return .budgetAmount(refusal)
      case .success(.some(0)): return .budgetZero
      case .success: return nil
      }
    }
  }

  /// No step on the path holds a problem; steps off it are not asked.
  var isComplete: Bool { path.allSatisfy { problem(at: $0) == nil } }

  /// The first scheduled day from `today` on (`firstDay`, `onboarding-screen.tsx:111-115`).
  func firstDay(from today: LocalDate) -> LocalDate? {
    (0..<7).lazy.compactMap { today.adding(days: $0) }.first { scheduledDays.contains($0.weekday) }
  }

  /// `onboarding.complete`'s values (`account.service.ts:159-176`): the home currency, enabled alone, and the day; the monthly budget starts unset, since
  /// Home holds the limit. A module not chosen is written off and a chosen one left unwritten, which reads as on.
  var settings: AccountSettingsRecord? {
    guard case .success(let selection) = selection, let window = ScheduleWindow(start: wakeMinute, end: sleepMinute) else { return nil }
    var record = AccountSettingsRecord(defaultCurrency: currency, enabledCurrencies: [currency], schedule: window)
    for module in MemoirModule.allCases where !selection.contains(module) { record.setModule(module, enabled: false) }
    return record
  }

  /// With Hero and Money both chosen, money is scored from the account's first day.
  var scoresMoney: Bool { modules.contains(.hero) && modules.contains(.money) }

  /// Home's limit as the write sets it: only on a path with Money, and none when the field is empty.
  var homeLimitMinor: Int64? {
    guard path.contains(.budget), case .success(let limit) = budgetLimit else { return nil }
    return limit
  }

  func quest(id: UUID = UUID(), startingOn today: LocalDate) throws -> OnboardingQuest {
    let frequency: RecurrenceRule.Frequency = recurrence == .daily ? .daily : .weekly(scheduledDays)
    let schedule = try QuestSchedule(
      strictness: strictness, startTimeMinutes: questStartMinute, durationMinutes: Self.questMinutes, statAffinity: stat,
      optionalStreakOptIn: strictness == .optional, recurrence: try RecurrenceRule(frequency: frequency, startDate: today))
    return OnboardingQuest(record: QuestRecord(id: id, name: trimmedName), creation: QuestCreation(questId: id, schedule: schedule))
  }
}
