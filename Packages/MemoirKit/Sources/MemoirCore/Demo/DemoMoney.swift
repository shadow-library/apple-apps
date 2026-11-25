import Foundation
import ShadowCore

struct DemoExpense: Sendable {
  let key: String
  let date: LocalDate
  let minute: Int
  let amountMinor: Int64
  let currency: CurrencyCode
  let category: CategoryKey
  let merchant: String?
  let note: String?
  let refundedMinor: Int64

  init(
    key: String, date: LocalDate, minute: Int, amountMinor: Int64, currency: CurrencyCode, category: CategoryKey, merchant: String? = nil, note: String? = nil,
    refundedMinor: Int64 = 0
  ) {
    self.key = key
    self.date = date
    self.minute = minute
    self.amountMinor = amountMinor
    self.currency = currency
    self.category = category
    self.merchant = merchant
    self.note = note
    self.refundedMinor = refundedMinor
  }

  var id: UUID { derivedID(DemoMoney.expenseDomain, key) }
  var netMinor: Int64 { amountMinor - refundedMinor }
}

struct DemoClose: Sendable {
  let period: LocalDate
  let day: LocalDate
  let outcome: BudgetCloseOutcome
  let amountMinor: Int64
  let spentMinor: Int64
  let medianExpenseMinor: Int64?
  let milestones: [GoalMilestone]
}

struct DemoMoney: Sendable {
  static let expenseDomain = "com.shadow.library.memoircore.demo-expense"
  static let budgetDomain = "com.shadow.library.memoircore.demo-budget"
  static let goalDomain = "com.shadow.library.memoircore.demo-goal"
  static let homeLimitMinor: Int64 = 150_000
  static let monthlySpendMinor: [Int64] = [121_000, 113_500, 116_000, 109_000, 112_000]
  static let openMonthMinor: Int64 = 115_000
  static let goalTargetMinor: Int64 = 100_000
  static let tripLimitMinor: Int64 = 15_000
  static let goalMonthsAhead = 6
  static let tripID = derivedID(budgetDomain, "trip")
  static let goalID = derivedID(goalDomain, "bike")

  private static let skipCycleDays = 9
  private static let skipCycleRemainder = 4
  private static let gapStartOffset = 9
  private static let gapDays = 3

  private struct Slot {
    let dayOfMonth: Int
    let minute: Int
    let category: String
    let merchant: String?
    let permille: Int64
  }

  private static let slots = [
    Slot(dayOfMonth: 2, minute: 1100, category: "groceries", merchant: "Market Hall", permille: 190),
    Slot(dayOfMonth: 5, minute: 1250, category: "food", merchant: "Corner Café", permille: 70),
    Slot(dayOfMonth: 8, minute: 530, category: "transport", merchant: "Transit pass", permille: 110),
    Slot(dayOfMonth: 11, minute: 1140, category: "shopping", merchant: "Bookshop on the Square", permille: 130),
    Slot(dayOfMonth: 14, minute: 1100, category: "groceries", merchant: "Market Hall", permille: 170),
    Slot(dayOfMonth: 18, minute: 1000, category: "bills", merchant: "Phone and internet", permille: 100),
    Slot(dayOfMonth: 22, minute: 1230, category: "food", merchant: "Noodle Bar", permille: 80),
    Slot(dayOfMonth: 26, minute: 1110, category: "groceries", merchant: "Market Hall", permille: 150),
  ]

  /// What one unit of a currency is worth, in ten-thousandths of a US dollar: the demo's own rough table, so the sample trip converts at a believable rate.
  private static let reference: [String: Int64] = [
    "USD": 10_000, "EUR": 10_800, "GBP": 12_700, "CHF": 11_200, "JPY": 65, "CAD": 7_300, "AUD": 6_500, "NZD": 6_000, "SEK": 950, "NOK": 940, "DKK": 1_450,
    "PLN": 2_500, "CZK": 430, "INR": 120, "BRL": 1_800, "MXN": 560, "SGD": 7_400, "CNY": 1_400,
  ]

  let home: CurrencyCode
  let trip: CurrencyCode
  let tripRate: DecimalText
  let start: LocalDate
  let tripFrom: LocalDate
  let tripThrough: LocalDate
  let tripCreatedOn: LocalDate
  let goalCreatedOn: LocalDate
  let goalTargetDate: LocalDate
  let months: [LocalDate]
  let expenses: [DemoExpense]
  let noSpendDays: [LocalDate]
  let closes: [DemoClose]

  var rateDates: [LocalDate] { Set(expenses.filter { $0.currency == trip }.map(\.date)).sorted() }

