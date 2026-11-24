import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Testing

@Suite("Memoir money commands", TestTimeLimit.quick)
struct MoneyCommandTests {
  private static let budget: JSONValue = .string(CommandSamples.budget.lowercasedString)
  private static let goal: JSONValue = .string(CommandSamples.goal.lowercasedString)
  private static let expense: JSONValue = .string(CommandSamples.record.lowercasedString)

  private static func decode(_ kind: MemoirCommandKind, _ payload: [String: JSONValue]) throws(CommandRefusal) -> MemoirCommandBody {
    try MemoirCommandBody(type: kind.commandType, payload: payload, occurrence: nil)
  }

  private static let valid: [(MemoirCommandKind, [String: JSONValue])] = [
    (.moneyNoSpend, ["date": "2026-11-20"]),
    (.expenseCreate, ["id": expense, "source": "manual", "occurredOn": "2026-11-20"]),
    (.budgetClosePeriod, ["budgetId": budget, "periodStart": "2026-10-01", "outcome": "within", "deposited": true]),
    (.goalMilestone, ["goalId": goal, "milestone": "p75"]),
    (.goalBought, ["goalId": goal, "outcome": "over"]),
  ]

  @Test func shouldDecodeEachMoneyPayloadIntoItsBodyAndWriteItBackUnchanged() throws {
    let date = try MemoirStoreFixture.date("2026-11-20")
    let expected: [MemoirCommandBody] = [
      .moneyNoSpend(NoSpendDay(date: date)),
      .expenseCreate(ExpenseCreation(id: CommandSamples.record, occurredOn: date)),
      .budgetClosePeriod(try BudgetPeriodClose(budgetId: CommandSamples.budget, periodStart: try MemoirStoreFixture.date("2026-10-01"), outcome: .within, deposited: true)),
      .goalMilestone(GoalMilestoneReached(goalId: CommandSamples.goal, milestone: .p75)),
      .goalBought(GoalPurchase(goalId: CommandSamples.goal, outcome: .over)),
    ]
    for ((kind, payload), body) in zip(Self.valid, expected) {
      #expect(try Self.decode(kind, payload) == body, "\(kind.rawValue)")
      #expect(try body.payload().members == payload, "\(kind.rawValue)")
    }
    #expect(try Self.decode(.expenseCreate, ["id": Self.expense]) == .expenseCreate(ExpenseCreation(id: CommandSamples.record)))
    #expect(try ExpenseCreation(id: CommandSamples.record).asBody.payload().members["occurredOn"] == nil, "a v1 creation keeps its v1 payload")
  }

  @Test func shouldRefuseAStrayKeyAMissingFieldAndAWrongTypeInEveryMoneyPayload() throws {
    for (kind, payload) in Self.valid {
      #expect(throws: CommandRefusal.unexpectedField("amountMinor"), "\(kind.rawValue)") { try Self.decode(kind, payload.merging(["amountMinor": 1250]) { $1 }) }
      #expect(throws: CommandRefusal.unexpectedField("note"), "\(kind.rawValue)") { try Self.decode(kind, payload.merging(["note": "Lunch"]) { $1 }) }
      for key in payload.keys where !(kind == .expenseCreate && ["source", "occurredOn"].contains(key)) {
        var missing = payload
        missing[key] = nil
        #expect(throws: CommandRefusal.self, "\(kind.rawValue) without \(key)") { try Self.decode(kind, missing) }
      }
      for key in payload.keys {
        for wrong: JSONValue in [.null, 3, ["date": "2026-11-20"], ["2026-11-20"]] {
          #expect(throws: CommandRefusal.self, "\(kind.rawValue) \(key) = \(wrong)") { try Self.decode(kind, payload.merging([key: wrong]) { $1 }) }
        }
      }
    }
  }

