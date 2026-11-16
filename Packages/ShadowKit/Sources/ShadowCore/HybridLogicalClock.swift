import Foundation
import Synchronization

private enum CivilCalendar {
  static let millisPerDay: Int64 = 86_400_000

  static func isLeap(_ year: Int64) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  static func daysIn(month: Int64, year: Int64) -> Int64 {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
    let shifted = month <= 2 ? year - 1 : year
    let era = (shifted >= 0 ? shifted : shifted - 399) / 400
    let yearOfEra = shifted - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
    let shifted = days + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return (year, month, day)
  }
}

public struct HLCTimestamp: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
  public static let maxWallMillis: Int64 = 253_402_300_799_999

  private static let hexDigits = Array("0123456789abcdef".utf8)
  private static let textLength = 66

  public let wallMillis: Int64
  public let counter: UInt16
  public let replica: ReplicaID

  public init?(wallMillis: Int64, counter: UInt16, replica: ReplicaID) {
    guard (0...Self.maxWallMillis).contains(wallMillis) else { return nil }
    self.wallMillis = wallMillis
    self.counter = counter
    self.replica = replica
  }

  fileprivate init(clampingWallMillis wallMillis: Int64, counter: UInt16, replica: ReplicaID) {
    self.wallMillis = min(max(wallMillis, 0), Self.maxWallMillis)
    self.counter = counter
    self.replica = replica
  }

  public init?(_ description: String) {
    let bytes = Array(description.utf8)
    guard bytes.count == Self.textLength else { return nil }
    let separators: [(Int, UInt8)] = [(4, 0x2D), (7, 0x2D), (10, 0x54), (13, 0x3A), (16, 0x3A), (19, 0x2E), (23, 0x5A), (24, 0x2D), (29, 0x2D)]
    guard separators.allSatisfy({ bytes[$0.0] == $0.1 }) else { return nil }
    guard
      let year = Self.digits(bytes, 0..<4), let month = Self.digits(bytes, 5..<7), let day = Self.digits(bytes, 8..<10),
      let hour = Self.digits(bytes, 11..<13), let minute = Self.digits(bytes, 14..<16), let second = Self.digits(bytes, 17..<19),
      let millis = Self.digits(bytes, 20..<23), let counter = Self.hex(bytes, 25..<29),
      (1...12).contains(month), (1...CivilCalendar.daysIn(month: month, year: year)).contains(day), hour < 24, minute < 60, second < 60,
      let replica = ReplicaID(String(decoding: bytes[30...], as: UTF8.self))
    else { return nil }
    let days = CivilCalendar.daysFromCivil(year: year, month: month, day: day)
    let wall = days * CivilCalendar.millisPerDay + ((hour * 60 + minute) * 60 + second) * 1_000 + millis
    self.init(wallMillis: wall, counter: UInt16(counter), replica: replica)
  }

  public var description: String {
    let days = wallMillis / CivilCalendar.millisPerDay
    let millisOfDay = wallMillis % CivilCalendar.millisPerDay
    let date = CivilCalendar.civilFromDays(days)
    let seconds = millisOfDay / 1_000
    var bytes: [UInt8] = []
    bytes.reserveCapacity(Self.textLength)
    Self.append(date.year, width: 4, to: &bytes)
    bytes.append(0x2D)
    Self.append(date.month, width: 2, to: &bytes)
    bytes.append(0x2D)
    Self.append(date.day, width: 2, to: &bytes)
    bytes.append(0x54)
    Self.append(seconds / 3_600, width: 2, to: &bytes)
    bytes.append(0x3A)
    Self.append(seconds / 60 % 60, width: 2, to: &bytes)
    bytes.append(0x3A)
    Self.append(seconds % 60, width: 2, to: &bytes)
    bytes.append(0x2E)
    Self.append(millisOfDay % 1_000, width: 3, to: &bytes)
    bytes.append(0x5A)
    bytes.append(0x2D)
    for shift in stride(from: 12, through: 0, by: -4) { bytes.append(Self.hexDigits[Int((counter >> UInt16(shift)) & 0xF)]) }
    bytes.append(0x2D)
    bytes.append(contentsOf: replica.description.utf8)
    return String(decoding: bytes, as: UTF8.self)
  }

  public var date: Date {
    Date(timeIntervalSince1970: Double(wallMillis) / 1_000)
  }

  public static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
    (lhs.wallMillis, lhs.counter, lhs.replica) < (rhs.wallMillis, rhs.counter, rhs.replica)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let timestamp = HLCTimestamp(text) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Timestamp is not in canonical hybrid logical clock form")
    }
    self = timestamp
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  private static func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Int64? {
    var value: Int64 = 0
    for index in range {
      guard (0x30...0x39).contains(bytes[index]) else { return nil }
      value = value * 10 + Int64(bytes[index] - 0x30)
    }
    return value
  }

  private static func hex(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
    var value = 0
    for index in range {
      guard let digit = hexDigits.firstIndex(of: bytes[index]) else { return nil }
      value = value * 16 + digit
    }
    return value
  }

  private static func append(_ value: Int64, width: Int, to bytes: inout [UInt8]) {
    var divisor = Int64(1)
    for _ in 1..<width { divisor *= 10 }
    while divisor > 0 {
      bytes.append(UInt8(value / divisor % 10) + 0x30)
      divisor /= 10
    }
  }
}

public final class HybridLogicalClock: Sendable {
  private struct State {
    var wallMillis: Int64
    var counter: UInt16
    var hasValue: Bool
  }

  public let replica: ReplicaID

  private let wallClock: @Sendable () -> Date
  private let state: Mutex<State>

  public init(replica: ReplicaID, wallClock: @escaping @Sendable () -> Date = { Date() }, latest: HLCTimestamp? = nil) {
    self.replica = replica
    self.wallClock = wallClock
    state = Mutex(State(wallMillis: latest?.wallMillis ?? 0, counter: latest?.counter ?? 0, hasValue: latest != nil))
  }

  public var latest: HLCTimestamp? {
    let snapshot = state.withLock { $0 }
    guard snapshot.hasValue else { return nil }
    return HLCTimestamp(clampingWallMillis: snapshot.wallMillis, counter: snapshot.counter, replica: replica)
  }

  public func now() -> HLCTimestamp {
    let wall = currentWallMillis()
    let issued = state.withLock { state -> (Int64, UInt16) in
      defer { state.hasValue = true }
      if !state.hasValue || wall > state.wallMillis {
        state.wallMillis = wall
        state.counter = 0
      } else if state.counter < UInt16.max {
        state.counter += 1
      } else if state.wallMillis < HLCTimestamp.maxWallMillis {
        state.wallMillis += 1
        state.counter = 0
      }
      return (state.wallMillis, state.counter)
    }
    return HLCTimestamp(clampingWallMillis: issued.0, counter: issued.1, replica: replica)
  }

  public func observe(_ remote: HLCTimestamp) {
    state.withLock { state in
      defer { state.hasValue = true }
      guard state.hasValue else {
        state.wallMillis = remote.wallMillis
        state.counter = remote.counter
        return
      }
      guard (remote.wallMillis, remote.counter) > (state.wallMillis, state.counter) else { return }
      state.wallMillis = remote.wallMillis
      state.counter = remote.counter
    }
  }

  private func currentWallMillis() -> Int64 {
    let millis = (wallClock().timeIntervalSince1970 * 1_000).rounded(.down)
    guard millis >= 0 else { return 0 }
    guard millis < Double(HLCTimestamp.maxWallMillis) else { return HLCTimestamp.maxWallMillis }
    return Int64(millis)
  }
}
