import Foundation

public struct SettingChange<Value: Sendable & Hashable>: Sendable, Hashable {
  public let firstDay: LocalDate
  public let value: Value
  public let command: UUID
  /// The command's place in replay order, which breaks a tie between two changes for the same first day.
  public let order: Int
}

/// The account settings replay reads, each a list of changes with the day it takes effect. On a day, the change with the latest first day not after it
/// governs, and of two for the same day the later in replay order, so a change dated earlier that arrives late never overrides a later one.
public struct ReplaySettings: Sendable, Hashable {
  public static let empty = ReplaySettings()

  public internal(set) var timeZones: [SettingChange<String>] = []
  public internal(set) var intensityModes: [SettingChange<IntensityMode>] = []
  public internal(set) var returnerThresholds: [SettingChange<Int>] = []

  public func timeZone(on date: LocalDate) -> String? {
    Self.value(in: timeZones, on: date)
  }

  public func intensityMode(on date: LocalDate) -> IntensityMode {
    Self.value(in: intensityModes, on: date) ?? .standard
  }

  /// Nil while the ruleset's default threshold applies.
  public func returnerThresholdDays(on date: LocalDate) -> Int? {
    Self.value(in: returnerThresholds, on: date)
  }

  private static func value<Value>(in changes: [SettingChange<Value>], on date: LocalDate) -> Value? {
    changes.filter { $0.firstDay <= date }.max { ($0.firstDay, $0.order) < ($1.firstDay, $1.order) }?.value
  }
}
