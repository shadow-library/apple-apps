import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("WeeklyReviewModel", TestTimeLimit.standard)
struct WeeklyReviewModelTests {
  private static func loaded(_ model: WeeklyReviewModel) async throws {
    try await TestClock.until("the review loads") { model.week != nil }
  }

  @Test("should review last week and walk its steps, with nothing logged said plainly")
  func walksTheSteps() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = WeeklyReviewModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await Self.loaded(model)
        let review = try #require(model.review.state.value)
        #expect(review.week.start == TestClock.day(-7), "the Monday-to-Sunday week before the one holding today")
        #expect(model.step == .kept)
        #expect(
          WeeklyReviewPresentation.keptHeadline(review.kept)
            == String(localized: "Nothing was logged last week. The week stays empty rather than guessing at it.", table: "Reflect"))
        #expect(WeeklyReviewPresentation.moneyFacts(review.money, lookups: nil).isEmpty)
        await model.advance()
        #expect(model.step == .money)
        await model.advance()
        await model.advance()
        #expect(model.step == .reflect)
        await model.back()
        #expect(model.step == .body)
        #expect(model.furthest == .reflect)
      }
    }
  }

  @Test("should keep answers on this device only, close the week, and open closed on the next visit")
  func savesAnswersAndCompletes() async throws {
    let (context, _) = try ReflectTesting.world()
    let commandsBefore = try await context.stores.commands().count
    let first = WeeklyReviewModel(context: context)

    try await ReflectTesting.following(first.day) {
      try await QuestsObservation { await first.observe() }.during {
        try await Self.loaded(first)
        await first.show(.reflect)
        first.drafts[.better] = "Walked every morning"
        first.drafts[.carry] = "Late emails"
        #expect(await first.save(.better))
        #expect(first.status[.better] == .saved)
        first.edited(.better)
        #expect(first.status[.better] == .idle)
        await first.advance()
        #expect(first.step == .done)
        try await TestClock.until("the completion is read back") { first.isComplete }
      }
    }
    let week = try #require(first.week)
    let stored = try await context.stores.main.read { transaction in try WeeklyReviewAnswers.answers(week: week, in: transaction) }
    #expect(stored.answers == [.better: "Walked every morning", .carry: "Late emails"], "finishing saves what was typed")
    #expect(stored.isComplete)
    #expect(try await context.stores.commands().count == commandsBefore, "the review issues no command and syncs nothing")

    let again = WeeklyReviewModel(context: context)
    try await ReflectTesting.following(again.day) {
      try await QuestsObservation { await again.observe() }.during {
        try await Self.loaded(again)
        #expect(again.step == .done)
        #expect(again.drafts[.better] == "Walked every morning")
        let review = try #require(again.review.state.value)
        #expect(WeeklyReviewPresentation.summary(review).count == 4, "no money line without a home currency")
        await again.show(.reflect)
        again.drafts[.carry] = ""
        #expect(await again.save(.carry))
        await again.advance()
        #expect(again.step == .done, "a closed review moves on without closing again")
      }
    }
    let cleared = try await context.stores.main.read { transaction in try WeeklyReviewAnswers.answers(week: week, in: transaction) }
    #expect(cleared.answers == [.better: "Walked every morning"], "an emptied answer is removed")
    #expect(cleared.completedAtMillis == stored.completedAtMillis)
  }

  @Test("should start a new week over when the day turns into it, never writing the old week's draft")
  func startsANewWeek() async throws {
    let (context, clock) = try ReflectTesting.world()
    let model = WeeklyReviewModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await Self.loaded(model)
        #expect(await model.save(.better) == true, "nothing typed, nothing to write")
        model.drafts[.better] = "Saved before the turn"
        #expect(await model.save(.better))
        await model.show(.reflect)
        model.drafts[.change] = "Typed before the turn"
      }
      let lastWeek = try #require(model.week)
      clock.set(day: 7, minute: 720)
      try await ReflectTesting.seed([ReflectTesting.meal("Breakfast", day: 7)], in: context.stores.main)
      try await TestClock.until("the day turns") { model.day.day?.today == TestClock.day(7) }
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the review moves to the new week") { model.week == TestClock.day0 }
        #expect(model.step == .kept)
        #expect(model.drafts.isEmpty)
        #expect(await model.save(.change), "the new week has nothing typed to write")
        let previous = try await context.stores.main.read { transaction in try WeeklyReviewAnswers.answers(week: lastWeek, in: transaction) }
        #expect(previous.answers == [.better: "Saved before the turn"], "the unsaved draft of the week that ended is not written")
      }
    }
  }

  @Test("should refuse to save a draft once the day has turned past its week, even before the new review is read")
  func refusesAnEndedWeeksDraft() async throws {
    let (context, clock) = try ReflectTesting.world()
    let model = WeeklyReviewModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await Self.loaded(model)
        let lastWeek = try #require(model.week)
        clock.set(day: 7, minute: 720)
        try await ReflectTesting.seed([ReflectTesting.meal("Breakfast", day: 7)], in: context.stores.main)
        try await TestClock.until("the day turns") { model.day.day?.today == TestClock.day(7) }
        #expect(model.review.state.value?.week.start == lastWeek, "the review read for the old day is still shown")
        model.drafts[.better] = "Typed for the week that ended"
        #expect(await model.save(.better) == false)
        #expect(await model.saveAll() == false)
        for week in [lastWeek, TestClock.day0] {
          let stored = try await context.stores.main.read { transaction in try WeeklyReviewAnswers.answers(week: week, in: transaction) }
          #expect(stored == .none, "nothing is written for either week")
        }
      }
    }
  }
}
