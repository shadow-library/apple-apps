import Foundation
import Testing

@testable import ShadowAI

@Suite("Spend")
struct LedgerSpendTests {
  private static let auckland: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Pacific/Auckland") ?? .gmt
    return calendar
  }()

  private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    auckland.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) ?? .distantPast
  }

  private static func call(at date: Date, cost: Int64?, source: LedgerCostSource = .computed) -> ModelCallEntry {
    LedgerFixture.entry(startedMillis: Int64(date.timeIntervalSince1970 * 1_000), outcome: .finished, cost: cost.map { Cost(nanoUSD: $0) }, costSource: source)
  }

  private static let now = Self.date(2025, 3, 15, 12)

  @Test("should split calls at local midnight in a non-UTC time zone")
  func splitsAtMidnight() {
    let entries = [
      Self.call(at: Self.date(2025, 3, 15, 0, 0, 0), cost: 1),
      Self.call(at: Self.date(2025, 3, 15, 23, 59, 59), cost: 10),
      Self.call(at: Self.date(2025, 3, 14, 23, 59, 59), cost: 100),
      Self.call(at: Self.date(2025, 3, 16, 0, 0, 0), cost: 1_000),
    ]
    let summary = Spend.summary(of: entries, now: Self.now, calendar: Self.auckland)
    #expect(summary.today == Cost(nanoUSD: 11))
    #expect(summary.month == Cost(nanoUSD: 1_111))
  }

  @Test("should assign a UTC afternoon to the next local day")
  func usesLocalDayNotUTC() {
    let utcEvening = Date(timeIntervalSince1970: 1_741_982_400)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    #expect(utc.component(.day, from: utcEvening) == 14)
    #expect(Self.auckland.component(.day, from: utcEvening) == 15)
    let summary = Spend.summary(of: [Self.call(at: utcEvening, cost: 7)], now: Self.now, calendar: Self.auckland)
    #expect(summary.today == Cost(nanoUSD: 7))
  }

  @Test("should split calls at the local month boundary")
  func splitsAtMonthBoundary() {
    let entries = [
      Self.call(at: Self.date(2025, 2, 28, 23, 59, 59), cost: 1),
      Self.call(at: Self.date(2025, 3, 1, 0, 0, 0), cost: 10),
      Self.call(at: Self.date(2025, 3, 31, 23, 59, 59), cost: 100),
      Self.call(at: Self.date(2025, 4, 1, 0, 0, 0), cost: 1_000),
      Self.call(at: Self.date(2024, 3, 15, 12), cost: 10_000),
    ]
    let summary = Spend.summary(of: entries, now: Self.now, calendar: Self.auckland)
    #expect(summary.month == Cost(nanoUSD: 110))
    #expect(summary.today == .zero)
  }

  @Test("should count pending calls separately and give them no cost")
  func countsPendingSeparately() {
    let entries = [
      Self.call(at: Self.date(2025, 3, 15, 1), cost: nil, source: .pending),
      Self.call(at: Self.date(2025, 3, 2, 1), cost: 999, source: .pending),
      Self.call(at: Self.date(2025, 2, 2, 1), cost: nil, source: .pending),
      Self.call(at: Self.date(2025, 3, 15, 2), cost: 50, source: .reported),
    ]
    let summary = Spend.summary(of: entries, now: Self.now, calendar: Self.auckland)
    #expect(summary == SpendSummary(today: Cost(nanoUSD: 50), month: Cost(nanoUSD: 50), pendingCalls: 2))
  }

  @Test("should treat a settled call without a cost as free")
  func settledWithoutCostIsFree() {
    let summary = Spend.summary(of: [Self.call(at: Self.now, cost: nil)], now: Self.now, calendar: Self.auckland)
    #expect(summary == SpendSummary(today: .zero, month: .zero, pendingCalls: 0))
  }

  @Test("should summarise no entries as zero")
  func summarisesNothing() {
    #expect(Spend.summary(of: [], now: Self.now, calendar: Self.auckland) == SpendSummary(today: .zero, month: .zero, pendingCalls: 0))
  }

  @Test("should saturate sums instead of trapping")
  func saturates() {
    let entries = [Self.call(at: Self.now, cost: Int64.max), Self.call(at: Self.now, cost: Int64.max), Self.call(at: Self.now, cost: 5)]
    let summary = Spend.summary(of: entries, now: Self.now, calendar: Self.auckland)
    #expect(summary.today == Cost(nanoUSD: Int64.max))
    #expect(summary.month == Cost(nanoUSD: Int64.max))
  }

  @Test("should ignore a negative stored cost")
  func ignoresNegativeCost() {
    let summary = Spend.summary(of: [Self.call(at: Self.now, cost: -500), Self.call(at: Self.now, cost: 3)], now: Self.now, calendar: Self.auckland)
    #expect(summary.today == Cost(nanoUSD: 3))
  }

  struct DecisionCase: CustomTestStringConvertible, Sendable {
    let name: String
    let limits: SpendLimits
    let expected: SpendDecision
    var testDescription: String { name }
  }

  private static let spent = SpendSummary(today: Cost(nanoUSD: 100), month: Cost(nanoUSD: 1_000), pendingCalls: 0)

  static let decisionCases: [DecisionCase] = [
    DecisionCase(name: "no limits", limits: SpendLimits(), expected: .allowed),
    DecisionCase(name: "both below", limits: SpendLimits(daily: Cost(nanoUSD: 101), monthly: Cost(nanoUSD: 1_001)), expected: .allowed),
    DecisionCase(name: "daily exactly at", limits: SpendLimits(daily: Cost(nanoUSD: 100)), expected: .dailyLimitReached(spent: Cost(nanoUSD: 100), limit: Cost(nanoUSD: 100))),
    DecisionCase(name: "daily above", limits: SpendLimits(daily: Cost(nanoUSD: 50)), expected: .dailyLimitReached(spent: Cost(nanoUSD: 100), limit: Cost(nanoUSD: 50))),
    DecisionCase(
      name: "monthly exactly at", limits: SpendLimits(monthly: Cost(nanoUSD: 1_000)),
      expected: .monthlyLimitReached(spent: Cost(nanoUSD: 1_000), limit: Cost(nanoUSD: 1_000))),
    DecisionCase(
      name: "monthly above", limits: SpendLimits(monthly: Cost(nanoUSD: 10)), expected: .monthlyLimitReached(spent: Cost(nanoUSD: 1_000), limit: Cost(nanoUSD: 10))),
    DecisionCase(
      name: "monthly is checked before daily", limits: SpendLimits(daily: Cost(nanoUSD: 1), monthly: Cost(nanoUSD: 1)),
      expected: .monthlyLimitReached(spent: Cost(nanoUSD: 1_000), limit: Cost(nanoUSD: 1))),
    DecisionCase(
      name: "daily blocks when monthly is fine", limits: SpendLimits(daily: Cost(nanoUSD: 1), monthly: Cost(nanoUSD: 5_000)),
      expected: .dailyLimitReached(spent: Cost(nanoUSD: 100), limit: Cost(nanoUSD: 1))),
    DecisionCase(name: "a nil monthly never blocks", limits: SpendLimits(daily: Cost(nanoUSD: 1_000), monthly: nil), expected: .allowed),
    DecisionCase(name: "a nil daily never blocks", limits: SpendLimits(daily: nil, monthly: Cost(nanoUSD: 1_001)), expected: .allowed),
  ]

  @Test("should decide against the limits", arguments: decisionCases)
  func decides(_ item: DecisionCase) {
    #expect(Spend.decision(for: Self.spent, limits: item.limits) == item.expected)
  }

  @Test("should block a saturated spend against any finite limit")
  func blocksSaturated() {
    let saturated = SpendSummary(today: Cost(nanoUSD: Int64.max), month: Cost(nanoUSD: Int64.max), pendingCalls: 0)
    #expect(Spend.decision(for: saturated, limits: SpendLimits(monthly: Cost(nanoUSD: Int64.max))) == .monthlyLimitReached(spent: saturated.month, limit: saturated.month))
  }

  @Test("should round-trip limits through Codable with absent caps as nil")
  func codesLimits() throws {
    let limits = SpendLimits(daily: Cost(nanoUSD: 5), monthly: nil)
    let decoded = try JSONDecoder().decode(SpendLimits.self, from: JSONEncoder().encode(limits))
    #expect(decoded == limits)
  }
}
