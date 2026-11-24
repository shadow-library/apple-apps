import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("Reflect modules", TestTimeLimit.standard)
struct ReflectModulesTests {
  private static func selection(_ modules: MemoirModule...) throws -> ModuleSelection {
    try ModuleSelection(Set(modules))
  }

  @Test("should offer the history kinds of the modules that are on")
  func offersHistoryKinds() throws {
    #expect(ModuleSelection.all.historyKinds == Set(HistoryKind.allCases))
    #expect(try Self.selection(.money).historyKinds == [.expense])
    #expect(try Self.selection(.journal).historyKinds == [.journal])
    #expect(try Self.selection(.hero, .money).historyKinds == [.hero, .expense])
    #expect(try Self.selection(.hero, .quests, .body).historyKinds == [.hero, .quest, .recovery, .sideQuest, .weight, .health])
  }

  @Test("should walk the review steps of quests, money and body, with reflection and the close always")
  func walksReviewSteps() throws {
    #expect(ModuleSelection.all.reviewSteps == [.kept, .money, .body, .reflect, .done])
    #expect(try Self.selection(.money).reviewSteps == [.money, .reflect, .done])
    #expect(try Self.selection(.hero, .quests).reviewSteps == [.kept, .reflect, .done])
    #expect(try Self.selection(.journal).reviewSteps == [.reflect, .done])
  }

  @Test("should map insight sections to quests, hero, money and body")
  func mapsInsightSections() throws {
    #expect(InsightSections(.all) == InsightSections(.all) && !InsightSections(.all).isEmpty)
    #expect(try InsightSections(Self.selection(.journal, .meals)).isEmpty)
    #expect(try InsightSections(Self.selection(.money)) == InsightSections(Self.selection(.money, .meals)))
  }

  @Test("should read only the body classes while the body module is on")
  func readsBodyOnlyWhenOn() throws {
    let classes: Set<SyncClass> = [.health, .activity]
    #expect(ModuleSelection.all.readableBodyClasses(classes) == classes)
    #expect(try Self.selection(.money).readableBodyClasses(classes).isEmpty)
  }

