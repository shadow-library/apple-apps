import Foundation
import MemoirCore

/// A Health sample as HealthKit gives it: the instants, the zone it was recorded in when its metadata names one, and a quantity already in the built-in
/// metric's unit. An asleep stage or a workout carries no quantity.
nonisolated struct HealthRawSample: Sendable, Hashable {
  let id: UUID
  let start: Date
  let end: Date
  let recordedZone: TimeZone?
  let quantity: Double?
}

nonisolated struct HealthRawChanges: Sendable, Hashable {
  let added: [HealthRawSample]
  let deleted: [UUID]
  let anchor: Data
}

/// What the Health reader asks of HealthKit, so the reader can be tested without it. HealthKit never says whether reading a type was refused: a refused
/// type answers like an empty one.
protocol HealthSampleSource: Sendable {
  func requestReading(_ sources: Set<HealthSource>) async throws(HealthReadError)
  /// The statistics total over `[start, end)`, merging overlapping sources; nil when nothing was recorded.
  func sum(of total: HealthTotal, from start: Date, to end: Date) async throws(HealthReadError) -> Double?
  /// Samples added and ids deleted since `anchor`; without one, samples starting at or after `since`.
  func changes(of kind: HealthSampleKind, after anchor: Data?, since: Date) async throws(HealthReadError) -> HealthRawChanges
}

/// HealthKit's doubles as the exact decimals the metric days hold, rounded half away from zero to the places each metric is shown with.
nonisolated enum HealthValueText {
  static func places(of total: HealthTotal) -> Int {
    switch total {
    case .stepCount, .activeEnergy, .dietaryWater: 0
    }
  }

  static func places(of kind: HealthSampleKind) -> Int {
    switch kind {
    case .bodyMass: 2
    case .waistCircumference: 1
    case .restingHeartRate, .sleep, .workout: 0
    }
  }

  /// Nil for a value that is not finite, is negative, or does not fit.
  static func decimal(_ value: Double, places: Int) -> DecimalText? {
    guard value.isFinite, value >= 0 else { return nil }
    let scale = (0..<places).reduce(1.0) { result, _ in result * 10 }
    let scaled = (value * scale).rounded(.toNearestOrAwayFromZero)
    guard scaled < 1e17, let units = Int64(exactly: scaled) else { return nil }
    var digits = String(units)
    guard places > 0 else { return DecimalText(digits) }
    if digits.count <= places { digits = String(repeating: "0", count: places - digits.count + 1) + digits }
    var fraction = digits.suffix(places)
    while fraction.last == "0" { fraction = fraction.dropLast() }
    let whole = digits.dropLast(places)
    return DecimalText(fraction.isEmpty ? String(whole) : "\(whole).\(fraction)")
  }
}
