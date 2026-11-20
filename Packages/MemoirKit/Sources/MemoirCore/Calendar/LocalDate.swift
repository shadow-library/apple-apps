public struct LocalDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
  public enum Weekday: Int, Sendable, CaseIterable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday
  }

  public static let earliest = LocalDate(unchecked: civilToDays(year: 0, month: 1, day: 1))
  public static let latest = LocalDate(unchecked: civilToDays(year: 9999, month: 12, day: 31))

  public let daysSinceEpoch: Int

  public init?(daysSinceEpoch: Int) {
    guard (Self.earliest.daysSinceEpoch...Self.latest.daysSinceEpoch).contains(daysSinceEpoch) else { return nil }
    self.daysSinceEpoch = daysSinceEpoch
  }

  public init?(year: Int, month: Int, day: Int) {
    guard (0...9999).contains(year), (1...12).contains(month), (1...Self.daysInMonth(year: year, month: month)).contains(day) else { return nil }
    daysSinceEpoch = Self.civilToDays(year: year, month: month, day: day)
  }

  public init?(isoString: String) {
    let bytes = Array(isoString.utf8)
    guard bytes.count == 10, bytes[4] == Self.hyphen, bytes[7] == Self.hyphen else { return nil }
    guard let year = Self.number(bytes[0..<4]), let month = Self.number(bytes[5..<7]), let day = Self.number(bytes[8..<10]) else { return nil }
    self.init(year: year, month: month, day: day)
  }

  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard let date = LocalDate(isoString: string) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\"\(string)\" is not a yyyy-MM-dd date."))
    }
    self = date
  }

  private init(unchecked daysSinceEpoch: Int) {
    self.daysSinceEpoch = daysSinceEpoch
  }

  public var year: Int { civil.year }
  public var month: Int { civil.month }
  public var day: Int { civil.day }

  public var weekday: Weekday {
    let index = (daysSinceEpoch + 3) % 7
    return Weekday(rawValue: (index < 0 ? index + 7 : index) + 1) ?? .monday
  }

  public var isoString: String {
    "\(Self.padded(year, width: 4))-\(Self.padded(month, width: 2))-\(Self.padded(day, width: 2))"
  }

  public var description: String { isoString }

  public static func isLeapYear(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  public static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2: isLeapYear(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
    lhs.daysSinceEpoch < rhs.daysSinceEpoch
  }

  public func adding(days: Int) -> LocalDate? {
    let (sum, overflow) = daysSinceEpoch.addingReportingOverflow(days)
    return overflow ? nil : LocalDate(daysSinceEpoch: sum)
  }

  public func days(since other: LocalDate) -> Int {
    daysSinceEpoch - other.daysSinceEpoch
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(isoString)
  }

  private static let hyphen = UInt8(ascii: "-")

  private var civil: (year: Int, month: Int, day: Int) {
    let shifted = daysSinceEpoch + 719_468
    let era = Self.floorDivide(shifted, 146_097)
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }

  private static func civilToDays(year: Int, month: Int, day: Int) -> Int {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = floorDivide(shiftedYear, 400)
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
    value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
  }

  private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
    digits.reduce(into: 0 as Int?) { result, byte in
      guard let value = result, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
        result = nil
        return
      }
      result = value * 10 + Int(byte - UInt8(ascii: "0"))
    }
  }

  private static func padded(_ value: Int, width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }
}
