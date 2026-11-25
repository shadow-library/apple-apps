import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("Savings", TestTimeLimit.standard)
struct SavingsTests {
  private typealias W = SavingsWorld
  private let english = SavingsWorld.english

  @Test("should follow savings under budget, what can be drawn, the pace and the deposit history, and fill the goal")
  func followsSavings() async throws {
    let world = try await W()
    let model = SavingsModel(context: world.context)
    let task = Task { await model.run() }
    defer { task.cancel() }
    try await TestClock.until("savings are read") { model.value != nil }
    let snapshot = try #require(model.value)
    let balance = snapshot.overview.balance
    #expect(balance.balanceMinor == 40_000)
    #expect(balance.availableMinor == 140_000, "what is saved and as much again as Home's limit")
    #expect(balance.standing == .saving)
    #expect(SavingsCopy.available(balance, locale: english) == String(localized: "Available to draw: €1,400.00", table: "Money"))
    #expect(snapshot.overview.history.map(\.depositedMinor) == [10_000, 10_000, 10_000, 10_000])
    #expect(SavingsCopy.pace(snapshot.overview.pace, home: snapshot.home, locale: english).contains("€100.00"))
    let share = try #require(snapshot.active.first)
    #expect(share.progressThousandths == 400)
    #expect(GoalCopy.accessibilityLabel(share, forecast: snapshot.overview.forecast(of: W.bike), locale: english) == "New bike, 40% saved, around September 2026")

    _ = try await world.expense(50_000, fromSavings: 50_000, goal: W.bike)
    try await TestClock.until("the purchase is read") { model.value?.overview.balance.balanceMinor == -10_000 }
    #expect(model.value?.active.first?.progressThousandths == 500, "a purchase never moves its goal backwards")
  }

