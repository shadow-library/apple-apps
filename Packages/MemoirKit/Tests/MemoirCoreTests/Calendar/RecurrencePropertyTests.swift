import MemoirCore
import ShadowTestSupport
import Testing

@Suite("Recurrence properties", TestTimeLimit.property)
struct RecurrencePropertyTests {
  private static let firstStart = LocalDate(year: 1900, month: 1, day: 1)!

  private static func date(_ generator: inout SeededGenerator, from: LocalDate, days: ClosedRange<Int>) throws -> LocalDate {
    try #require(from.adding(days: generator.int(in: days)))
  }

  private static func rule(_ generator: inout SeededGenerator) throws -> RecurrenceRule {
    let start = try date(&generator, from: firstStart, days: 0...73_000)
    let weekdays = Set((0..<generator.int(in: 1...4)).map { _ in generator.pick(from: LocalDate.Weekday.allCases) })
    let frequency: RecurrenceRule.Frequency =
      switch generator.int(in: 0...4) {
      case 0: .daily
      case 1: .weekly(weekdays)
      case 2: .monthly(.dayOfMonth(generator.pick(from: [1, 15, 28, 29, 30, 31, 40])))
      case 3: .monthly(.nthWeekday(generator.pick(from: LocalDate.Weekday.allCases), generator.pick(from: WeekdayOrdinal.allCases)))
      default: .yearly
      }
    let end: RecurrenceEnd =
      switch generator.int(in: 0...2) {
      case 0: .never
      case 1: .count(generator.int(in: -1...40))
      default: .until(try date(&generator, from: start, days: -10...900))
      }
    let exceptions = try Set((0..<generator.int(in: 0...4)).map { _ in try date(&generator, from: start, days: 0...200) })
    return try RecurrenceRule(frequency: frequency, interval: generator.int(in: -1...4), startDate: start, end: end, exceptions: exceptions)
  }

  @Test("should resume an expansion from its own cursor exactly as a full expansion, whatever the split")
  func cursorResumptionEqualsFullExpansion() throws {
    try forAll(iterations: 400) { generator in
      let rule = try Self.rule(&generator)
      let from = try Self.date(&generator, from: rule.startDate, days: -30...200)
      let through = try Self.date(&generator, from: from, days: 0...800)
      let full = rule.expand(from: from, through: through)
      var resumed: [RecurrenceOccurrence] = []
      var cursor: RecurrenceOccurrence?
      var windowStart = from
      while windowStart <= through {
        let windowEnd = min(try Self.date(&generator, from: windowStart, days: 0...90), through)
        let part = rule.expand(from: windowStart, through: windowEnd, resumingAt: cursor)
        resumed += part.occurrences
        cursor = part.cursor ?? cursor
        guard let next = windowEnd.adding(days: 1) else { break }
        windowStart = next
      }
      #expect(resumed == full.occurrences, "\(rule)")
      #expect(cursor == full.cursor, "\(rule)")
    }
  }

  @Test("should answer point queries the same with a cursor from an earlier window as without")
  func cursorPointQueries() throws {
    try forAll(iterations: 300) { generator in
      let rule = try Self.rule(&generator)
      let boundary = try Self.date(&generator, from: rule.startDate, days: 0...400)
      let cursor = rule.expand(from: rule.startDate, through: boundary).cursor
      for _ in 0..<10 {
        let probe = try Self.date(&generator, from: boundary, days: 1...500)
        #expect(rule.occurs(on: probe, resumingAt: cursor) == rule.occurs(on: probe), "\(rule) at \(probe)")
        #expect(rule.nextOccurrence(onOrAfter: probe, resumingAt: cursor) == rule.nextOccurrence(onOrAfter: probe), "\(rule) from \(probe)")
      }
    }
  }

  @Test("should number occurrences densely from zero, never past COUNT or UNTIL, and let exceptions keep their index")
  func occurrenceIndices() throws {
    try forAll(iterations: 300) { generator in
      let rule = try Self.rule(&generator)
      let through = try Self.date(&generator, from: rule.startDate, days: 0...900)
      let withoutExceptions = try RecurrenceRule(frequency: rule.frequency, interval: rule.interval, startDate: rule.startDate, end: rule.end)
      let raw = withoutExceptions.expand(from: rule.startDate, through: through).occurrences
      #expect(raw.map(\.index) == Array(raw.indices))
      #expect(raw.allSatisfy { $0.date >= rule.startDate })
      #expect(zip(raw, raw.dropFirst()).allSatisfy { $0.date < $1.date })
      switch rule.end {
      case .count(let count): #expect(raw.count <= max(0, count))
      case .until(let date): #expect(raw.allSatisfy { $0.date <= date })
      case .never: break
      }
      #expect(rule.expand(from: rule.startDate, through: through).occurrences == raw.filter { !rule.exceptions.contains($0.date) })
    }
  }
}
