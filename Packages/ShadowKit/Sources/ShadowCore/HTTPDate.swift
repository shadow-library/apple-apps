import Foundation

enum HTTPDate {
  private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  private static let shortDays: Set<String> = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  private static let longDays: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  static func parse(_ value: String, referenceYear: Int) -> Date? {
    let parts = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if let first = parts.first, first.hasSuffix(",") {
      let name = String(first.dropLast())
      if shortDays.contains(name) { return parseIMF(parts) }
      if longDays.contains(name) { return parseRFC850(parts, referenceYear: referenceYear) }
      return nil
    }
    return parseAsctime(parts)
  }

  static func currentYear(at date: Date) -> Int {
    civil(fromDays: Int((date.timeIntervalSince1970 / 86_400).rounded(.down))).year
  }

  private static func parseIMF(_ parts: [String]) -> Date? {
    guard parts.count == 6, parts[5] == "GMT" else { return nil }
    guard let day = number(parts[1], digits: 1...2), let month = months.firstIndex(of: parts[2]), let year = number(parts[3], digits: 4...4) else { return nil }
    return build(year: year, month: month + 1, day: day, time: parts[4])
  }

  private static func parseRFC850(_ parts: [String], referenceYear: Int) -> Date? {
    guard parts.count == 4, parts[3] == "GMT" else { return nil }
    let dateParts = parts[1].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard dateParts.count == 3 else { return nil }
    guard let day = number(dateParts[0], digits: 1...2), let month = months.firstIndex(of: dateParts[1]), let twoDigitYear = number(dateParts[2], digits: 2...2) else { return nil }
    var year = referenceYear - referenceYear % 100 + twoDigitYear
    if year > referenceYear + 50 { year -= 100 }
    return build(year: year, month: month + 1, day: day, time: parts[2])
  }

  private static func parseAsctime(_ tokens: [String]) -> Date? {
    var parts = tokens
    if parts.count == 6, parts[2].isEmpty, parts[3].utf8.count == 1 { parts.remove(at: 2) }
    guard parts.count == 5, shortDays.contains(parts[0]) else { return nil }
    guard let month = months.firstIndex(of: parts[1]), let day = number(parts[2], digits: 1...2), let year = number(parts[4], digits: 4...4) else { return nil }
    return build(year: year, month: month + 1, day: day, time: parts[3])
  }

  private static func build(year: Int, month: Int, day: Int, time: String) -> Date? {
    let fields = time.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 3 else { return nil }
    guard let hour = number(fields[0], digits: 2...2), let minute = number(fields[1], digits: 2...2), let second = number(fields[2], digits: 2...2) else { return nil }
    guard hour < 24, minute < 60, second < 60 else { return nil }
    guard day >= 1, day <= daysIn(month: month, year: year) else { return nil }
    let seconds = days(fromCivilYear: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second
    return Date(timeIntervalSince1970: TimeInterval(seconds))
  }

  private static func number(_ text: String, digits: ClosedRange<Int>) -> Int? {
    let bytes = Array(text.utf8)
    guard digits.contains(bytes.count), bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
  }

  private static func isLeap(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  private static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  private static func days(fromCivilYear year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return (year, month, day)
  }
}
