import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("Expense form savings", TestTimeLimit.standard)
struct SavingsDrawTests {
  private typealias W = SavingsWorld
  private let current = Locale.autoupdatingCurrent

  private func saved(_ world: W, _ id: UUID) async throws -> ExpenseRecord {
    try #require(try await MoneyFixture.expenseEntries(world.context).first { $0.record.id == id }?.record)
  }

  @Test("should pay part of a goal's purchase from savings, exempt from the one-off rule")
  func buysAGoal() async throws {
    let world = try await W()
    let form = try await world.form()
    #expect(form.goalChoices == [GoalChoice(id: W.bike, name: "New bike")])
    form.amountText = "150"
    form.fromSavingsText = "120"
    form.goal = W.bike
    #expect(form.savingsNotes(locale: W.english).first?.hasPrefix("Buying a goal needn’t be a one-off.") == true)
    let id = try #require(await form.save())
    let expense = try await saved(world, id)
    #expect(expense.fromSavingsMinor == 12_000 && expense.goal == W.bike)
  }

  @Test("should name the budget's one-off threshold before saving, and in the refusal of a smaller draw")
  func refusesASmallDraw() async throws {
    let world = try await W()
    let form = try await world.form()
    form.amountText = "50"
    form.fromSavingsText = "50"
    #expect(form.savingsNotes(locale: W.english).first == "Only a one-off can be paid from savings: in Home, €200.00 or more.")
    #expect(form.savingsNotes(locale: W.english).contains("Available to draw: €1,400.00"))
    #expect(await form.save() == nil)
    let threshold = MoneyText.formatted(W.oneOff, MoneyFixture.euro, locale: current)
    #expect(form.failure?.headline == String(localized: "Savings are for one-off purchases: in this budget, \(threshold) or more.", table: "Writing"))
    #expect(form.failure?.detail == "memoir_finance.not_one_off")
    #expect(try await MoneyFixture.expenseEntries(world.context).isEmpty)
  }

  @Test("should name what savings can cover when a draw is larger")
  func refusesTooLargeADraw() async throws {
    let world = try await W()
    let form = try await world.form()
    form.amountText = "3000"
    form.fromSavingsText = "2000"
    #expect(await form.save() == nil)
    let available = MoneyText.formatted(140_000, MoneyFixture.euro, locale: current)
    #expect(form.failure?.headline == String(localized: "Your savings can cover up to \(available) right now.", table: "Writing"))
  }

  @Test("should give the day a goal can be bought from while it cools off")
  func waitsForTheCoolingOff() async throws {
    let world = try await W(goals: [W.goal(W.bike, createdOn: "2026-03-02")])
    let form = try await world.form()
    form.amountText = "300"
    form.goal = W.bike
    #expect(await form.save() == nil)
    let day = MoneyDates.text(W.date("2026-03-05"), locale: current)
    #expect(form.failure?.headline == String(localized: "This goal can be bought from \(day), a few days after it was made.", table: "Writing"))
  }

  @Test("should say a draw in another currency waits for its rate")
  func waitsForARate() async throws {
    let world = try await W()
    let form = try await world.form()
    form.select(MoneyFixture.krone)
    form.amountText = "5000"
    form.fromSavingsText = "3000"
    #expect(form.savingsNotes(locale: W.english).last?.hasPrefix("A part from savings in NOK needs a rate") == true)
    #expect(await form.save() == nil)
    #expect(form.failure?.headline == String(localized: "This needs an exchange rate before it can be paid from savings.", table: "Writing"))
  }

  @Test("should read the part from savings in the owner's locale, and mark one that does not read")
  func readsThePart() async throws {
    let world = try await W()
    let form = try await world.form(locale: MoneyFixture.german)
    form.amountText = "300"
    form.fromSavingsText = "12,345"
    #expect(form.fromSavingsIssue != nil)
    #expect(!form.canSave)
    form.fromSavingsText = "250,50"
    #expect(form.fromSavings == .success(25_050))
    form.fromSavingsText = ""
    #expect(form.fromSavings == .success(nil))
    #expect(form.canSave)
  }

  @Test("should keep a deleted goal an expense names, and save other changes without checking it again")
  func keepsADeletedGoal() async throws {
    let world = try await W()
    let expense = try await world.expense(30_000, fromSavings: 10_000, goal: W.bike, note: "Bike")
    try await world.context.writer.write { _, transaction in try GoalEdits.delete(W.bike, in: &transaction) }
    let form = try await world.form(.edit(expense))
    #expect(form.goal == W.bike)
    #expect(form.goalChoices == [GoalChoice(id: W.bike, name: String(localized: "A deleted goal", table: "Money"))])
    #expect(form.fromSavingsText == "100.00")
    #expect(form.savingsNotes(locale: W.english).contains("Available to draw: €1,300.00, besides what this expense already draws."))
    form.note = "Bike, second hand"
    #expect(await form.save() == expense.id)
    let saved = try await saved(world, expense.id)
    #expect(saved.goal == W.bike && saved.fromSavingsMinor == 10_000 && saved.note == "Bike, second hand")
  }

