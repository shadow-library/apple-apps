import MemoirCore
import Testing

@Suite("Recurrence vectors", TestTimeLimit.standard)
struct RecurrenceVectorTests {
  @Test("should expand every spec and seeded rule as the reference does, with or without a cursor")
  func expansions() throws {
    try CalendarVectors.check("recurrence.json", "expandRecurrence") { input in
      let rule = try input["rule"].recurrenceRule
      let cursor = try input.optionalMember("cursor")?.occurrence
      return FixtureValue(rule.expand(from: try input["from"].localDate, through: try input["to"].localDate, resumingAt: cursor))
    }
  }

  @Test("should answer occursOn and the next occurrence as the reference does")
  func pointQueries() throws {
    try CalendarVectors.check("recurrence.json", "occursOn") { input in
      .bool(try input["rule"].recurrenceRule.occurs(on: try input["date"].localDate, resumingAt: try input.optionalMember("cursor")?.occurrence))
    }
    try CalendarVectors.check("recurrence.json", "nextOccurrenceOnOrAfter") { input in
      FixtureValue(try input["rule"].recurrenceRule.nextOccurrence(onOrAfter: try input["date"].localDate, resumingAt: try input.optionalMember("cursor")?.occurrence))
    }
  }

  @Test("should advance subscription due dates as the reference does")
  func subscriptionCycles() throws {
    try CalendarVectors.check("subscription.json", "advanceDueDate") { input in
      let frequency: BillingFrequency =
        switch try input["frequency"].string {
        case "weekly": .weekly
        case "monthly": .monthly
        case "quarterly": .quarterly
        case "yearly": .yearly
        case "custom": .custom(intervalDays: try input["customIntervalDays"].optionalInt)
        default: throw FixtureError.malformed("\(input) has no billing frequency")
        }
      let cycle = try SubscriptionCycle(frequency: frequency, billingDay: try input["billingDay"].int)
      return FixtureValue(try require(cycle.advanceDueDate(from: try input["from"].localDate), "\(input) leaves the range"))
    }
  }
}
