import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// The unit weights are typed and shown in. The core keeps kilograms and has no unit setting, so this is the device's own choice.
nonisolated struct WeightUnitPreference: Sendable {
  static let key = "com.shadow.apps.memoir.weight-unit"

  /// Nil for the app's standard defaults; tests name their own suite.
  private let suiteName: String?

  init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

  var unit: WeightUnit {
    get { defaults.string(forKey: Self.key).flatMap(WeightUnit.init(rawValue:)) ?? (Locale.current.measurementSystem == .us ? .pounds : .kilograms) }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
  }
}

/// `features/quick-logs/weight-screen.tsx`: one value a day, the 7-day average, the 90-day change and trend, and "Replace today’s weight?". Weight is
/// health class: it is read from and written to the restricted store only.
@MainActor
@Observable
final class WeightModel {
  /// What saving again would replace, and with what, for the owner to confirm.
  struct Replacement: Equatable {
    let existing: WeightRecord
    let kilograms: DecimalText
  }

  let context: MemoirScreenContext
  let overview = ReadObserver<WeightOverview>()
  let caps = ReadObserver<EntryCapsOverview>()
  var input = ""
  private(set) var problem: String?
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  private(set) var confirmation: String?
  var replacement: Replacement?
  /// The weight a confirmed save replaced this session, by day (`replacedKg`).
  private(set) var replaced: [LocalDate: DecimalText] = [:]
  private let preference: WeightUnitPreference
  private let locale: Locale

  init(context: MemoirScreenContext, preference: WeightUnitPreference = WeightUnitPreference(), locale: Locale = .current) {
    self.context = context
    self.preference = preference
    self.locale = locale
    unit = preference.unit
  }

  var unit: WeightUnit {
    didSet {
      preference.unit = unit
      problem = nil
    }
  }

  func observe() async {
    let context = context
    let stores = context.stores
    let days = LogStreams.days(context)
    async let overview: Void = overview.run { LogStreams.following(days) { today in LogReads.observeWeight(in: stores, today: today) } }
    async let caps: Void = caps.run { LogStreams.entryCaps(context, includeHealth: true) }
    _ = await (overview, caps)
  }

  var advisory: EntryCapAdvisory? { caps.state.value?.advisory(.weight) }

  /// `weightError` (`quick-logs.rules.ts:60-64`), in the unit the owner types.
  func kilograms() -> Result<DecimalText, WeightInputProblem> {
    let parsed: DecimalText
    switch DecimalInput.parse(input, locale: locale) {
    case .failure(.empty): return .failure(.empty)
    case .failure(.notANumber): return .failure(.notANumber)
    case .failure(.negative): return .failure(.outOfRange)
    case .success(let value): parsed = value
    }
    guard let kilograms = WeightConversion.convert(parsed, from: unit, to: .kilograms, places: 2), WeightOverview.isAccepted(kilograms) else {
      return .failure(.outOfRange)
    }
    return .success(kilograms)
  }

  /// Saving a day that already has a weight asks first; a confirmed save replaces it and earns nothing more.
  @discardableResult
  func save(confirmingReplacement: Bool = false) async -> Bool {
    guard !isSaving else { return false }
    let replacing = confirmingReplacement ? replacement : nil
    let typed = replacing.map { Result<DecimalText, WeightInputProblem>.success($0.kilograms) } ?? kilograms()
    let kilograms: DecimalText
    switch typed {
    case .failure(let problem):
      self.problem = problem.message(in: unit, locale: locale)
      return false
    case .success(let value): kilograms = value
    }
    problem = nil
    replacement = nil
    isSaving = true
    defer { isSaving = false }
    failure = nil
    confirmation = nil
    let outcome: WeightSave
    do {
      let today = try await context.today()
      outcome = try await context.writer.quickLogs.saveWeight(kilograms, on: today.date, confirmedReplacement: replacing != nil)
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
    switch outcome {
    case .needsConfirmation(let existing):
      replacement = Replacement(existing: existing, kilograms: kilograms)
      return false
    case .saved:
      if let replacing { replaced[replacing.existing.date] = replacing.existing.kilograms }
      confirmation = String(localized: "\(LogFormat.weight(kilograms, in: unit)) saved.", table: "Log")
      input = ""
      return true
    }
  }

  func cancelReplacement() {
    replacement = nil
  }
}

nonisolated enum WeightInputProblem: Error, Equatable, Sendable {
  case empty
  case notANumber
  case outOfRange

  func message(in unit: WeightUnit, locale: Locale = .current) -> String {
    switch self {
    case .empty: return String(localized: "Enter a weight to save.", table: "Log")
    case .notANumber: return String(localized: "Use digits only, like \(DecimalInput.example(whole: 72, fraction: 4, locale: locale)).", table: "Log")
    case .outOfRange:
      let range = WeightOverview.acceptedKilograms
      let low = DecimalText(String(range.lowerBound)).map { LogFormat.weight($0, in: unit) } ?? ""
      let high = DecimalText(String(range.upperBound)).map { LogFormat.weight($0, in: unit) } ?? ""
      return String(localized: "Weight is between \(low) and \(high).", table: "Log")
    }
  }
}
