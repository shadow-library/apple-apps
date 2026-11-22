import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("HistoryModel", TestTimeLimit.standard)
struct HistoryModelTests {
  @Test("should say nothing is logged yet on an empty vault")
  func showsTheEmptyState() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = HistoryModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the history loads") { model.history.state.value != nil }
        #expect(model.history.state.value?.totalRecords == 0)
        #expect(model.groups.isEmpty)
        #expect(model.pageCount == 1)
      }
    }
  }

  @Test("should page twenty records at a time, newest first, grouped by day with today named")
  func pagesTheStream() async throws {
    let (context, _) = try ReflectTesting.world()
    let meals = (0..<25).map { ReflectTesting.meal("Meal \($0)", day: -($0 / 5), minute: 600 + $0) }
    try await ReflectTesting.seed(meals, in: context.stores.main)
    let model = HistoryModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the first page loads") { model.history.state.value?.records.items.count == 20 }
        #expect(model.pageCount == 2)
        #expect(model.groups.first?.date == TestClock.day0)
        #expect(model.groups.first?.label.hasPrefix(String(localized: "Today", table: "Reflect")) == true)
        #expect(model.rows.first?.text == "Meal 4", "the latest logged on the newest day comes first")
        #expect(model.rows.map(\.date) == model.rows.map(\.date).sorted(by: >))
      }
      model.go(to: 2)
      #expect(model.page == 2)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the second page loads") { model.history.state.value?.records.offset == 20 }
        #expect(model.history.state.value?.records.items.count == 5)
      }
      model.go(to: 9)
      #expect(model.page == 2, "a page past the end is never asked for")
    }
  }

  @Test("should filter by kind and search names, starting again from the first page, and clear both")
  func filtersAndSearches() async throws {
    let (context, _) = try ReflectTesting.world()
    try await ReflectTesting.seed((0..<22).map { ReflectTesting.meal("Soup \($0)", day: 0) }, in: context.stores.main)
    try await ReflectTesting.logExpenses(
      [ReflectTesting.expense(450, day: 0, merchant: "Corner Café"), ReflectTesting.expense(1_200, day: -1, merchant: "Market")], in: context)
    let model = HistoryModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("everything loads") { (model.history.state.value?.totalRecords ?? 0) >= 24 }
      }
      let total = try #require(model.history.state.value?.totalRecords)
      model.go(to: 2)
      model.filter(.expense)
      #expect(model.page == 1)
      #expect(model.isFiltered)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the expenses load") { model.history.state.value?.records.total == 2 }
        #expect(model.rows.allSatisfy { $0.kind == .expense })
        #expect(model.rows.first?.text == "Food — Corner Café")
        guard case .money(.expense)? = model.rows.first?.link.route else {
          Issue.record("an expense record should open its expense")
          return
        }
        let totals = try #require(model.history.state.value?.totals)
        #expect(totals.expenses == 2 && totals.spent?.totalMinor == 1_650)
        #expect(HistoryTotalsCopy.lines(totals).count == 4, "no expense waits for a rate")
      }
      model.filter(nil)
      model.setSearch("  café ")
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the search narrows the stream") { model.history.state.value?.records.total == 1 }
        #expect(model.rows.first?.title == "Corner Café")
      }
      model.setSearch("nothing like this")
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("nothing matches") { model.history.state.value?.records.total == 0 }
        #expect(model.history.state.value?.totalRecords == total, "everything logged is still there")
      }
      model.clearFilters()
      #expect(model.kind == nil && model.search.isEmpty && !model.isFiltered)
    }
  }

  @Test("should move back to the last page when records go away under it")
  func clampsAPagePastTheEnd() async throws {
    let (context, _) = try ReflectTesting.world()
    let meals = (0..<21).map { ReflectTesting.meal("Meal \($0)", day: 0, minute: 600 + $0) }
    try await ReflectTesting.seed(meals, in: context.stores.main)
    let model = HistoryModel(context: context)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("two pages load") { model.pageCount == 2 }
      }
      model.go(to: 2)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the second page loads") { model.history.state.value?.records.offset == 20 }
        try await context.stores.main.write { transaction in
          _ = try MealRecord.remove(meals[0].ref, in: &transaction)
          _ = try MealRecord.remove(meals[1].ref, in: &transaction)
        }
        try await TestClock.until("the page moves back") { model.page == 1 }
      }
    }
  }

  @Test("should present a quest log with its outcome and open the quest it belongs to")
  func presentsAQuestLog() async throws {
    let (context, _) = try ReflectTesting.world()
    let walk = try await QuestsTesting.quest("Walk", in: context)
    try await ReflectTesting.complete(walk, on: 0, in: context)
    let model = HistoryModel(context: context)
    model.filter(.quest)

    try await ReflectTesting.following(model.day) {
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the log loads") { model.rows.count == 1 }
        let row = try #require(model.rows.first)
        #expect(row.text.hasPrefix("Walk · "))
        #expect(row.value.hasPrefix("+"))
        #expect(row.time != nil)
        #expect(row.link.route == .quest(.detail(walk)))
        #expect(row.fields.map(\.label).first == String(localized: "Outcome", table: "Reflect"))
      }
    }
  }

  @Test("should find a record by id, say when the filter hides it, and when it was deleted")
  func looksUpARecord() async throws {
    let (context, _) = try ReflectTesting.world()
    let meal = ReflectTesting.meal("Ramen", day: 0)
    try await ReflectTesting.seed([meal], in: context.stores.main)
    let id = "meal:\(meal.id.uuidString.lowercased())"
    let found = HistoryRecordModel(context: context, id: id)
    let filtered = HistoryRecordModel(context: context, id: id, kind: .expense)

    try await ReflectTesting.following(found.day) {
      try await ReflectTesting.following(filtered.day) {
        try await QuestsObservation { await found.observe() }.during {
          try await QuestsObservation { await filtered.observe() }.during {
            try await TestClock.until("the record is found") { if case .found = found.presentation { true } else { false } }
            guard case .found(let presentation) = found.presentation else { return }
            #expect(presentation.title == "Ramen")
            #expect(presentation.link.route == .destination(.meals))
            try await TestClock.until("the filter hides it") { filtered.presentation == .missing }
            try await context.stores.main.write { transaction in _ = try MealRecord.remove(meal.ref, in: &transaction) }
            try await TestClock.until("the deletion shows") { found.presentation == .missing }
          }
        }
      }
    }
  }

  @Test("should leave weight out when its class is not read on this device, and say so")
  func hidesAClassThisDeviceDoesNotHold() async throws {
    let (context, _) = try ReflectTesting.world()
    try await ReflectTesting.seed([ReflectTesting.weight("72.4", day: 0)], in: context.stores.restricted)
    let without = HistoryModel(context: context, bodyClasses: [])
    let with = HistoryModel(context: context)
    without.filter(.weight)
    with.filter(.weight)
    #expect(without.kindIsNotHeld && !with.kindIsNotHeld)

    try await ReflectTesting.following(without.day) {
      try await ReflectTesting.following(with.day) {
        try await QuestsObservation { await without.observe() }.during {
          try await QuestsObservation { await with.observe() }.during {
            try await TestClock.until("the weight shows where health is read") { with.rows.count == 1 }
            try await TestClock.until("the other loads") { without.history.state.value != nil }
            #expect(without.history.state.value?.totalRecords == 0)
            #expect(without.history.state.value?.classes == [.general])
            #expect(with.rows.first?.value == String(localized: "\(ReflectFormat.decimal(DecimalText("72.4")!)) kg", table: "Reflect"))
          }
        }
      }
    }
    #expect(ReflectCopy.missingClasses([]).count == 2)
  }

  @Test("should apply typed search only once typing pauses, and drop what was typed over")
  func debouncesTheSearch() async throws {
    let (context, _) = try ReflectTesting.world()
    let model = HistoryModel(context: context)
    model.searchText = "so"
    let interrupted = Task { await model.applySearchAfterPause() }
    interrupted.cancel()
    await interrupted.value
    #expect(model.search.isEmpty, "a keystroke within the pause replaces the search before it applies")
    model.searchText = "soup"
    await model.applySearchAfterPause()
    #expect(model.search == "soup" && model.page == 1)
    model.clearFilters()
    #expect(model.searchText.isEmpty && model.search.isEmpty)
  }
}