  init(first: LocalDate, home: CurrencyCode) throws(CalendarError) {
    guard let lastLogged = first.adding(days: MemoirDemo.days - 1), let trip = Self.tripCurrency(for: home), let rate = Self.rate(from: trip, to: home) else {
      throw .dateOutOfRange
    }
    let months = try Self.closedMonths(lastLogged: lastLogged)
    guard let start = months.first, let tripFrom = first.adding(days: 4), let tripThrough = first.adding(days: 8), let tripCreatedOn = first.adding(days: 3) else {
      throw .dateOutOfRange
    }
    let week = try Self.week(first: first, home: home, trip: trip)
    let history = try Self.history(months: months, first: first, home: home, week: week.filter { $0.currency == home })
    let expenses = history + week
    let closes = try Self.closes(months: months, expenses: expenses.filter { $0.currency == home }, home: home)
    guard let deposited = closes.dropFirst(2).first, let goalCreatedOn = deposited.day.adding(days: 1), let target = Self.targetDate(first: first) else {
      throw .dateOutOfRange
    }
    self.home = home
    self.trip = trip
    self.tripRate = rate
    self.start = start
    self.tripFrom = tripFrom
    self.tripThrough = tripThrough
    self.tripCreatedOn = tripCreatedOn
    self.goalCreatedOn = goalCreatedOn
    self.goalTargetDate = target
    self.months = months
    self.expenses = expenses
    self.noSpendDays = Self.noSpendDays(from: start, through: lastLogged, first: first, months: months, expenses: expenses)
    self.closes = try Self.milestones(on: closes, from: goalCreatedOn)
  }

  private static func tripCurrency(for home: CurrencyCode) -> CurrencyCode? {
    ["GBP", "USD", "EUR"].lazy.filter { $0 != home.code }.compactMap(CurrencyCode.init).first
  }

  private static func rate(from trip: CurrencyCode, to home: CurrencyCode) -> DecimalText? {
    let tripValue = Int128(reference[trip.code] ?? 10_000)
    let homeValue = Int128(reference[home.code] ?? 10_000)
    let scaled = Exact.roundHalfUp(tripValue * 1_000_000, homeValue)
    let whole = scaled / 1_000_000
    var fraction = String(scaled % 1_000_000)
    fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
    while fraction.hasSuffix("0") { fraction.removeLast() }
    return DecimalText(fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)")
  }

  private static func monthEnd(_ month: LocalDate) throws(CalendarError) -> LocalDate {
    guard let span = DateSpan.month(of: month) else { throw .dateOutOfRange }
    return span.end
  }

  private static func closeDay(of month: LocalDate) throws(CalendarError) -> LocalDate {
    guard let day = try monthEnd(month).adding(days: BudgetThresholds.closeGraceDays) else { throw .dateOutOfRange }
    return day
  }

  private static func monthStart(of date: LocalDate) throws(CalendarError) -> LocalDate {
    guard let start = LocalDate(year: date.year, month: date.month, day: 1) else { throw .dateOutOfRange }
    return start
  }

  private static func closedMonths(lastLogged: LocalDate) throws(CalendarError) -> [LocalDate] {
    var latest = try monthStart(of: lastLogged)
    while try closeDay(of: latest) > lastLogged {
      guard let previous = latest.adding(months: -1) else { throw .dateOutOfRange }
      latest = previous
    }
    let count = monthlySpendMinor.count
    return try (0..<count).map { index throws(CalendarError) in
      guard let month = latest.adding(months: index - (count - 1)) else { throw .dateOutOfRange }
      return month
    }
  }

  private static func targetDate(first: LocalDate) -> LocalDate? {
    guard let month = try? monthStart(of: first), let target = month.adding(months: goalMonthsAhead) else { return nil }
    return target.adding(days: 14)
  }

  private static func category(_ key: String) throws(CalendarError) -> CategoryKey {
    guard let category = CategoryKey(key) else { throw .dateOutOfRange }
    return category
  }

  private static func week(first: LocalDate, home: CurrencyCode, trip: CurrencyCode) throws(CalendarError) -> [DemoExpense] {
    let samples: [(day: Int, minute: Int, minor: Int64, currency: CurrencyCode, category: String, merchant: String?, note: String?, refunded: Int64)] = [
      (1, 1110, 4_235, home, "groceries", "Market Hall", nil, 650), (2, 750, 1_250, home, "food", "Corner Café", nil, 0),
      (3, 520, 2_800, home, "transport", nil, "Train tickets", 0), (4, 650, 640, trip, "food", "Harbour Café", nil, 0),
      (4, 1140, 1_850, trip, "shopping", "Old Town Bookshop", nil, 0), (5, 1230, 1_490, trip, "food", "Fish Bar", nil, 0),
      (5, 1000, 920, trip, "transport", "Bus day pass", nil, 0), (6, 1100, 2_130, trip, "groceries", "Corner Grocer", nil, 0),
    ]
    return try samples.map { sample throws(CalendarError) in
      guard let date = first.adding(days: sample.day) else { throw .dateOutOfRange }
      return DemoExpense(
        key: "week-\(sample.day)-\(sample.minute)", date: date, minute: sample.minute, amountMinor: sample.minor, currency: sample.currency,
        category: try category(sample.category), merchant: sample.merchant, note: sample.note, refundedMinor: sample.refunded)
    }
  }

