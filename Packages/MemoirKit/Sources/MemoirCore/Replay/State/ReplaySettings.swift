import Foundation

public struct SettingChange<Value: Sendable & Hashable>: Sendable, Hashable {
  public let firstDay: LocalDate
  public let value: Value
  public let command: UUID
  /// The command's place in replay order, which breaks a tie between two changes for the same first day.
  public let order: Int
}

/// A staged change the day walk has not yet promoted.
public struct PendingSetting<Value: Sendable & Hashable>: Sendable, Hashable {
  public let value: Value
  public let command: UUID
  public let order: Int
  /// The offset the command was issued under, the zone's that was in force, which tells the day walk where that zone's day ends.
  public let utcOffsetMinutes: Int

  func promoted(on firstDay: LocalDate) -> SettingChange<Value> {
    SettingChange(firstDay: firstDay, value: value, command: command, order: order)
  }
}

/// The account settings replay reads, each a list of changes with the day it takes effect, and the staged changes the walk promotes on the next day it
/// prepares. On a day, the change with the latest first day not after it governs, and of two for the same day the later in replay order.
public struct ReplaySettings: Sendable, Hashable {
  public static let empty = ReplaySettings()

  public internal(set) var timeZones: [SettingChange<String>] = []
  public internal(set) var intensityModes: [SettingChange<IntensityMode>] = []
  public internal(set) var returnerThresholds: [SettingChange<Int>] = []
  public internal(set) var pendingTimeZone: PendingSetting<String>?
  public internal(set) var pendingIntensityMode: PendingSetting<IntensityMode>?

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

  mutating func promotePending(on date: LocalDate) {
    if let zone = pendingTimeZone { timeZones.append(zone.promoted(on: date)) }
    if let mode = pendingIntensityMode { intensityModes.append(mode.promoted(on: date)) }
    pendingTimeZone = nil
    pendingIntensityMode = nil
  }

  private static func value<Value>(in changes: [SettingChange<Value>], on date: LocalDate) -> Value? {
    changes.filter { $0.firstDay <= date }.max { ($0.firstDay, $0.order) < ($1.firstDay, $1.order) }?.value
  }
}
