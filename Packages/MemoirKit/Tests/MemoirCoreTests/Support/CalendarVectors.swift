import Foundation
import MemoirCore
import Testing

struct ZoneExclusion: Decodable {
  let function: String
  let id: String
  let reason: String
}

struct ZoneExclusionList: Decodable {
  let tzdata: String
  let count: Int
  let cases: [ZoneExclusion]
}

struct CalendarDivergence: Decodable {
  let function: String
  let input: String
  let reference: Int
  let exact: Int
  let reason: String
}

struct CalendarDivergenceList: Decodable {
  let count: Int
  let cases: [CalendarDivergence]
}

enum CalendarVectors {
  static func load<Value: Decodable>(_ type: Value.Type, _ file: String) throws -> Value {
    try JSONDecoder().decode(type, from: RuleVectors.data("calendar/\(file)"))
  }

  static func cases(_ file: String, _ function: String) throws -> [RuleCase] {
    let groups = try load([String: [RuleCase]].self, file)
    guard let cases = groups[function], !cases.isEmpty else { throw FixtureError.malformed("\(file) has no \(function) cases") }
    return cases
  }

  /// Every vector must agree with the reference exactly, except a zone case listed in `zone-exclusions.json`, which is skipped and must exist.
  static func check(
    _ file: String, _ function: String, sourceLocation: SourceLocation = #_sourceLocation, evaluate: (FixtureValue) throws -> FixtureValue
  ) throws {
    let excluded = Set(try load(ZoneExclusionList.self, "zone-exclusions.json").cases.filter { $0.function == function }.map(\.id))
    let vectors = try cases(file, function)
    var mismatches: [String] = []
    for vector in vectors where !excluded.contains(vector.id) {
      let native: FixtureValue
      do {
        native = try evaluate(vector.input)
      } catch let error as CalendarError {
        native = .string("error: \(error.code)")
      }
      if native != vector.output { mismatches.append("\(vector.id): native \(native) reference \(vector.output) for \(vector.input)") }
    }
    #expect(excluded.isSubset(of: Set(vectors.map(\.id))), "zone exclusions name vectors that do not exist", sourceLocation: sourceLocation)
    #expect(mismatches.isEmpty, "\(mismatches.count) of \(vectors.count) mismatch, first: \(mismatches.prefix(10).joined(separator: "\n"))", sourceLocation: sourceLocation)
  }
}

extension FixtureValue {
  var localDate: LocalDate {
    get throws {
      guard let date = LocalDate(isoString: try string) else { throw FixtureError.malformed("\(self) is not a yyyy-MM-dd date") }
      return date
    }
  }

  var int64: Int64 {
    get throws { Int64(try int) }
  }

  var weekday: LocalDate.Weekday {
    get throws {
      guard let weekday = LocalDate.Weekday(rawValue: try int) else { throw FixtureError.malformed("\(self) is not an ISO weekday") }
      return weekday
    }
  }

  var ordinal: WeekdayOrdinal {
    get throws {
      switch self {
      case .string("last"): return .last
      case .int(1): return .first
      case .int(2): return .second
      case .int(3): return .third
      case .int(4): return .fourth
      default: throw FixtureError.malformed("\(self) is not a weekday ordinal")
      }
    }
  }

  var occurrence: RecurrenceOccurrence? {
    get throws {
      if case .null = self { return nil }
      return RecurrenceOccurrence(date: try self["date"].localDate, index: try self["index"].int)
    }
  }

  func optionalMember(_ key: String) -> FixtureValue? {
    guard case .object(let members) = self else { return nil }
    return members[key]
  }

  var recurrenceRule: RecurrenceRule {
    get throws {
      let end: RecurrenceEnd =
        switch try self["end"]["kind"].string {
        case "never": .never
        case "count": .count(try self["end"]["count"].int)
        case "until": .until(try self["end"]["date"].localDate)
        default: throw FixtureError.malformed("\(self) has no recurrence end")
        }
      let frequency: RecurrenceRule.Frequency =
        switch try self["frequency"].string {
        case "daily": .daily
        case "weekly": .weekly(Set(try self["daysOfWeek"].array.map { try $0.weekday }))
        case "monthly": .monthly(try monthlyPattern)
        case "yearly": .yearly
        default: throw FixtureError.malformed("\(self) has no recurrence frequency")
        }
      let exceptions = try optionalMember("exceptions")?.array.map { try $0.localDate } ?? []
      return try RecurrenceRule(frequency: frequency, interval: try self["interval"].int, startDate: try self["startDate"].localDate, end: end, exceptions: Set(exceptions))
    }
  }

  private var monthlyPattern: MonthlyPattern {
    get throws {
      let pattern = try self["pattern"]
      return switch try pattern["kind"].string {
      case "day_of_month": .dayOfMonth(try pattern["dayOfMonth"].int)
      case "nth_weekday": .nthWeekday(try pattern["weekday"].weekday, try pattern["ordinal"].ordinal)
      default: throw FixtureError.malformed("\(pattern) is not a monthly pattern")
      }
    }
  }

  init(_ date: LocalDate) {
    self = .string(date.isoString)
  }

  init(_ occurrence: RecurrenceOccurrence?) {
    self = occurrence.map { .object(["date": FixtureValue($0.date), "index": .int($0.index)]) } ?? .null
  }

  init(_ expansion: RecurrenceExpansion) {
    self = .object(["occurrences": .array(expansion.occurrences.map(FixtureValue.init)), "cursor": FixtureValue(expansion.cursor)])
  }

  init(_ instant: Int64) {
    self = .int(Int(instant))
  }
}

func require<Value>(_ value: Value?, _ detail: @autoclosure () -> String) throws -> Value {
  guard let value else { throw FixtureError.malformed(detail()) }
  return value
}
