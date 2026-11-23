import Foundation
import MemoirCore
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

/// Answers every pair from a fixed rate, or fails, and records what it was asked.
nonisolated final class RecordingRatesClient: RatesClient {
  private let state: Mutex<(requests: [(pairs: Set<CurrencyPair>, date: LocalDate)], failing: Bool)>
  private let rate: DecimalText

  init(rate: String = "0.1", failing: Bool = false) {
    self.rate = DecimalText(rate)!
    state = Mutex(([], failing))
  }

  var requests: [(pairs: Set<CurrencyPair>, date: LocalDate)] { state.withLock { $0.requests } }

  func recover() {
    state.withLock { $0.failing = false }
  }

  func rates(for pairs: Set<CurrencyPair>, on date: LocalDate) async throws(RatesClientError) -> [CurrencyPair: DecimalText] {
    let failing = state.withLock { state in
      state.requests.append((pairs, date))
      return state.failing
    }
    if failing { throw .unavailable("scripted") }
    return Dictionary(uniqueKeysWithValues: pairs.map { ($0, rate) })
  }
}

/// A now the test moves, and a sleep that moves it by the time slept, so a backoff passes at once and its length is recorded.
nonisolated final class MovingNow: Sendable {
  private let state: Mutex<(now: Date, slept: [TimeInterval])>

  init(_ start: Date) {
    state = Mutex((start, []))
  }

  var now: @Sendable () -> Date { { self.state.withLock { $0.now } } }
  var slept: [TimeInterval] { state.withLock { $0.slept } }

  var sleep: @Sendable (TimeInterval) async throws -> Void {
    { interval in
      self.state.withLock { state in
        state.slept.append(interval)
        state.now = state.now.addingTimeInterval(interval)
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

@MainActor
@Suite("Memoir exchange rates", TestTimeLimit.standard)
struct MemoirRatesTests {
  private static func defaults() -> UserDefaults {
    let name = "MemoirRatesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func rates(_ client: RecordingRatesClient, defaults: UserDefaults = defaults(), moving: MovingNow = MovingNow(TestClock.date(day: 0, minute: 720)))
    -> MemoirRates
  {
    MemoirRates(client: client, setting: RatesDeviceSetting(defaults: defaults), now: moving.now, sleep: moving.sleep)
  }

  private static func spend(_ context: MemoirScreenContext) async throws -> MonthSpend? {
    try await context.stores.main.read { transaction in try FinanceLedger.load(from: transaction).spend(inMonthOf: TestClock.day0) }
  }

  /// Lets the runner see what was written; a fill it would start has started by then.
  private static func settle() async throws {
    try await Task.sleep(for: .milliseconds(300))
  }

  @Test("should fill a foreign expense saved in the foreground, so the home totals include it")
  func fillsASavedForeignExpense() async throws {
    let context = try await MoneyFixture.context()
    let client = RecordingRatesClient(rate: "0.1")
    let rates = Self.rates(client)
    rates.follow(context)
    rates.phaseChanged(isActive: true)
    try await MoneyFixture.expense(context, 2_000, on: TestClock.day0)

    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    form.select(MoneyFixture.krone)
    form.amountText = "100"
    _ = try #require(await form.save())

    try await TestClock.until("the krone expense converts") { try await Self.spend(context)?.awaitingRate == 0 }
    #expect(try await Self.spend(context)?.spentMinor == 2_000 + 1_000)
    #expect(client.requests.map(\.date) == [TestClock.day0])
    #expect(client.requests.first?.pairs == [CurrencyPair(base: MoneyFixture.krone, quote: MoneyFixture.euro)])
  }

  @Test("should ask nothing while the setting is off, and ask once it is turned on")
  func asksNothingWhileOff() async throws {
    let context = try await MoneyFixture.context()
    let client = RecordingRatesClient()
    let defaults = Self.defaults()
    RatesDeviceSetting(defaults: defaults).set(false)
    let rates = Self.rates(client, defaults: defaults)
    #expect(!rates.isFetching)
    rates.follow(context)
    rates.phaseChanged(isActive: true)
    try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone)
    try await Self.settle()
    #expect(client.requests.isEmpty)
    #expect(try await Self.spend(context)?.awaitingRate == 1)

    rates.setFetching(true)
    #expect(RatesDeviceSetting(defaults: defaults).isOn)
    try await TestClock.until("the expense converts once fetching is on") { try await Self.spend(context)?.awaitingRate == 0 }
    #expect(client.requests.count == 1)
  }

  @Test("should never ask for the demo's vault, nor while the app is in the background")
  func asksNothingForTheDemoOrInTheBackground() async throws {
    let owner = try await MoneyFixture.context()
    let demo = MemoirScreenContext(stores: owner.stores, clock: owner.clock, isDemo: true)
    let client = RecordingRatesClient()
    let rates = Self.rates(client)
    rates.follow(demo)
    rates.phaseChanged(isActive: true)
    try await MoneyFixture.expense(owner, 10_000, MoneyFixture.krone)
    try await Self.settle()
    #expect(client.requests.isEmpty, "the demo is never followed")

    rates.phaseChanged(isActive: false)
    rates.follow(owner)
    try await Self.settle()
    #expect(client.requests.isEmpty, "nothing is asked in the background")
    rates.phaseChanged(isActive: true)
    try await TestClock.until("the foreground asks") { !client.requests.isEmpty }
  }

  @Test("should convert at a rate the owner entered, which the filler never asks about nor replaces")
  func keepsTheOwnersRate() async throws {
    let context = try await MoneyFixture.context()
    let client = RecordingRatesClient(rate: "0.1")
    let rates = Self.rates(client)
    rates.follow(context)
    rates.phaseChanged(isActive: true)

    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.german)
    form.select(MoneyFixture.krone)
    form.amountText = "100"
    #expect(form.offersRate)
    form.rateText = "0,0875"
    #expect(form.preview(locale: MoneyFixture.german)?.contains("0,0875") == true)
    let typed = try #require(await form.save())
    try await Self.settle()
    #expect(client.requests.isEmpty, "an expense with the owner's rate needs none")
    #expect(try await Self.spend(context)?.spentMinor == 875)

    try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone)
    try await TestClock.until("the other krone expense converts") { try await Self.spend(context)?.awaitingRate == 0 }
    #expect(try await Self.spend(context)?.spentMinor == 875 + 1_000)
    let entries = try await MoneyFixture.expenseEntries(context)
    let kept = try #require(entries.first { $0.record.id == typed }?.record)
    #expect(kept.manualRate == ManualRate(rate: DecimalText("0.0875")!, quote: MoneyFixture.euro))
    #expect(kept.rate == nil)
  }

  @Test("should work through a backlog past the filler's limit at once rather than an hour apart")
  func worksThroughABacklog() async throws {
    let context = try await MoneyFixture.context()
    for day in 0..<5 { try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone, on: TestClock.day(-day)) }
    let client = RecordingRatesClient(rate: "0.1")
    let rates = MemoirRates(
      client: client, setting: RatesDeviceSetting(defaults: Self.defaults()), maximumDates: 2, now: TestClock(day: 0, minute: 720).now,
      sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
    rates.follow(context)
    rates.phaseChanged(isActive: true)
    try await TestClock.until("every expense converts") {
      let ledger = try await context.stores.main.read { transaction in try FinanceLedger.load(from: transaction) }
      return ledger.converter.map { converter in ledger.expenses.allSatisfy { converter.homeAmount(of: $0) != .awaitingRate } } ?? false
    }
    #expect(client.requests.count == 5, "each date is asked once")
  }

  @Test("should back off after a failure and ask again once the wait has passed")
  func backsOffAfterAFailure() async throws {
    let context = try await MoneyFixture.context()
    let client = RecordingRatesClient(failing: true)
    let moving = MovingNow(TestClock.date(day: 0, minute: 720))
    let rates = Self.rates(client, moving: moving)
    rates.follow(context)
    rates.phaseChanged(isActive: true)
    try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone)
    try await TestClock.until("a second attempt after the backoff") { client.requests.count >= 3 }
    #expect(Array(moving.slept.prefix(2)) == [60, 120], "the wait doubles after each failure")

    client.recover()
    try await TestClock.until("the expense converts once the service answers") { try await Self.spend(context)?.awaitingRate == 0 }
  }
}

@Suite("Rate pacing", TestTimeLimit.quick)
struct RatePacingTests {
  private static let start = Date(timeIntervalSince1970: 1_800_000_000)
  private static let pair = CurrencyPair(base: MoneyFixture.krone, quote: MoneyFixture.euro)

  private static func requests(_ days: [Int]) -> RateRequests {
    RateRequests(dates: Dictionary(uniqueKeysWithValues: days.map { (TestClock.day($0), Set([pair])) }), pendingLocks: false)
  }

  private static func dated(_ days: [Int]) -> Set<DatedPair> {
    Set(days.map { DatedPair(pair: pair, date: TestClock.day($0)) })
  }

  private static func report(deferred: [Int] = [], failed: [Int] = []) -> RateFillReport {
    var report = RateFillReport()
    report.deferredDates = deferred.map(TestClock.day)
    report.failedDates = failed.map(TestClock.day)
    return report
  }

  @Test("should ask at once for anything new, and only an hour later for what was asked")
  func asksNewPairsAtOnce() {
    var pacing = RatePacing()
    #expect(pacing.decide(.none, now: Self.start) == .idle)
    #expect(pacing.decide(Self.requests([0]), now: Self.start) == .run(asking: Self.dated([0])))
    pacing.ran(Self.requests([0]), asking: Self.dated([0]), at: Self.start, report: Self.report())
    #expect(pacing.decide(Self.requests([0]), now: Self.start) == .wait(until: Self.start.addingTimeInterval(3_600)))
    #expect(pacing.decide(Self.requests([0, 1]), now: Self.start) == .run(asking: Self.dated([1])), "only the new date is asked")
    #expect(pacing.decide(Self.requests([0]), now: Self.start.addingTimeInterval(3_600)) == .run(asking: Self.dated([0])))
    #expect(pacing.decide(RateRequests(dates: [:], pendingLocks: true), now: Self.start) == .run(asking: []))
  }

  @Test("should ask again at once for the dates a fill deferred past its limit")
  func asksDeferredDatesAtOnce() {
    var pacing = RatePacing()
    pacing.ran(Self.requests([0, 1, 2]), asking: Self.dated([0, 1, 2]), at: Self.start, report: Self.report(deferred: [0, 1]))
    #expect(pacing.decide(Self.requests([0, 1, 2]), now: Self.start) == .run(asking: Self.dated([0, 1])))
  }

  @Test("should back off after failures, doubling up to an hour, and ask again what failed")
  func backsOff() {
    for (failures, wait) in [(1, 60.0), (2, 120), (3, 240), (7, 3_600), (9, 3_600)] {
      var failing = RatePacing()
      for _ in 0..<failures { failing.ran(Self.requests([0]), asking: Self.dated([0]), at: Self.start, report: Self.report(failed: [0])) }
      #expect(failing.decide(Self.requests([0, 1]), now: Self.start) == .wait(until: Self.start.addingTimeInterval(wait)), "\(failures) failures")
      #expect(failing.decide(Self.requests([0]), now: Self.start.addingTimeInterval(wait)) == .run(asking: Self.dated([0])))
    }
    var thrown = RatePacing()
    thrown.ran(Self.requests([0]), asking: Self.dated([0]), at: Self.start, report: nil)
    #expect(thrown.failures == 1)
    #expect(thrown.asked.isEmpty, "a fill that threw asked nothing")
  }
}
