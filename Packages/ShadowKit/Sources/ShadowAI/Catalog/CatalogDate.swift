import Foundation

public struct CatalogDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  public init?(year: Int, month: Int, day: Int) {
    guard (1...9999).contains(year), (1...12).contains(month), day >= 1, day <= Self.daysInMonth(year: year, month: month) else { return nil }
    self.year = year
    self.month = month
    self.day = day
  }

  public init?(_ text: String) {
    let bytes = Array(text.utf8)
    guard bytes.count == 10, bytes[4] == Self.dash, bytes[7] == Self.dash else { return nil }
    let digits = bytes[0..<4] + bytes[5..<7] + bytes[8..<10]
    guard digits.allSatisfy({ (Self.zero...Self.nine).contains($0) }) else { return nil }
    let number = { (range: Range<Int>) in bytes[range].reduce(0) { $0 * 10 + Int($1 - Self.zero) } }
    self.init(year: number(0..<4), month: number(5..<7), day: number(8..<10))
  }

  public init(_ date: Date) {
    let seconds = date.timeIntervalSince1970
    let rawDays = seconds.isFinite ? (seconds / Self.secondsPerDay).rounded(.down) : 0
    let days = Int(min(max(rawDays, Double(Self.firstDay)), Double(Self.lastDay)))
    let (year, month, day) = Self.civil(fromDays: days)
    self.year = year
    self.month = month
    self.day = day
  }

  public var description: String {
    let pad = { (value: Int, width: Int) in String(repeating: "0", count: max(0, width - String(value).count)) + String(value) }
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
  }

  public func days(until other: CatalogDate) -> Int {
    Self.days(year: other.year, month: other.month, day: other.day) - Self.days(year: year, month: month, day: day)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let date = CatalogDate(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a calendar date as YYYY-MM-DD, found \(text).") }
    self = date
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  public static func < (lhs: CatalogDate, rhs: CatalogDate) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  private static let dash = UInt8(ascii: "-")
  private static let zero = UInt8(ascii: "0")
  private static let nine = UInt8(ascii: "9")
  private static let secondsPerDay = 86_400.0
  private static let firstDay = days(year: 1, month: 1, day: 1)
  private static let lastDay = days(year: 9999, month: 12, day: 31)

  private static func isLeap(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  private static func days(year: Int, month: Int, day: Int) -> Int {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = shiftedYear / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
    let shifted = days + 719_468
    let era = shifted / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }
}
