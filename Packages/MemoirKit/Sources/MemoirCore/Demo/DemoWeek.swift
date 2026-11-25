import Foundation
import ShadowCore
import ShadowStore

private struct Step {
  let day: Int
  let minute: Int
  let run: (inout WriteTransaction) throws -> Void
}

/// The past week as instants of the account's zone: day 0 is the first day of the week, the last is yesterday. The money history reaches back from it, so
/// its days count below zero; every step is written in the order it would have happened.
struct SampleWeek: Sendable {
  let clock: IssueClock
  let first: LocalDate
  let currency: CurrencyCode
  let money: DemoMoney

  init(clock: IssueClock, now: Date, currency: CurrencyCode) throws(CalendarError) {
    guard let millis = Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) else { throw .dateOutOfRange }
    let today = try clock.localDate(at: millis)
    guard let first = today.adding(days: -MemoirDemo.days) else { throw .dateOutOfRange }
    self.clock = clock
    self.first = first
    self.currency = currency
    self.money = try DemoMoney(first: first, home: currency)
  }

  func day(_ date: LocalDate) -> Int { date.days(since: first) }

  func date(_ day: Int) throws -> LocalDate {
    guard let date = first.adding(days: day) else { throw CalendarError.dateOutOfRange }
    return date
  }

  func millis(_ day: Int, minute: Int) throws -> Int64 {
    try clock.resolve(minuteOfDay: minute, on: try date(day)).instantMillis
  }

  func issuer(_ day: Int, minute: Int) throws -> CommandIssuer {
    let date = Date(timeIntervalSince1970: Double(try millis(day, minute: minute)) / 1000)
    return CommandIssuer(clock: clock, wallClock: { date })
  }

  func write(zoneIdentifier: String, in transaction: inout WriteTransaction) throws {
    var steps = [Step]()
    func add(_ day: Int, _ minute: Int, _ run: @escaping (inout WriteTransaction) throws -> Void) { steps.append(Step(day: day, minute: minute, run: run)) }

    add(day(money.start), 420) { transaction in
      try AccountSettingsRecord(defaultCurrency: currency, enabledCurrencies: [currency, money.trip], moneyScoredFrom: money.start).create(in: &transaction)
      try issuer(day(money.start), minute: 420).issue(.accountSetTimeZone(try TimeZoneChange(identifier: zoneIdentifier)), in: &transaction)
      try BudgetEdits.update(HomeBudget.id, today: money.start, in: &transaction) { $0.limitMinor = DemoMoney.homeLimitMinor }
    }
    add(0, 420) { transaction in
      let opening = try issuer(0, minute: 420)
      for quest in try quests() {
        try opening.issue(.questCreate(QuestCreation(questId: quest.record.id, schedule: quest.schedule)), content: quest.record, in: &transaction)
        try quest.record.create(in: &transaction)
      }
    }
    for log in logs { add(log.day, log.minute) { transaction in try issuer(log.day, minute: log.minute).issue(log.body(try date(log.day)), in: &transaction) } }
    addMoney(add: add)
    for entry in journal {
      add(entry.day, 1260) { transaction in
        let record = JournalEntryRecord(id: UUID.v7(), date: try date(entry.day), text: entry.text, mood: entry.mood, loggedAtMillis: try millis(entry.day, minute: 1260))
        try issuer(entry.day, minute: 1260).issue(.journalSave(QuickLogEntry(id: record.id, date: record.date)), content: record, in: &transaction)
        try record.create(in: &transaction)
      }
    }
    for meal in meals {
      add(meal.day, 780) { transaction in
        let record = MealRecord(
          id: UUID.v7(), date: try date(meal.day), name: meal.name, calories: meal.calories, mealType: .known(meal.type), loggedAtMillis: try millis(meal.day, minute: 780))
        try issuer(meal.day, minute: 780).issue(.mealLog(QuickLogEntry(id: record.id, date: record.date)), content: record, in: &transaction)
        try record.create(in: &transaction)
      }
    }
    let ordered = steps.enumerated().sorted { ($0.element.day, $0.element.minute, $0.offset) < ($1.element.day, $1.element.minute, $1.offset) }
    for entry in ordered { try entry.element.run(&transaction) }
  }

  private func addMoney(add: (Int, Int, @escaping (inout WriteTransaction) throws -> Void) -> Void) {
    for date in money.rateDates {
      add(day(date), 300) { transaction in
        try FxRateRecord(base: money.trip, quote: currency, date: date, rate: money.tripRate).create(in: &transaction)
      }
    }
    for sample in money.expenses {
      add(day(sample.date), sample.minute) { transaction in
        let record = ExpenseRecord(
          id: sample.id, amountMinor: sample.amountMinor, currency: sample.currency, occurredOn: sample.date, category: sample.category, merchant: sample.merchant,
          note: sample.note, loggedAtMillis: try millis(day(sample.date), minute: sample.minute))
        try ExpenseEdits.create(record, issuer: try issuer(day(sample.date), minute: sample.minute), in: &transaction)
      }
      guard sample.refundedMinor > 0, let refundDay = first.adding(days: day(sample.date) + 1) else { continue }
      add(day(refundDay), 600) { transaction in
        try ExpenseEdits.refund(sample.id, amount: .partial(sample.refundedMinor), issuer: try issuer(day(refundDay), minute: 600), in: &transaction)
      }
    }
    for date in money.noSpendDays {
      add(day(date), 1290) { transaction in try issuer(day(date), minute: 1290).issue(.moneyNoSpend(NoSpendDay(date: date)), in: &transaction) }
    }
    add(day(money.tripCreatedOn), 1300) { transaction in
      let draft = BudgetDraft(
        name: "Coast weekend", currency: money.trip, limitMinor: DemoMoney.tripLimitMinor, period: .trip(from: money.tripFrom, through: money.tripThrough))
      try BudgetEdits.create(draft, id: DemoMoney.tripID, today: money.tripCreatedOn, in: &transaction)
    }
    add(day(money.goalCreatedOn), 1200) { transaction in
      let draft = GoalDraft(name: "New bike", symbol: "bicycle", targetMinor: DemoMoney.goalTargetMinor, targetDate: money.goalTargetDate)
      try GoalEdits.create(draft, id: DemoMoney.goalID, today: money.goalCreatedOn, in: &transaction)
    }
    for close in money.closes {
      add(day(close.day), 600) { transaction in
        let issuer = try issuer(day(close.day), minute: 600)
        let body = try BudgetPeriodClose(budgetId: HomeBudget.id, periodStart: close.period, outcome: close.outcome, deposited: close.amountMinor > 0)
        let command = try issuer.issue(.budgetClosePeriod(body), in: &transaction)
        let deposit = SavingsDeposit(
          amountMinor: close.amountMinor, currency: currency, closedOn: close.day, command: command.id, spentMinor: close.spentMinor, limitMinor: DemoMoney.homeLimitMinor,
          medianExpenseMinor: close.medianExpenseMinor)
        try SavingsDepositRecord(budget: HomeBudget.id, periodStart: close.period, deposit: deposit).create(in: &transaction)
        for milestone in close.milestones {
          try issuer.issue(.goalMilestone(GoalMilestoneReached(goalId: DemoMoney.goalID, milestone: milestone)), in: &transaction)
        }
      }
    }
  }

  private func quests() throws -> [(record: QuestRecord, schedule: QuestSchedule)] {
    let daily = try RecurrenceRule(frequency: .daily, startDate: first)
    let weekly = try RecurrenceRule(frequency: .weekly([try date(3).weekday]), startDate: first)
    return [
      (QuestRecord(id: MemoirDemo.lines, name: "Write three lines"), try schedule(.anchor, at: 420, minutes: 10, stat: .mind, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.walk, name: "Morning walk"), try schedule(.routine, at: 450, minutes: 30, stat: .body, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.reading, name: "Read before bed"), try schedule(.routine, at: 1290, minutes: 20, stat: .mind, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.stretch, name: "Stretch"), try schedule(.optional, at: nil, minutes: 10, stat: .body, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.budget, name: "Check the budget"), try schedule(.goal, at: nil, minutes: 20, stat: .wealth, recurrence: weekly)),
    ]
  }

  private func schedule(_ strictness: Strictness, at start: Int?, minutes: Int, stat: StatAffinity, recurrence: RecurrenceRule) throws -> QuestSchedule {
    try QuestSchedule(strictness: strictness, startTimeMinutes: start, durationMinutes: minutes, statAffinity: stat, recurrence: recurrence)
  }

  private struct Log {
    let day: Int
    let minute: Int
    let body: (LocalDate) -> MemoirCommandBody
  }

  private var logs: [Log] {
    func completed(_ quest: UUID, on days: [Int], at minute: Int) -> [Log] {
      days.map { day in Log(day: day, minute: minute) { .questComplete(Occurrence(quest: quest, date: $0)) } }
    }
    let skipped = Log(day: 2, minute: 480) { .questSkip(QuestBreak(occurrence: Occurrence(quest: MemoirDemo.walk, date: $0), reasonTag: .tooTired)) }
    let partial = Log(day: 5, minute: 500) { .questPartial(Occurrence(quest: MemoirDemo.walk, date: $0)) }
    return completed(MemoirDemo.lines, on: [0, 1, 2, 4, 5, 6], at: 425) + completed(MemoirDemo.walk, on: [0, 1, 3, 4, 6], at: 470)
      + completed(MemoirDemo.reading, on: [0, 2, 3, 5, 6], at: 1305) + completed(MemoirDemo.stretch, on: [1, 4], at: 1080)
      + completed(MemoirDemo.budget, on: [3], at: 600) + [skipped, partial]
  }

  private var journal: [(day: Int, text: String, mood: Int)] {
    [
      (4, "Slow start, but the walk along the river cleared my head and I finally finished the chapter I had been putting off.", 4),
      (6, "Work ran long again. Kept the evening quiet, made soup and read for a while before bed.", 3),
    ]
  }

  private var meals: [(day: Int, name: String, calories: Int, type: MealType)] {
    [(5, "Noodle bar lunch", 650, .ateOut), (6, "Lentil soup", 420, .cooked)]
  }
}