  @Test("should list and query only the kinds of enabled modules, and count only them")
  func historyFollowsModules() async throws {
    let (context, _) = try ReflectTesting.world()
    try await ReflectTesting.seed([ReflectTesting.meal("Soup", day: 0), ReflectTesting.meal("Bread", day: 0)], in: context.stores.main)
    try await ReflectTesting.logExpenses([ReflectTesting.expense(450, day: 0, merchant: "Corner Café")], in: context)
    let model = HistoryModel(context: context)
    model.apply(try Self.selection(.money))

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await QuestsObservation { await model.observeOverall() }.during {
          try await TestClock.until("the money records load") { model.history.state.value != nil && model.recordCount != nil }
          #expect(model.rows.map(\.kind) == [.expense])
          #expect(model.filters.compactMap { $0 } == [.expense])
          #expect(model.recordCount == 1, "the meals are not counted")
          #expect(model.history.state.value?.classes == [.general], "no body store is read while the body module is off")
          model.filter(.meal)
          #expect(model.kind == nil, "a kind of a disabled module cannot be chosen")
          #expect(HistoryTotalsCopy.lines(try #require(model.history.state.value?.totals), modules: model.modules).count == 1)
          model.setSearch("nothing like this")
          try await QuestsObservation { await model.observe() }.during {
            try await TestClock.until("the search comes up empty") { model.history.state.value?.records.total == 0 }
            #expect(model.recordCount == 1, "what is logged stays counted beside a search that matches nothing")
          }
        }
      }
    }
  }

  @Test("should drop the filter of a module turned off and show everything again when all are on")
  func historyFollowsSelectionChanges() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = HistoryModel(context: context)
    model.filter(.meal)
    #expect(model.kind == .meal)

    model.apply(try Self.selection(.money))
    #expect(model.kind == nil)
    #expect(model.query?.kinds == [.expense])
    model.apply(.all)
    #expect(model.query?.kinds == Set(HistoryKind.allCases))
    #expect(model.filters.count == HistoryKind.allCases.count + 1)
  }

  @Test("should filter a pushed record by the enabled kinds")
  func recordFollowsModules() async throws {
    let (context, _) = try ReflectTesting.world()
    let meal = ReflectTesting.meal("Soup", day: 0)
    try await ReflectTesting.seed([meal], in: context.stores.main)
    let id = "meal:\(meal.id.lowercasedString)"
    let model = HistoryRecordModel(context: context, id: id)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the meal is found") { if case .found = model.presentation { true } else { false } }
      }
      model.apply(try Self.selection(.money))
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the meal is no longer in the history") { model.presentation == .missing }
      }
    }
  }

  @Test("should show only the sections of enabled modules in the statistics")
  func insightsFollowModules() async throws {
    let (context, _) = try ReflectTesting.world()
    try await ReflectTesting.logExpenses([ReflectTesting.expense(450, day: 0, merchant: "Corner Café")], in: context)
    let model = InsightsModel(context: context)
    model.apply(try Self.selection(.money))

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the statistics load") { model.shown != nil }
        let statistics = try #require(model.shown)
        #expect(model.sections == InsightSections(try Self.selection(.money)))
        #expect(statistics.bodyClasses.isEmpty, "no body store is read while the body module is off")
        #expect(InsightsPresentation.kpis(statistics, streak: nil, modules: model.modules).map(\.kind) == [.spend])
        #expect(InsightsPresentation.kpis(statistics, streak: nil, modules: try Self.selection(.hero, .quests)).map(\.kind) == [.kept, .streak, .xp])
        #expect(InsightsPresentation.kpis(statistics, streak: nil, modules: try Self.selection(.hero, .money)).map(\.kind) == [.xp, .spend])
        #expect(InsightsPresentation.kpis(statistics, streak: nil, modules: try Self.selection(.journal)).isEmpty)
      }
    }
  }

  @Test("should start the review on its first enabled step and walk only enabled ones")
  func reviewStartsOnFirstEnabledStep() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = WeeklyReviewModel(context: context)
    model.apply(try Self.selection(.money))

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the review loads") { model.week != nil }
        #expect(model.step == .money)
        await model.back()
        #expect(model.step == .money, "there is nothing before the first enabled step")
        await model.show(.kept)
        #expect(model.step == .money, "a hidden step cannot be shown")
        await model.advance()
        #expect(model.step == .reflect)
        await model.advance()
        #expect(model.step == .done)
      }
    }
  }

  @Test("should move to the next enabled step when the current one disappears, keeping the answers")
  func reviewMovesOffAHiddenStep() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = WeeklyReviewModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the review loads") { model.week != nil }
        await model.show(.reflect)
        model.drafts[.better] = "Typed before"
        await model.show(.money)
        model.apply(try Self.selection(.hero, .quests))
        #expect(model.step == .reflect, "money is gone, the next enabled step follows")
        #expect(model.furthest == .reflect)
        #expect(model.drafts[.better] == "Typed before")
        model.apply(.all)
        #expect(model.step == .reflect)
        await model.show(.kept)
        model.apply(try Self.selection(.money))
        #expect(model.step == .money)
        #expect(model.steps == [.money, .reflect, .done])
      }
    }
  }

  @Test("should glance and summarise only the values of enabled modules")
  func reviewGlanceFollowsModules() async throws {
    let (context, _) = try ReflectTesting.world()
    try await ReflectTesting.logExpenses([ReflectTesting.expense(450, day: -7, merchant: "Market")], in: context)
    let model = WeeklyReviewModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the review loads") { model.review.state.value?.money?.expenseCount == 1 }
        let review = try #require(model.review.state.value)
        #expect(WeeklyReviewPresentation.glance(review).count == 5)
        #expect(WeeklyReviewPresentation.glance(review, modules: try Self.selection(.money)).count == 1)
        #expect(WeeklyReviewPresentation.glance(review, modules: try Self.selection(.journal, .meals)).count == 1)
        #expect(WeeklyReviewPresentation.glance(review, modules: try Self.selection(.hero, .quests)).count == 3)
        #expect(WeeklyReviewPresentation.summary(review, modules: try Self.selection(.money)).count == 1)
        #expect(WeeklyReviewPresentation.summary(review, modules: try Self.selection(.hero, .money)).count == 2)
      }
    }
  }

  @Test("should offer a suggestion only when its screen shows")
  func asksOnlyVisibleSuggestions() throws {
    let quest = UUID()
    let suggestions = [InsightSuggestion(kind: .known(.shiftTime), quest: quest, text: "Move it")]
    let hidden = MemoirNavigationMap(try Self.selection(.money))
    let shown = MemoirNavigationMap(.all)
    #expect(AskSuggestionLink.offered(suggestions, shows: { hidden.shows($0) }).isEmpty)
    #expect(AskSuggestionLink.offered(suggestions, shows: { shown.shows($0) }).count == 1)
  }
}
