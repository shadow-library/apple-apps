import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir money in the game on Today and the Hero screen", TestTimeLimit.quick)
struct MoneyGameReadTests {
  private typealias Device = ReadsDevice

  private static let budget = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e001")
  private static let trip = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e002")
  private static let period = LocalDate(year: 2026, month: 2, day: 1)!
  private static let v2 = Ruleset.v2.version

  private static func standing(_ device: Device) async throws -> MoneyGameStanding {
    try await device.load(MoneyGameStanding.self, MoneyGameQuery())
  }

  private static func noSpend(_ date: LocalDate) -> MemoirCommandBody {
    .moneyNoSpend(NoSpendDay(date: date))
  }

  private static func close(_ budget: UUID, _ outcome: BudgetCloseOutcome, deposited: Bool = false) throws -> MemoirCommandBody {
    .budgetClosePeriod(try BudgetPeriodClose(budgetId: budget, periodStart: period, outcome: outcome, deposited: deposited))
  }

  @Test func shouldReadAVaultWithoutMoneyActivityAsNothingCoveredAndOfferNoSpend() async throws {
    let device = try Device()
    let unwalked = try await Self.standing(device)
    #expect(unwalked.openDay == nil && unwalked.week == nil && unwalked.logging.isEmpty && unwalked.today == nil)
    #expect(unwalked.noSpend(on: Device.day(0)) == .unavailable(.loggingWindowClosed), "without an open day no window is known")

    try await device.walk(to: Device.day(2))
    let standing = try await Self.standing(device)
    #expect(standing.weekStreak == 0 && standing.savingStreak == 0 && standing.lastActivityDay == nil && standing.debuff == nil && standing.recentCloses.isEmpty)
    let week = try #require(standing.week)
    #expect(week.start == Device.day(0) && week.end == Device.day(6) && week.covered.isEmpty && week.required == 5 && week.coverable == 7)
    #expect(!week.isAccounted && week.canStillBeAccounted && standing.settlingWeek == nil)
    #expect(standing.logging.map(\.date) == [Device.day(2), Device.day(1), Device.day(0)] && standing.logging.allSatisfy { $0.noSpend == .available })
    #expect(standing.today?.coverage == nil && standing.backFill.map(\.date) == [Device.day(1), Device.day(0)])
    #expect(standing.noSpend(on: Device.day(3)) == .unavailable(.notYetBegun) && standing.noSpend(on: Device.day(-1)) == .unavailable(.loggingWindowClosed))
    #expect(standing.changesOn == Device.day(3))
  }

  /// The week of 30 March runs into April; on Monday 6 April it is still settling, since its Saturday and Sunday can be back-filled until Tuesday closes.
  @Test func shouldCountTheWeekAcrossAMonthEndAndKeepLastWeekWhileItSettles() async throws {
    let device = try Device()
    let monday = Device.day(28)
    for offset in 0..<4 { try await device.issue(Self.noSpend(monday.movedBy(days: offset)), on: monday.movedBy(days: offset), rulesetVersion: Self.v2) }
    try await device.walk(to: monday.movedBy(days: 3))
    let thursday = try #require(try await Self.standing(device).week)
    #expect(thursday.start == monday && thursday.end == LocalDate(year: 2026, month: 4, day: 5) && thursday.covered.count == 4)
    #expect(thursday.coverable == 3 && thursday.canStillBeAccounted && !thursday.isAccounted, "Friday to Sunday; Tuesday is past the late window")

    let next = monday.movedBy(days: 7)
    try await device.issue(Self.noSpend(next.movedBy(days: -1)), on: next, rulesetVersion: Self.v2)
    try await device.issue(.expenseCreate(ExpenseCreation(id: CommandSamples.record, occurredOn: next.movedBy(days: -2))), on: next, rulesetVersion: Self.v2)
    try await device.walk(to: next)
    let onMonday = try await Self.standing(device)
    #expect(onMonday.week?.start == next && onMonday.week?.covered.isEmpty == true && onMonday.week?.coverable == 7)
    let settling = try #require(onMonday.settlingWeek)
    #expect(settling.start == monday && settling.covered.count == 6 && settling.isAccounted && settling.coverable == 0)
    #expect(onMonday.weekStreak == 0, "the week has not settled while its last days can still be covered")
    #expect(onMonday.logging.map(\.coverage) == [nil, .noSpend, .expense])
    #expect(onMonday.noSpend(on: next.movedBy(days: -2)) == .unavailable(.alreadyCovered(.expense)) && onMonday.backFill.isEmpty)

    try await device.walk(to: next.movedBy(days: 1))
    #expect(try await Self.standing(device).settlingWeek?.start == monday, "Tuesday still closes inside the late window of Sunday")
    try await device.walk(to: next.movedBy(days: 2))
    let settled = try await Self.standing(device)
    #expect(settled.settlingWeek == nil && settled.weekStreak == 1 && settled.lastActivityDay == next)
  }