  @Test("should say savings pay back what they owe first, for the balance and every goal")
  func repays() async throws {
    let world = try await W(deposits: [10_000], goals: [W.goal(W.bike), W.goal(W.laptop, name: "Laptop", rank: "2")])
    try await world.expense(30_000, fromSavings: 30_000)
    let snapshot = try await world.snapshot()
    #expect(snapshot.overview.balance.standing == .repaying(owedMinor: 20_000))
    #expect(snapshot.overview.forecasts.map(\.state) == [.repaying(owedMinor: 20_000), .repaying(owedMinor: 20_000)])
    #expect(SavingsCopy.repaying(20_000, home: snapshot.home, locale: english) == String(localized: "You’ll pay back €200.00 first", table: "Money"))
    let line = snapshot.forecastLine(try #require(snapshot.overview.forecasts.first), locale: english)
    #expect(line == String(localized: "Savings pay back €200.00 first, then this goal starts filling.", table: "Money"))
  }

  @Test("should name what savings leave out: draws waiting for a rate and deposits in another currency")
  func notesWhatIsLeftOut() async throws {
    let world = try await W()
    let krone = ExpenseRecord(
      id: UUID(), amountMinor: 50_000, currency: MoneyFixture.krone, occurredOn: TestClock.day0, category: MoneyFixture.food, fromSavingsMinor: 40_000,
      loggedAtMillis: 0)
    let foreign = SavingsDepositRecord(
      budget: UUID(), periodStart: W.date("2026-02-01"),
      deposit: SavingsDeposit(
        amountMinor: 5_000, currency: MoneyFixture.krone, closedOn: TestClock.day0, command: UUID(), spentMinor: 0, limitMinor: nil, medianExpenseMinor: nil))
    try await world.write([krone, foreign])
    let notes = SavingsCopy.notes(try await world.snapshot().overview.balance)
    #expect(notes.count == 2)
    #expect(notes.first == String(localized: "\(1) draws wait for an exchange rate and aren’t counted yet.", table: "Money"))
    #expect(notes.first?.contains("1 draw waits") == true, "the plural takes the one form")
  }

  @Test("should turn a list move into the index among the other goals")
  func convertsMoves() {
    #expect(GoalsModel.target(from: 0, to: 3) == 2)
    #expect(GoalsModel.target(from: 0, to: 2) == 1)
    #expect(GoalsModel.target(from: 2, to: 0) == 0)
    #expect(GoalsModel.target(from: 1, to: 1) == 1)
    let listed = [W.bike, W.laptop, W.trip]
    #expect(GoalsModel.previous(of: 0, to: 3, in: listed) == W.trip)
    #expect(GoalsModel.previous(of: 0, to: 2, in: listed) == W.laptop)
    #expect(GoalsModel.previous(of: 2, to: 0, in: listed) == nil)
    #expect(GoalsModel.previous(of: 2, to: 1, in: listed) == W.bike)
  }

  @Test("should move goals by their neighbour, a goal in another currency keeping its place, and count it against the limit")
  func movesAroundAnotherCurrency() async throws {
    var dollars = W.goal(W.trip, name: "Trip", rank: "2")
    dollars.currency = CurrencyCode("USD")!
    let world = try await W(goals: [W.goal(W.bike), dollars, W.goal(W.laptop, name: "Laptop", rank: "3")])
    let snapshot = try await world.snapshot()
    #expect(snapshot.active.map(\.id) == [W.bike, W.laptop])
    #expect(snapshot.otherCurrencyActive.map(\.id) == [W.trip])
    #expect(snapshot.activeCount == 3 && !snapshot.canAddGoal, "the core counts the goal in another currency too")
    #expect(snapshot.settled.isEmpty)

    let model = GoalsModel(context: world.context)
    let task = Task { await model.run() }
    defer { task.cancel() }
    try await TestClock.until("the goals are read") { model.savings.value?.active.count == 2 }
    #expect(await model.move(from: [1], to: 0))
    #expect(model.failure == nil)
    try await TestClock.until("the move is read") { model.savings.value?.active.map(\.id) == [W.laptop, W.bike] }
    #expect(try await world.goal(W.trip).rank == SavingsGoalRank("2"))
    #expect(await model.abandon(W.trip), "a goal in another currency can be set aside")
    #expect(try await world.snapshot().settled.map(\.id) == [W.trip])
  }

  @Test("should reorder the active goals, the moved one alone changing rank")
  func reorders() async throws {
    let world = try await W(goals: [
      W.goal(W.bike), W.goal(W.laptop, name: "Laptop", rank: "2"), W.goal(W.trip, name: "Trip", rank: "3"),
    ])
    let model = GoalsModel(context: world.context)
    let task = Task { await model.run() }
    defer { task.cancel() }
    try await TestClock.until("the goals are read") { model.savings.value?.active.count == 3 }
    #expect(await model.move(from: [0], to: 3))
    try await TestClock.until("the move is read") { model.savings.value?.active.map(\.id) == [W.laptop, W.trip, W.bike] }
    #expect(try await world.goal(W.laptop).rank == SavingsGoalRank("2"), "the goals that did not move keep their ranks")
    #expect(await model.move(from: [2], to: 0))
    try await TestClock.until("the second move is read") { model.savings.value?.active.map(\.id) == [W.bike, W.laptop, W.trip] }
    #expect(model.failure == nil)
  }

  @Test("should refuse to mark a goal bought until an expense names it, then mark it with its rewards")
  func marksBought() async throws {
    let world = try await W()
    let model = GoalsModel(context: world.context)
    #expect(await !model.markBought(W.bike))
    #expect(model.failure?.headline == String(localized: "Pick this goal on the expense that bought it first.", table: "Writing"))
    #expect(try await world.goal(W.bike).state == .known(.active))

    try await world.expense(95_000, fromSavings: 40_000, goal: W.bike, note: "Bike shop")
    #expect(await model.markBought(W.bike))
    #expect(model.failure == nil)
    #expect(model.notice == .bought(rewarded: true), "a target of a whole Home limit earns rewards")
    #expect(try await world.goal(W.bike).state == .known(.bought))
    let bodies = try await MoneyFixture.bodies(world.context)
    #expect(bodies.contains(.goalBought(GoalPurchase(goalId: W.bike, outcome: .within))))
    #expect(await !model.markBought(W.bike))
    #expect(model.failure?.headline == String(localized: "That goal is no longer active.", table: "Writing"))
  }

  @Test("should mark a goal too small for rewards bought without any")
  func marksASmallGoalBought() async throws {
    let world = try await W(goals: [W.goal(W.bike, target: 10_000)])
    try await world.expense(9_000, goal: W.bike)
    let model = GoalsModel(context: world.context)
    #expect(await model.markBought(W.bike))
    #expect(model.notice == .bought(rewarded: false))
    #expect(try await MoneyFixture.bodies(world.context).isEmpty, "no reward command for a goal below a quarter of Home's limit")
  }

  @Test("should set a goal aside, returning its share, and delete one")
  func abandonsAndDeletes() async throws {
    let world = try await W(goals: [W.goal(W.bike, target: 30_000), W.goal(W.laptop, name: "Laptop", rank: "2")])
    #expect(try await world.snapshot().active.map(\.shareMinor) == [30_000, 10_000])
    let model = GoalsModel(context: world.context)
    #expect(await model.abandon(W.bike))
    #expect(model.notice == .abandoned)
    let snapshot = try await world.snapshot()
    #expect(snapshot.active.map(\.shareMinor) == [40_000], "the share returns to the goals after it")
    #expect(GoalCopy.state(try #require(snapshot.goal(W.bike)), home: snapshot.home) == String(localized: "Set aside", table: "Money"))
    #expect(await model.delete(W.bike))
    #expect(model.notice == .deleted)
    #expect(try await world.snapshot().goal(W.bike) == nil)
    #expect(await !model.delete(W.bike))
    #expect(model.failure?.headline == String(localized: "That’s no longer available.", table: "Writing"))
  }

  @Test("should keep more than three active goals synced in, and offer no fourth")
  func keepsGoalsPastTheLimit() async throws {
    let goals = [
      W.goal(W.bike), W.goal(W.laptop, name: "Laptop", rank: "2"), W.goal(W.trip, name: "Trip", rank: "3"), W.goal(W.sofa, name: "Sofa", rank: "4"),
    ]
    let world = try await W(goals: goals)
    let snapshot = try await world.snapshot()
    #expect(snapshot.active.count == 4)
    #expect(!snapshot.canAddGoal)
    let form = GoalForm(home: snapshot.home, today: TestClock.day0, context: world.context, locale: english)
    form.name = "Camera"
    form.targetText = "500"
    #expect(await form.save() == nil)
    #expect(form.failure?.headline == String(localized: "You can have up to 3 goals at once. Finish or set one aside first.", table: "Writing"))
  }
}

@MainActor
@Suite("GoalForm", TestTimeLimit.standard)
struct GoalFormTests {
  private typealias W = SavingsWorld