  @Test("should name the savings refusals with the form's currencies, and fall back without them")
  func presentsSavingsRefusals() {
    let amounts = SavingsAmounts(budget: MoneyFixture.krone, home: MoneyFixture.euro)
    let notOneOff = MemoirWriteError.command(.refused(.finance(.notOneOff(thresholdMinor: 50_000))))
    let named = WritingErrors.presented(notOneOff, savings: amounts)
    #expect(named?.headline.contains(MoneyText.formatted(50_000, MoneyFixture.krone, locale: current)) == true)
    #expect(named?.detail == "memoir_finance.not_one_off")
    let plain = String(localized: "Savings are for one-off purchases, and this expense is below this budget’s one-off amount.", table: "Writing")
    #expect(WritingErrors.presented(notOneOff)?.headline == plain)
    #expect(WritingErrors.presented(MemoirWriteError.command(.refused(.finance(.notOneOff(thresholdMinor: nil)))), savings: amounts)?.headline == plain)
    #expect(WritingErrors.presented(MemoirWriteError.cancelled, savings: amounts) == nil)
  }
}

@MainActor
@Suite("Category essentials", TestTimeLimit.standard)
struct CategoryEssentialTests {
  @Test("should mark a category essential, then go back to its default")
  func togglesEssential() async throws {
    let context = try await MoneyFixture.context()
    let model = CategoriesModel(context: context)
    let task = Task { await model.run() }
    defer { task.cancel() }
    func entry() -> CategoryEntry? { model.overview.state.value?.overview.categories.first { $0.key == MoneyFixture.food } }
    try await TestClock.until("the categories are read") { entry() != nil }
    #expect(entry()?.essential == .byDefault(false))
    #expect(CategoryCopy.essential(try #require(entry())) == nil)

    await model.setEssential(MoneyFixture.food, true)
    #expect(model.failure == nil)
    #expect(model.notice == String(localized: "Marked essential. Goal tips won’t suggest spending less on it.", table: "Money"))
    try await TestClock.until("the choice is read") { entry()?.essential == .byOwner(true) }
    #expect(CategoryCopy.essential(try #require(entry())) == String(localized: "Essential", table: "Money"))
    #expect(entry()?.label == "Food", "the record is created with the built-in's stored label")

    await model.setEssential(MoneyFixture.food, nil)
    try await TestClock.until("the default is read") { entry()?.essential == .byDefault(false) }
    #expect(!CategoryCopy.offersEssential(try #require(model.overview.state.value?.overview.categories.first { $0.key == MoneyFixture.uncategorised })))
  }
}

@MainActor
@Suite("Weekly review goal", TestTimeLimit.standard)
struct WeeklyReviewGoalTests {
  @Test("should show the goal savings fill first, how fast savings grow and its forecast")
  func showsTheTopGoal() async throws {
    let world = try await SavingsWorld(goals: [
      SavingsWorld.goal(SavingsWorld.laptop, name: "Laptop", rank: "2"), SavingsWorld.goal(SavingsWorld.bike, rank: "1"),
    ])
    let model = WeeklyReviewModel(context: world.context)
    let task = Task { await model.observeSavings() }
    defer { task.cancel() }
    try await TestClock.until("savings are read") { model.savings.state.value != nil }
    let goal = try #require(WeeklyReviewPresentation.goal(model.savings.state.value ?? nil, locale: SavingsWorld.english))
    #expect(goal.name == "New bike")
    #expect(goal.saved == "40% saved")
    #expect(goal.pace == "Savings grow about \(ReflectFormat.money(10_000, MoneyFixture.euro)) a month.")
    #expect(goal.forecast == "On track for around September 2026.")
    #expect(goal.accessibilityLabel == "New bike, 40% saved, around September 2026")
  }

  @Test("should leave the section out without a goal filling")
  func leavesItOut() async throws {
    let world = try await SavingsWorld(goals: [SavingsWorld.goal(SavingsWorld.bike, state: .bought)])
    #expect(WeeklyReviewPresentation.goal(try await world.snapshot(), locale: SavingsWorld.english) == nil)
    #expect(WeeklyReviewPresentation.goal(nil, locale: SavingsWorld.english) == nil)
  }
}