  private static func history(months: [LocalDate], first: LocalDate, home: CurrencyCode, week: [DemoExpense]) throws(CalendarError) -> [DemoExpense] {
    var expenses = [DemoExpense]()
    var month = try monthStart(of: months[0])
    let last = try monthStart(of: first)
    while month <= last {
      let target = months.firstIndex(of: month).map { monthlySpendMinor[$0] }
      var placed = [(slot: Slot, date: LocalDate)]()
      for slot in slots {
        guard let date = month.adding(days: slot.dayOfMonth - 1) else { throw .dateOutOfRange }
        if date < first { placed.append((slot, date)) }
      }
      let weights = placed.reduce(Int64(0)) { $0 + $1.slot.permille }
      let fixed = week.filter { $0.date.year == month.year && $0.date.month == month.month }.reduce(Int64(0)) { $0 + $1.netMinor }
      var remaining = target.map { $0 - fixed }
      for (index, entry) in placed.enumerated() {
        let amount: Int64
        if let left = remaining, let share = target.map({ ($0 - fixed) * entry.slot.permille }) {
          amount = index == placed.count - 1 ? left : Int64(Exact.roundHalfUp(Int128(share), Int128(weights)))
          remaining = left - amount
        } else {
          amount = Int64(Exact.roundHalfUp(Int128(openMonthMinor * entry.slot.permille), 1000))
        }
        expenses.append(
          DemoExpense(
            key: "history-\(entry.date.isoString)", date: entry.date, minute: entry.slot.minute, amountMinor: amount, currency: home,
            category: try category(entry.slot.category), merchant: entry.slot.merchant))
      }
      guard let next = month.adding(months: 1) else { throw .dateOutOfRange }
      month = next
    }
    return expenses
  }

  private static func closes(months: [LocalDate], expenses: [DemoExpense], home: CurrencyCode) throws(CalendarError) -> [DemoClose] {
    var closes = [DemoClose]()
    var spends = [Int64]()
    for month in months {
      let end = try monthEnd(month)
      let counted = expenses.filter { $0.date >= month && $0.date <= end }
      let spent = counted.reduce(Int64(0)) { $0 + $1.netMinor }
      let median = BudgetHistory.median(counted.map(\.netMinor).filter { $0 > 0 })
      let prior = Array(spends.suffix(BudgetThresholds.typicalMonths))
      var outcome = BudgetCloseOutcome.within
      var amount: Int64 = 0
      if prior.count >= BudgetThresholds.calibrationMonths, let typical = BudgetHistory.median(prior) {
        let reference = min(homeLimitMinor, Int64(Exact.roundHalfUp(Int128(typical) * Int128(SavingsRules.referenceThousandths), 1000)))
        amount = max(0, reference - spent)
        if spent <= typical { outcome = .withinTypical }
      }
      closes.append(
        DemoClose(period: month, day: try closeDay(of: month), outcome: outcome, amountMinor: amount, spentMinor: spent, medianExpenseMinor: median, milestones: []))
      spends.append(spent)
    }
    return closes
  }

  private static func milestones(on closes: [DemoClose], from goalCreatedOn: LocalDate) throws(CalendarError) -> [DemoClose] {
    let thresholds: [(thousandths: Int64, milestone: GoalMilestone)] = [(250, .p25), (500, .p50), (750, .p75), (1000, .p100)]
    var pool: Int64 = 0
    var reached = 0
    return closes.map { close in
      pool += close.amountMinor
      guard close.day >= goalCreatedOn else { return close }
      let progress = min(1000, Int64(Exact.floorDivide(Int128(pool) * 1000, Int128(goalTargetMinor))))
      let crossed = thresholds.dropFirst(reached).prefix { $0.thousandths <= progress }.map(\.milestone)
      reached += crossed.count
      return DemoClose(
        period: close.period, day: close.day, outcome: close.outcome, amountMinor: close.amountMinor, spentMinor: close.spentMinor,
        medianExpenseMinor: close.medianExpenseMinor, milestones: crossed)
    }
  }

  private static func noSpendDays(from start: LocalDate, through last: LocalDate, first: LocalDate, months: [LocalDate], expenses: [DemoExpense]) -> [LocalDate] {
    let logged = Set(expenses.map(\.date))
    let gapStart = months[months.count - 2].adding(days: gapStartOffset)
    return (0...last.days(since: start)).compactMap { offset -> LocalDate? in
      guard let date = start.adding(days: offset), !logged.contains(date) else { return nil }
      guard date < first else { return date }
      let inGap = gapStart.map { date >= $0 && date.days(since: $0) < gapDays } ?? false
      return inGap || offset % skipCycleDays == skipCycleRemainder ? nil : date
    }
  }
}