  @Test func shouldShowTheDebuffWhileItLastsAndTheLatestClosesNewestFirst() async throws {
    let device = try Device()
    _ = try await device.store.write { transaction in
      try BudgetRecord(id: Self.trip, name: "Lisbon", currency: try MemoirStoreFixture.currency("EUR"), period: .monthly, createdOn: Self.period).create(in: &transaction)
    }
    let over = try await device.issue(try Self.close(Self.budget, .over10), on: Device.day(3), rulesetVersion: Self.v2)
    try await device.issue(try Self.close(Self.trip, .within, deposited: true), on: Device.day(4), rulesetVersion: Self.v2)
    try await device.walk(to: Device.day(4))
    let standing = try await Self.standing(device)
    #expect(standing.debuff == MoneyRow.Debuff(multiplier: Thousandths(850), through: Device.day(9)) && standing.savingStreak == 1)
    #expect(standing.recentCloses.map(\.key) == [MoneyCloseKey(budget: Self.trip, periodStart: Self.period), MoneyCloseKey(budget: Self.budget, periodStart: Self.period)])
    let first = try #require(standing.recentCloses.first)
    #expect(first.budgetName == "Lisbon" && first.closedOn == Device.day(4) && first.outcome == .within && first.deposited)
    #expect(first.result == .rewarded(RewardAmount(xp: 20, coins: 3)))
    let fined = try #require(standing.recentCloses.last)
    #expect(fined.budgetName == nil && fined.outcome == .over10 && !fined.deposited)
    guard case .fined(intended: 15, applied: 0, let debuff) = fined.result else { throw MemoirFixtureError(description: "\(fined.result)") }
    #expect(debuff.command == over.id && debuff.from == Device.day(3) && debuff.through == Device.day(9), "a fine clamps to the empty balance")

    try await device.walk(to: Device.day(9))
    #expect(try await Self.standing(device).debuff?.through == Device.day(9))
    try await device.walk(to: Device.day(10))
    let expired = try await Self.standing(device)
    #expect(expired.debuff == nil && expired.recentCloses.count == 2)
  }

  /// An earlier-clocked close of the same period arriving from another device takes it: the one shown first is superseded and leaves the list.
  @Test func shouldShowOnlyTheCloseReplayKeptOnceAnEarlierOneArrives() async throws {
    let device = try Device()
    let shown = try await device.issue(try Self.close(Self.trip, .within, deposited: true), on: Device.day(3), rulesetVersion: Self.v2)
    try await device.walk(to: Device.day(3))
    #expect(try await Self.standing(device).recentCloses.map(\.key.budget) == [Self.trip])

    let offline = try MemoirStore.openInMemory(.main, wallClock: { Date(timeIntervalSince1970: 1_699_999_000) })
    let earlier = try device.command(try Self.close(Self.trip, .overMore), on: Device.day(3), minute: 300, rulesetVersion: Self.v2)
    _ = try await offline.write { transaction in try earlier.append(in: &transaction) }
    _ = try await device.store.applyRemote(try await offline.pendingChanges(limit: Int.max).map(\.line))

    let after = try await Self.standing(device)
    #expect(after.recentCloses.count == 1 && after.recentCloses.first?.outcome == .overMore && after.savingStreak == 0)
    #expect(after.debuff == MoneyRow.Debuff(multiplier: Thousandths(600), through: Device.day(32)))
    #expect(try await device.outcomes()[shown.id] == .superseded)
  }

  @Test func shouldCarryTheStandingOnTheBoardAndTheDeck() async throws {
    let device = try Device()
    try await device.issue(Self.noSpend(Device.day(1)), on: Device.day(2), rulesetVersion: Self.v2)
    try await device.walk(to: Device.day(2))
    let standing = try await Self.standing(device)
    #expect(try await device.board(Device.day(2)).money == standing)
    #expect(try await device.board(Device.day(5)).money == standing, "as of the open day whichever day the board shows")
    #expect(try await device.load(HeroDeck.self, HeroDeckQuery()).money == standing)
    #expect(standing.logging.map(\.coverage) == [nil, .noSpend, nil] && standing.backFill.map(\.date) == [Device.day(0)])
  }

  /// Z2-1: momentum measures quest keeping, so a quest-free vault would read cold every day.
  @Test func shouldWithholdMomentumWithoutAnActiveQuest() async throws {
    let device = try Device()
    #expect(try await device.load(HeroDeck.self, HeroDeckQuery()).momentum == .notStarted)
    try await device.issue(Self.noSpend(Device.day(0)), on: Device.day(0), rulesetVersion: Self.v2)
    try await device.walk(to: Device.day(3))
    #expect(try await device.load(HeroDeck.self, HeroDeckQuery()).momentum == .noActiveQuest)

    try await device.createStandardQuests()
    try await device.walk(to: Device.day(4))
    let deck = try await device.load(HeroDeck.self, HeroDeckQuery())
    let state = Replay.run(try await device.store.read { transaction in try Replay.commands(in: transaction) }, through: device.horizon.function())
    #expect(deck.momentum == .measured(try #require(state.days[Device.day(4)]?.momentum)))
  }

  @Test func shouldReEmitTheBoardAfterAMoneyCommand() async throws {
    let device = try Device()
    try await device.walk(to: Device.day(0))
    var boards = device.store.observe(TodayBoard.self, TodayBoardQuery(date: Device.day(0))).makeAsyncIterator()
    let first = try #require(try await boards.next())
    #expect(first.money.today?.noSpend == .available)
    try await device.issue(Self.noSpend(Device.day(0)), on: Device.day(0), rulesetVersion: Self.v2)
    let logged = try #require(try await boards.next())
    #expect(logged.money.today?.coverage == .noSpend && logged.money.today?.noSpend == .unavailable(.alreadyCovered(.noSpend)))
    #expect(logged.money.week?.covered == [Device.day(0)] && logged.money.lastActivityDay == Device.day(0))
  }
}