  @Test("should create a goal in the home currency, its target read in the owner's locale and its date optional")
  func creates() async throws {
    let world = try await W(goals: [])
    let form = GoalForm(home: MoneyFixture.euro, today: TestClock.day0, context: world.context, locale: MoneyFixture.german)
    #expect(!form.canSave)
    form.name = "  Neues Rad  "
    form.symbol = "car.fill"
    form.targetText = "1.500,50"
    #expect(form.canSave)
    form.hasTargetDate = true
    form.targetDate = W.date("2026-12-01")
    let id = try #require(await form.save())
    let goal = try await world.goal(id)
    #expect(goal.name == "Neues Rad" && goal.symbol == "car.fill" && goal.targetMinor == 150_050 && goal.currency == MoneyFixture.euro)
    #expect(goal.targetDate == W.date("2026-12-01") && goal.createdOn == TestClock.day0 && goal.state == .known(.active))
  }

  @Test("should show a target that does not read, and save nothing")
  func refusesABadTarget() async throws {
    let world = try await W(goals: [])
    let form = GoalForm(home: MoneyFixture.euro, today: TestClock.day0, context: world.context, locale: MoneyFixture.english)
    form.name = "Bike"
    form.targetText = "12.345"
    #expect(form.targetIssue != nil)
    #expect(!form.canSave)
    #expect(await form.save() == nil)
    form.targetText = "0"
    #expect(form.canSave, "the core refuses a zero target")
    #expect(await form.save() == nil)
    #expect(form.failure?.headline == String(localized: "A goal’s target has to be more than zero.", table: "Writing"))
    #expect(try await world.goals().isEmpty)
  }

  @Test("should edit a goal, and keep a bought goal's target")
  func edits() async throws {
    let world = try await W(goals: [W.goal(W.bike), W.goal(W.laptop, name: "Laptop", rank: "2", state: .bought)])
    let bike = try await world.goal(W.bike)
    let form = GoalForm(editing: bike, home: MoneyFixture.euro, today: TestClock.day0, context: world.context, locale: MoneyFixture.english)
    #expect(form.targetText == "1000.00")
    #expect(!form.canSave, "nothing changed yet")
    form.targetText = "1200"
    #expect(form.hasChanges)
    #expect(await form.save() == W.bike)
    #expect(try await world.goal(W.bike).targetMinor == 120_000)

    let laptop = GoalForm(editing: try await world.goal(W.laptop), home: MoneyFixture.euro, today: TestClock.day0, context: world.context, locale: MoneyFixture.english)
    #expect(!laptop.canChangeTarget)
    laptop.name = "Old laptop"
    #expect(await laptop.save() == W.laptop)
    #expect(try await world.goal(W.laptop).name == "Old laptop")
  }

