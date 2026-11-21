import Foundation
import ShadowStore

/// A quick log whose reward replay decided; its words and values stay in the record of its own class.
public struct QuickLogOutcome: Sendable, Hashable, Codable {
  public let source: QuickLogSource
  public let date: LocalDate
  public let rewarded: Bool
}

/// A metric a command created; deletion only deactivates it, as the reference's does, so later commands still find it.
public struct ReplayMetric: Sendable, Hashable, Codable {
  public let metricClass: SyncClass
  public internal(set) var isActive: Bool
}

/// What replay remembers about the records commands name, to judge later commands without reading the records themselves. A device that holds
/// none of the health- or activity-class records therefore replays the same.
public struct RecordIndex: Sendable, Hashable {
  public static let empty = RecordIndex()

  public internal(set) var quickLogs: [UUID: QuickLogOutcome] = [:]
  public internal(set) var weightDates: Set<LocalDate> = []
  public internal(set) var sideQuestsRewarded: [LocalDate: Int] = [:]
  public internal(set) var mealPresets: Set<UUID> = []
  public internal(set) var metrics: [UUID: ReplayMetric] = [:]
  public internal(set) var expenses: Set<UUID> = []
  public internal(set) var subscriptions: Set<UUID> = []
  public internal(set) var confirmedCycles: Set<CycleConfirmation> = []
}
