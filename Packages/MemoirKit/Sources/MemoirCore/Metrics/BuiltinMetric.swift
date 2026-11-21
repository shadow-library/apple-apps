import Foundation
import ShadowCore
import ShadowStore

extension SyncClass {
  var metricClass: any MetricClass.Type {
    switch self {
    case .general: GeneralMetric.self
    case .activity: ActivityMetric.self
    case .health: HealthMetric.self
    }
  }
}

/// Where a built-in metric's Health values come from: a statistics total per day, or samples reduced to one value per day.
public enum HealthSource: Sendable, Hashable {
  case total(HealthTotal)
  case samples(HealthSampleKind)
}

/// The built-in metrics and their fixed classes. Active energy is health class, though the plan lists only steps and workouts as Activity: Health
/// computes it from heart rate and body mass. Each has a derived id, so every device seeds the same record and two seeds converge. The reference's
/// built-ins are steps, calories burned, sleep and water; outcomes (a quest completed because a threshold was crossed) are quest completions, general
/// class by construction, so no built-in metric is general.
public enum BuiltinMetric: String, CaseIterable, Sendable {
  case steps
  case activeEnergy = "active_energy"
  case workoutMinutes = "workout_minutes"
  case weight
  case restingHeartRate = "resting_heart_rate"
  case sleep
  case waistCircumference = "waist_circumference"
  case water

  public static let idDomain = "com.shadow.library.memoircore.builtin-metric"

  private static let byID = Dictionary(uniqueKeysWithValues: allCases.map { ($0.id, $0) })

  public init?(id: UUID) {
    guard let metric = Self.byID[id] else { return nil }
    self = metric
  }

  public var id: UUID { derivedID(Self.idDomain, rawValue) }

  public var syncClass: SyncClass {
    switch self {
    case .steps, .workoutMinutes: .activity
    case .activeEnergy, .weight, .restingHeartRate, .sleep, .waistCircumference, .water: .health
    }
  }

  public var reference: MetricReference { MetricReference(id: id, metricClass: syncClass) }

  public var healthSource: HealthSource {
    switch self {
    case .steps: .total(.stepCount)
    case .activeEnergy: .total(.activeEnergy)
    case .water: .total(.dietaryWater)
    case .workoutMinutes: .samples(.workout)
    case .weight: .samples(.bodyMass)
    case .restingHeartRate: .samples(.restingHeartRate)
    case .sleep: .samples(.sleep)
    case .waistCircumference: .samples(.waistCircumference)
    }
  }

  /// Sleep is kept in whole minutes, where the reference's built-in counts hours, so integer arithmetic holds it exactly; a sleep threshold is in minutes.
  public var definition: MetricDefinition {
    switch self {
    case .steps: MetricDefinition(name: "Steps", unit: "steps", valueType: .count, direction: .higher)
    case .activeEnergy: MetricDefinition(name: "Calories burned", unit: "kcal", valueType: .number, direction: .higher)
    case .workoutMinutes: MetricDefinition(name: "Workout minutes", unit: "min", valueType: .duration, direction: .higher)
    case .weight: MetricDefinition(name: "Weight", unit: "kg", valueType: .number, direction: .neutral)
    case .restingHeartRate: MetricDefinition(name: "Resting heart rate", unit: "bpm", valueType: .number, direction: .lower)
    case .sleep: MetricDefinition(name: "Sleep duration", unit: "min", valueType: .duration, direction: .higher)
    case .waistCircumference: MetricDefinition(name: "Waist circumference", unit: "cm", valueType: .number, direction: .lower)
    case .water: MetricDefinition(name: "Water", unit: "ml", valueType: .number, direction: .higher)
    }
  }

  /// Writes the built-in's record unless the store already holds it, readable or not.
  static func seed<Class: MetricClass>(_ metric: MetricID<Class>, in transaction: inout WriteTransaction) throws(MemoirRecordError) {
    guard let builtin = BuiltinMetric(id: metric.recordUUID), builtin.syncClass == Class.syncClass else { return }
    let absent: Bool
    do throws(StoreError) {
      absent = try MetricRecord<Class>.read(id: metric, in: transaction) == .absent
    } catch {
      throw .store(error)
    }
    guard absent else { return }
    try builtin.definition.record(metric).create(in: &transaction)
  }
}

public struct MetricDefinition: Sendable, Hashable {
  public var name: String
  public var unit: String?
  public var valueType: MetricValueType
  public var direction: MetricDirection
  public var defaultValue: DecimalText?
  public var glyph: String?

  public init(name: String, unit: String? = nil, valueType: MetricValueType, direction: MetricDirection, defaultValue: DecimalText? = nil, glyph: String? = nil) {
    self.name = name
    self.unit = unit
    self.valueType = valueType
    self.direction = direction
    self.defaultValue = defaultValue
    self.glyph = glyph
  }

  func record<Class: MetricClass>(_ id: MetricID<Class>) -> MetricRecord<Class> {
    MetricRecord(id: id, name: name, unit: unit, valueType: .known(valueType), direction: .known(direction), defaultValue: defaultValue, glyph: glyph)
  }
}
