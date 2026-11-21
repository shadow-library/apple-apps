import Foundation
import ShadowCore

/// Cumulative quantities, read as HealthKit statistics totals, which merge overlapping sources (a phone and a watch counting the same steps).
public enum HealthTotal: String, CaseIterable, Sendable {
  case stepCount = "step_count"
  case activeEnergy = "active_energy"
  case dietaryWater = "dietary_water"
}

/// Samples read through anchored queries: quantities reduced to the day's latest, intervals (asleep stages, workouts) to their union's minutes.
public enum HealthSampleKind: String, CaseIterable, Sendable {
  case bodyMass = "body_mass"
  case restingHeartRate = "resting_heart_rate"
  case waistCircumference = "waist_circumference"
  case sleep
  case workout

  public var isInterval: Bool {
    switch self {
    case .sleep, .workout: true
    case .bodyMass, .restingHeartRate, .waistCircumference: false
    }
  }
}

/// One local day as instants: from the day's first instant to the next day's, so a daylight-saving day spans 23 or 25 hours.
public struct HealthWindow: Sendable, Hashable {
  public let date: LocalDate
  public let startMillis: Int64
  public let endMillis: Int64

  public init(date: LocalDate, startMillis: Int64, endMillis: Int64) {
    self.date = date
    self.startMillis = startMillis
    self.endMillis = endMillis
  }

  public init(_ date: LocalDate, in clock: IssueClock) throws(CalendarError) {
    guard let next = date.adding(days: 1) else { throw .dateOutOfRange }
    self.init(date: date, startMillis: try clock.startOfDay(date), endMillis: try clock.startOfDay(next))
  }
}

/// A Health sample as recorded: `utcOffsetMinutes` is the offset where it was recorded (the sample's time-zone metadata, else the reading device's zone at
/// its start), so its day never depends on the zone the device is in when it reads. A quantity is in its built-in metric's unit; an asleep stage or a
/// workout carries none. An edit in Health arrives as a deletion and an addition.
public struct HealthSample: Sendable, Hashable {
  public let id: UUID
  public let startMillis: Int64
  public let endMillis: Int64
  public let utcOffsetMinutes: Int
  public let quantity: DecimalText?

  public init(id: UUID, startMillis: Int64, endMillis: Int64, utcOffsetMinutes: Int, quantity: DecimalText? = nil) {
    self.id = id
    self.startMillis = startMillis
    self.endMillis = endMillis
    self.utcOffsetMinutes = utcOffsetMinutes
    self.quantity = quantity
  }
}

/// HealthKit's query anchor, archived by the reader; meaningful only on the device that made it.
public struct HealthAnchor: Sendable, Hashable {
  public let data: Data

  public init(data: Data) {
    self.data = data
  }
}

public struct HealthSampleChanges: Sendable, Hashable {
  public let added: [HealthSample]
  public let deleted: [UUID]
  public let anchor: HealthAnchor

  public init(added: [HealthSample], deleted: [UUID], anchor: HealthAnchor) {
    self.added = added
    self.deleted = deleted
    self.anchor = anchor
  }
}

public enum HealthReadError: ShadowError, Equatable {
  case unavailable
  case protectedDataUnavailable
  case failed(String)

  public var code: String {
    switch self {
    case .unavailable: "memoir_health.unavailable"
    case .protectedDataUnavailable: "memoir_health.protected_data_unavailable"
    case .failed: "memoir_health.failed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unavailable: "Health data is not available on this device."
    case .protectedDataUnavailable: "Health data cannot be read while the device is locked."
    case .failed(let reason): "Reading Health failed: \(reason)"
    }
  }
}

/// Read-only access to Apple Health, implemented in the app target with HealthKit. HealthKit does not say whether reading a type was refused: a refusal
/// reads as no data.
public protocol HealthReader: Sendable {
  /// The total over each window, in the built-in metric's unit; a window without samples is left out.
  func totals(of quantity: HealthTotal, in windows: [HealthWindow]) async throws(HealthReadError) -> [LocalDate: DecimalText]

  /// Samples added and ids deleted since `anchor`, and the anchor to resume from. Without an anchor, only samples starting at or after `since` are needed.
  func changes(of kind: HealthSampleKind, after anchor: HealthAnchor?, since startMillis: Int64) async throws(HealthReadError) -> HealthSampleChanges
}
