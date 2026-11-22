import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("InsightsModel", TestTimeLimit.standard)
struct InsightsModelTests {
  @Test("should read 90 days by default and switch to 30 days and the year, comparing only the shorter periods")
  func switchesPeriods() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = InsightsModel(context: context)
    #expect(model.period == .ninetyDays)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("90 days load") { model.shown != nil }
        #expect(model.shown?.window.dayCount == 90)
        #expect(model.shown?.window.end == TestClock.day0)
        #expect(model.shown?.previousWindow?.dayCount == 90)
      }
      model.period = .thirtyDays
      #expect(model.shown == nil, "the 90 days never stand in for the 30")
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("30 days load") { model.shown?.period == .thirtyDays }
        #expect(model.shown?.window.dayCount == 30)
        #expect(InsightsPresentation.periodNote(.thirtyDays) == String(localized: "The last 30 days, against the 30 before them.", table: "Reflect"))
      }
      model.period = .year
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the year loads") { model.shown?.period == .year }
        let year = try #require(model.shown)
        #expect(year.previousWindow == nil)
        let kpis = InsightsPresentation.kpis(year, streak: nil)
        #expect(kpis.allSatisfy { $0.deltaPercent == nil })
      }
    }
  }

  @Test("should say there is nothing yet on an empty vault, in every section")
  func showsEmptyStatistics() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = InsightsModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the statistics load") { model.shown != nil }
        let statistics = try #require(model.shown)
        let kpis = InsightsPresentation.kpis(statistics, streak: nil)
        #expect(kpis.first { $0.kind == .kept }?.value == nil)
        #expect(kpis.first { $0.kind == .kept }?.caption == String(localized: "No occurrences logged yet.", table: "Reflect"))
        #expect(kpis.first { $0.kind == .streak }?.caption == String(localized: "No streak recorded yet.", table: "Reflect"))
        #expect(kpis.first { $0.kind == .spend }?.value == nil, "no home currency yet")
        #expect(InsightsPresentation.byQuest(statistics).isEmpty)
        #expect(!InsightsPresentation.byWeekday(statistics).contains { $0.hasEntries })
        #expect(InsightsPresentation.reasonsNote(statistics) == String(localized: "No reasons were given in this period.", table: "Reflect"))
        #expect(InsightsPresentation.spendingNote(statistics, lookups: nil) == String(localized: "No expenses were logged in this period.", table: "Reflect"))
        #expect(InsightsPresentation.monthNote(statistics) == String(localized: "Nothing logged in this period yet. It fills in on its own.", table: "Reflect"))
        #expect(statistics.body.isEmpty)
      }
    }
  }

  @Test("should show adherence, XP, spending by category and the longest streak with its quest")
  func showsStatistics() async throws {
    let (context, _) = try ReflectTesting.world()
    let walk = try await QuestsTesting.quest("Walk", in: context)
    try await ReflectTesting.complete(walk, on: 0, in: context)
    try await ReflectTesting.logExpenses(
      [ReflectTesting.expense(450, day: 0, merchant: nil), ReflectTesting.expense(2_000, day: -3, merchant: nil, category: "bills")], in: context)
    let model = InsightsModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observeLookups() }.during {
        try await QuestsObservation { await model.observe() }.during {
          try await TestClock.until("the statistics load") { model.shown?.kept.occurrences == 1 && model.shown?.spent != nil }
          try await TestClock.until("the streak loads") { model.lookups.state.value?.longestStreak != nil }
          let statistics = try #require(model.shown)
          #expect(statistics.kept.percent == 100)
          #expect(statistics.xp > 0)
          let streak = try #require(model.lookups.state.value?.longestStreak)
          #expect(streak.quest == walk && streak.name == "Walk" && streak.days >= 1)
          let kpis = InsightsPresentation.kpis(statistics, streak: streak)
          #expect(kpis.first { $0.kind == .streak }?.caption == String(localized: "Held by Walk.", table: "Reflect"))
          #expect(kpis.first { $0.kind == .kept }?.value == ReflectFormat.percent(100))
          #expect(kpis.first { $0.kind == .spend }?.value == ReflectFormat.money(2_450, CurrencyCode("EUR")!))
          #expect(InsightsPresentation.byQuest(statistics).map(\.label) == ["Walk"])
          let spending = InsightsPresentation.spending(statistics, lookups: model.lookups.state.value)
          #expect(spending.map(\.label) == ["Bills", "Food"], "largest first, built-ins in the app's words")
          #expect(InsightsPresentation.spendingNote(statistics, lookups: nil).hasPrefix("Bills"))
        }
      }
    }
  }

  @Test("should leave weight out of the trends when the health class is not read on this device")
  func hidesBodySeriesWithoutTheClass() async throws {
    let (context, _) = try ReflectTesting.world()
    try await ReflectTesting.seed([ReflectTesting.weight("74", day: -5), ReflectTesting.weight("72.5", day: -1)], in: context.stores.restricted)
    let without = InsightsModel(context: context, bodyClasses: [.activity])
    let with = InsightsModel(context: context)

    try await ReflectTesting.following(without.day) {
      try await QuestsObservation { await without.observe() }.during {
        try await TestClock.until("the statistics load") { without.shown != nil }
        #expect(without.shown?.body.isEmpty == true)
        #expect(without.shown?.bodyClasses == [.activity])
        #expect(ReflectCopy.missingClasses(without.bodyClasses).count == 1)
      }
    }
    try await ReflectTesting.following(with.day) {
      try await QuestsObservation { await with.observe() }.during {
        try await TestClock.until("the weight trend loads") { with.shown?.body.isEmpty == false }
        let weight = try #require(with.shown?.body.first)
        #expect(weight.subject == .weight)
        #expect(InsightsPresentation.trendValue(weight).contains(ReflectCopy.movement(DecimalText("-1.5"))))
        #expect(ReflectCopy.missingClasses(with.bodyClasses).isEmpty)
      }
    }
  }

  @Test("should round the kept difference exactly, a half point up, as the reference does")
  func roundsKeptPointsExactly() throws {
    let half = try #require(Fraction(numerator: 1, denominator: 2))
    let justOver = try #require(Fraction(numerator: 101, denominator: 200))
    #expect(InsightsPresentation.keptPoints(current: half, previous: justOver) == 0, "-0.5 points round up to 0")
    #expect(
      InsightsPresentation.keptCaption(current: half, previous: justOver, whole: false, days: 30)
        == String(localized: "About the same as the \(30) days before.", table: "Reflect"))
    #expect(InsightsPresentation.keptPoints(current: justOver, previous: half) == 1, "+0.5 points round up to 1")
    let third = try #require(Fraction(numerator: 1, denominator: 3))
    #expect(InsightsPresentation.keptPoints(current: third, previous: half) == -17)
    #expect(InsightsPresentation.keptCaption(current: nil, previous: half, whole: false, days: 30) == String(localized: "No occurrences logged yet.", table: "Reflect"))
    #expect(InsightsPresentation.keptCaption(current: half, previous: nil, whole: true, days: 365) == String(localized: "Over the last year.", table: "Reflect"))
  }

  @Test("should name the quest with the longest best run, not the first quest")
  func findsTheLongestStreak() async throws {
    let (context, clock) = try ReflectTesting.world()
    let walk = try await QuestsTesting.quest("Walk", in: context)
    let read = try await QuestsTesting.quest("Read", in: context)
    try await ReflectTesting.complete(read, on: 0, in: context)
    clock.set(day: 1, minute: 720)
    try await ReflectTesting.complete(walk, on: 1, in: context)
    try await ReflectTesting.complete(read, on: 1, in: context)

    let lookups = try await context.stores.main.load(ReflectLookups.self, ReflectLookupsQuery(streaks: true))
    let streak = try #require(lookups.longestStreak)
    #expect(streak.quest == read && streak.name == "Read")
    #expect(streak.days == 2)
    let without = try await context.stores.main.load(ReflectLookups.self, ReflectLookupsQuery(streaks: false))
    #expect(without.longestStreak == nil)
  }
}
