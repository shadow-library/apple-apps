import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// What the owner types for a meal or a preset. Calories are an estimate with no food database behind them, so zero is a valid answer.
nonisolated struct MealDraft: Equatable, Sendable {
  var name = ""
  var calories: Int? = 0
  var mealType = MealType.cooked
  var touched = false

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// `mealCaloriesError` (`quick-logs.rules.ts:54-58`).
  var caloriesProblem: String? {
    guard let calories else { return String(localized: "Enter the calories — zero is a valid answer.", table: "Log") }
    return calories < 0 ? String(localized: "Calories are a whole number, zero or more.", table: "Log") : nil
  }

  var isComplete: Bool { !trimmedName.isEmpty && caloriesProblem == nil }

  init() {}

  init(_ preset: MealPresetRecord) {
    name = preset.name
    calories = preset.calories
    if case .known(let type) = preset.mealType { mealType = type }
  }
}

enum PresetLogOutcome: Equatable {
  case logged
  /// The same preset was logged a moment ago: a second tap within the window logs another one.
  case confirmRelog
  case ignored
  case failed
}

/// `features/quick-logs/meals-screen.tsx` and `meal-entry-panel.tsx`: today's meals, a typed meal, the presets and the last 14 days of calories.
@MainActor
@Observable
final class MealsModel {
  /// `RELOG_GUARD_MS`, `RELOG_CONFIRM_MS` and `RELOG_CONFIRM_SETTLE_MS` (`meals-screen.tsx:24-26`).
  static let relogGuard = Duration.milliseconds(1_500)
  static let relogConfirm = Duration.milliseconds(4_000)
  static let relogSettle = Duration.milliseconds(400)

  let context: MemoirScreenContext
  let overview = ReadObserver<MealsOverview>()
  let caps = ReadObserver<EntryCapsOverview>()
  var draft = MealDraft()
  private(set) var isSaving = false
  private(set) var loggingPreset: UUID?
  private(set) var confirmingPreset: UUID?
  private(set) var failure: PresentedError?
  private(set) var confirmation: String?
  private var lastPresetLog: (preset: UUID, at: ContinuousClock.Instant)?
  private var confirmStarted: ContinuousClock.Instant?
  private let uptime: @Sendable () -> ContinuousClock.Instant

  init(context: MemoirScreenContext, uptime: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
    self.context = context
    self.uptime = uptime
  }

  func observe() async {
    let context = context
    let stores = context.stores
    let days = LogStreams.days(context)
    async let overview: Void = overview.run { LogStreams.following(days) { today in LogReads.observeMeals(in: stores, on: today, today: today) } }
    async let caps: Void = caps.run { LogStreams.entryCaps(context) }
    _ = await (overview, caps)
  }

  var advisory: EntryCapAdvisory? { caps.state.value?.advisory(.meals) }

  var canSaveMeal: Bool { !isSaving && draft.isComplete }

  @discardableResult
  func saveMeal() async -> Bool {
    draft.touched = true
    guard canSaveMeal, let calories = draft.calories else { return false }
    let draft = draft
    let saved = await write(String(localized: "\(draft.trimmedName) logged.", table: "Log")) { context, date, millis in
      let id = UUID()
      let meal = MealRecord(id: id, date: date, name: draft.trimmedName, calories: calories, mealType: .known(draft.mealType), loggedAtMillis: millis)
      try await context.writer.issue(.mealLog(QuickLogEntry(id: id, date: date)), creating: meal)
    }
    if saved { self.draft = MealDraft() }
    return saved
  }

  /// A preset logs in one tap; the same preset tapped again within `relogGuard` asks for a second tap rather than logging twice by accident.
  func logPreset(_ preset: MealPresetRecord) async -> PresetLogOutcome {
    guard loggingPreset == nil else { return .ignored }
    let now = uptime()
    if let started = confirmStarted, now - started >= Self.relogConfirm { endConfirm() }
    let confirming = confirmingPreset == preset.id ? confirmStarted : nil
    if let confirming, now - confirming < Self.relogSettle { return .ignored }
    if confirming == nil, let last = lastPresetLog, last.preset == preset.id, now - last.at < Self.relogGuard {
      confirmingPreset = preset.id
      confirmStarted = now
      return .confirmRelog
    }
    endConfirm()
    loggingPreset = preset.id
    defer { loggingPreset = nil }
    let saved = await write(String(localized: "\(preset.name) logged.", table: "Log")) { context, date, millis in
      let id = UUID()
      let meal = MealRecord(
        id: id, date: date, name: preset.name, calories: preset.calories, mealType: preset.mealType, note: preset.note, preset: preset.id, loggedAtMillis: millis)
      try await context.writer.issue(.mealLogPreset(PresetMealEntry(id: id, presetId: preset.id, date: date)), creating: meal)
    }
    guard saved else { return .failed }
    lastPresetLog = (preset.id, uptime())
    return .logged
  }

  func endConfirm() {
    confirmingPreset = nil
    confirmStarted = nil
  }

  @discardableResult
  func savePreset(_ draft: MealDraft, editing existing: MealPresetRecord?) async -> Bool {
    guard draft.isComplete, let calories = draft.calories, !isSaving else { return false }
    let id = existing?.id ?? UUID()
    let record = MealPresetRecord(id: id, name: draft.trimmedName, calories: calories, mealType: .known(draft.mealType), note: existing?.note)
    return await write(String(localized: "Preset saved.", table: "Log")) { context, _, _ in
      guard existing != nil else {
        try await context.writer.issue(.mealSavePreset(RecordReference(id: id)), creating: record)
        return
      }
      try await context.writer.write { issuer, transaction in
        try issuer.issue(.mealPresetUpdate(RecordReference(id: id)), content: record, in: &transaction)
        try MealPresetRecord.edit(id: id, in: &transaction) { $0 = record }
      }
    }
  }

  /// A logged meal keeps the numbers it was logged with, so deleting a preset changes no past meal.
  @discardableResult
  func deletePreset(_ preset: MealPresetRecord) async -> Bool {
    guard !isSaving else { return false }
    return await write(String(localized: "Preset deleted.", table: "Log")) { context, _, _ in
      try await context.writer.write { issuer, transaction in
        try issuer.issue(.mealPresetDelete(RecordReference(id: preset.id)), in: &transaction)
        _ = try MealPresetRecord.remove(MealPresetRecord.ref(preset.id), in: &transaction)
      }
    }
  }

  private func write(_ success: String, _ body: (MemoirScreenContext, LocalDate, Int64) async throws -> Void) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    failure = nil
    confirmation = nil
    do {
      let today = try await context.today()
      try await body(context, today.date, MemoirClock.millis(context.clock.now()))
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
    confirmation = success
    return true
  }
}