  @Test("should offer the curated symbols, and a goal's own symbol from elsewhere first")
  func offersSymbols() async throws {
    let world = try await W(goals: [])
    var goal = W.goal(W.bike)
    goal.symbol = "star.fill"
    let form = GoalForm(editing: goal, home: MoneyFixture.euro, today: TestClock.day0, context: world.context, locale: MoneyFixture.english)
    #expect(form.symbols.first == "star.fill" && form.symbols.count == GoalCopy.symbols.count + 1)
    for symbol in GoalCopy.symbols { #expect(GoalCopy.symbolName(symbol) != GoalCopy.symbolName("star.fill"), "\(symbol) has its own name") }
  }
}

@MainActor
@Suite("GoalCopy", TestTimeLimit.quick)
struct GoalCopyTests {
  private let locale = MoneyFixture.english
  private let today = TestClock.day0
  private let cause = UUID()

  private func line(_ state: GoalForecastState, eta: LocalDate? = nil, target: LocalDate? = nil, leverEta: LocalDate? = nil) -> String {
    GoalCopy.forecast(
      state, eta: eta, target: target, leverEta: leverEta, today: today, home: MoneyFixture.euro, cause: { $0 == cause ? "Concert tickets" : nil },
      category: { MoneyLabels.categoryName($0) }, locale: locale)
  }

  @Test("should have its own words for every forecast state, naming what each needs")
  func coversEveryState() {
    let september = SavingsWorld.date("2026-09-01")
    let june = SavingsWorld.date("2026-06-30")
    let lines = [
      line(.onTrack(eta: september)),
      line(.aheadOfTarget(eta: SavingsWorld.date("2026-05-01"), target: june)),
      line(.behind(extraPerMonthMinor: 12_000, extraPerDayMinor: 400), target: june),
      line(.lever(category: MoneyFixture.food, monthsSooner: 2), leverEta: SavingsWorld.date("2026-07-01")),
      line(.noPace),
      line(.calibrating(monthsLeft: 1)),
      line(.pushedBack(byDays: 31, cause: cause), eta: september),
      line(.repaying(owedMinor: 20_000)),
      line(.reached(buyFrom: today)),
      line(.reached(buyFrom: SavingsWorld.date("2026-03-04"))),
    ]
    #expect(Set(lines).count == lines.count, "every state reads differently")
    #expect(lines[0] == "On track for around September 2026.")
    #expect(lines[1].contains("May 2026") && lines[1].contains("Jun 30, 2026"))
    #expect(lines[2] == "To reach it by Jun 30, 2026, it needs about €120.00 more a month, about €4.00 a day.")
    #expect(lines[3] == "Spending 10% less on Food could bring it about 2 months sooner, to around July 2026.")
    #expect(lines[5] == "An estimate comes once budgets have closed 1 more month.")
    #expect(lines[6] == "“Concert tickets” drew on savings this month, so it moves about 31 days later, to around September 2026.")
    #expect(lines[7].contains("€200.00"))
    #expect(lines[9].contains("Mar 4, 2026"))
    for line in lines {
      for word in ["fail", "bad", "wasted", "should have", "overspent"] { #expect(!line.localizedCaseInsensitiveContains(word), "\(line)") }
    }
  }

  @Test("should fall back gracefully when the push names an expense no longer readable")
  func pushedBackWithoutACause() {
    #expect(line(.pushedBack(byDays: 1, cause: UUID()), eta: SavingsWorld.date("2026-09-01")).hasPrefix("A draw on savings this month moves it about 1 day later"))
  }

  @Test("should say neutrally whether a goal earns rewards, for every reason")
  func explainsEligibility() {
    let cases: [GoalRewardEligibility] = [.eligible, .targetBelowMinimum(minimumMinor: 25_000), .homeWithoutLimit, .limitAwaitingRate, .otherCurrency]
    let lines = cases.map { GoalCopy.eligibility($0, home: MoneyFixture.euro, locale: locale) }
    #expect(Set(lines).count == cases.count)
    #expect(lines[1] == "Goals of at least €250.00 earn rewards.")
    #expect(lines[4].contains("EUR"))
  }

  @Test("should round the share saved down to a whole percent")
  func roundsDown() {
    #expect(GoalCopy.percent(999, locale: locale) == "99%")
    #expect(GoalCopy.percent(1000, locale: locale) == "100%")
    #expect(GoalCopy.percent(4, locale: locale) == "0%")
  }
}