  @Test func shouldRefuseDatesThatAreNotRealCivilDates() {
    for text: JSONValue in ["2026-02-30", "2026-13-01", "20261120", "2026-11-20T00:00:00Z", "yesterday", ""] {
      #expect(throws: CommandRefusal.self, "\(text)") { try Self.decode(.moneyNoSpend, ["date": text]) }
      #expect(throws: CommandRefusal.self, "\(text)") { try Self.decode(.expenseCreate, ["id": Self.expense, "occurredOn": text]) }
      #expect(throws: CommandRefusal.self, "\(text)") {
        try Self.decode(.budgetClosePeriod, ["budgetId": Self.budget, "periodStart": text, "outcome": "within", "deposited": false])
      }
    }
    #expect(throws: CommandRefusal.invalidField(field: "date", problem: .notDate)) { try Self.decode(.moneyNoSpend, ["date": "2026-02-30"]) }
    #expect(throws: CommandRefusal.invalidField(field: "occurredOn", problem: .notString)) {
      try Self.decode(.expenseCreate, ["id": Self.expense, "occurredOn": .null])
    }
  }

  @Test func shouldRefuseTokensOutsideEachClosedSet() {
    for outcome: JSONValue in ["over", "over_50", "Within", "within_limit", "p25", ""] {
      #expect(throws: CommandRefusal.invalidField(field: "outcome", problem: .notAllowed), "\(outcome)") {
        try Self.decode(.budgetClosePeriod, ["budgetId": Self.budget, "periodStart": "2026-10-01", "outcome": outcome, "deposited": false])
      }
    }
    for milestone: JSONValue in ["p0", "p33", "P25", "25", "within"] {
      #expect(throws: CommandRefusal.self, "\(milestone)") { try Self.decode(.goalMilestone, ["goalId": Self.goal, "milestone": milestone]) }
    }
    for outcome: JSONValue in ["within_typical", "under", "Over", "over_10"] {
      #expect(throws: CommandRefusal.invalidField(field: "outcome", problem: .notAllowed), "\(outcome)") {
        try Self.decode(.goalBought, ["goalId": Self.goal, "outcome": outcome])
      }
    }
    #expect(throws: CommandRefusal.invalidField(field: "budgetId", problem: .notIdentifier)) {
      try Self.decode(.budgetClosePeriod, ["budgetId": "home", "periodStart": "2026-10-01", "outcome": "within", "deposited": false])
    }
    #expect(throws: CommandRefusal.invalidField(field: "goalId", problem: .notIdentifier)) { try Self.decode(.goalBought, ["goalId": "bike", "outcome": "within"]) }
  }

  @Test func shouldRefuseADepositFromAPeriodThatWentOverOrWasUnscored() throws {
    let start = try MemoirStoreFixture.date("2026-10-01")
    for outcome in BudgetCloseOutcome.allCases {
      let deposits = outcome == .within || outcome == .withinTypical
      #expect(try BudgetPeriodClose(budgetId: CommandSamples.budget, periodStart: start, outcome: outcome, deposited: false).deposited == false)
      let payload: [String: JSONValue] = ["budgetId": Self.budget, "periodStart": "2026-10-01", "outcome": .string(outcome.rawValue), "deposited": true]
      if deposits {
        #expect(try BudgetPeriodClose(budgetId: CommandSamples.budget, periodStart: start, outcome: outcome, deposited: true).deposited)
        #expect(try Self.decode(.budgetClosePeriod, payload).kind == .budgetClosePeriod)
      } else {
        #expect(throws: CommandRefusal.invalidField(field: "deposited", problem: .notAllowed), "\(outcome.rawValue)") {
          try BudgetPeriodClose(budgetId: CommandSamples.budget, periodStart: start, outcome: outcome, deposited: true)
        }
        #expect(throws: CommandRefusal.invalidField(field: "deposited", problem: .notAllowed), "\(outcome.rawValue)") { try Self.decode(.budgetClosePeriod, payload) }
      }
    }
  }

  @Test func shouldNeedRulesetTwoForEveryMoneyBodyAndForACreationThatNamesItsDay() throws {
    let date = try MemoirStoreFixture.date("2026-11-20")
    #expect(MemoirCommandBody.moneyNoSpend(NoSpendDay(date: date)).minimumRulesetVersion == 2)
    #expect(MemoirCommandBody.goalBought(GoalPurchase(goalId: CommandSamples.goal, outcome: .within)).minimumRulesetVersion == 2)
    #expect(MemoirCommandBody.goalMilestone(GoalMilestoneReached(goalId: CommandSamples.goal, milestone: .p25)).minimumRulesetVersion == 2)
    #expect(
      MemoirCommandBody.budgetClosePeriod(try BudgetPeriodClose(budgetId: CommandSamples.budget, periodStart: date, outcome: .unscored, deposited: false))
        .minimumRulesetVersion == 2)
    #expect(ExpenseCreation(id: CommandSamples.record, occurredOn: date).asBody.minimumRulesetVersion == 2)
    #expect(ExpenseCreation(id: CommandSamples.record).asBody.minimumRulesetVersion == 1)
    let money: Set<MemoirCommandKind> = [.moneyNoSpend, .budgetClosePeriod, .goalMilestone, .goalBought]
    for body in try CommandSamples.all() where !money.contains(body.kind) && body.kind != .expenseCreate {
      #expect(body.minimumRulesetVersion == 1, "\(body.kind.rawValue)")
    }
    for kind in money {
      #expect(kind.occurrenceUse == .none && kind.settingTiming == nil && kind.integerPaths.isEmpty, "\(kind.rawValue)")
    }
  }
}

extension ExpenseCreation {
  fileprivate var asBody: MemoirCommandBody { .expenseCreate(self) }
}
