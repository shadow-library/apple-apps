import Foundation
import MemoirCore

/// The budgets' words, localized in `Money.xcstrings`. Home's record has no name, so the app names it.
enum BudgetCopy {
  static var home: String { String(localized: "Home", table: "Money") }

  static func name(of budget: LiveBudget) -> String {
    name(id: budget.id, stored: budget.record.name)
  }

  static func name(id: UUID, stored: String?) -> String {
    guard id != HomeBudget.id else { return home }
    return stored ?? String(localized: "Unnamed budget", table: "Money")
  }

  static func kind(_ period: BudgetPeriodKind, locale: Locale) -> String {
    switch period {
    case .monthly: String(localized: "Monthly", table: "Money")
    case .trip(let from, let through): String(localized: "Trip, \(dates(from, through, locale: locale))", table: "Money")
    }
  }

  static func dates(_ from: LocalDate, _ through: LocalDate, locale: Locale) -> String {
    let showsYear = from.year != through.year
    return "\(MoneyDates.text(from, locale: locale, showsYear: showsYear)) – \(MoneyDates.text(through, locale: locale))"
  }

  /// Why an expense or a subscription's next charge counts in its budget, as the assignment rule decided.
  static func reason(_ assignment: BudgetAssignment, currency: CurrencyCode, homeCurrency: CurrencyCode?) -> String {
    switch assignment.reason {
    case .expenseOverride: String(localized: "You chose this budget.", table: "Money")
    case .subscriptionOverride: String(localized: "Its subscription counts every charge here.", table: "Money")
    case .trip: String(localized: "The trip covers this date.", table: "Money")
    case .currency: String(localized: "It’s the monthly budget for \(currency.code).", table: "Money")
    case .home where homeCurrency.map({ $0 != currency }) ?? false:
      String(localized: "No trip or monthly \(currency.code) budget covers it, so it counts in Home, converted.", table: "Money")
    case .home: String(localized: "No trip covers this date, so it counts in Home.", table: "Money")
    }
  }

  static func phase(_ standing: BudgetPeriodStanding, locale: Locale) -> String {
    switch standing.phase {
    case .upcoming(let days): String(localized: "Starts in \(days) days", table: "Money")
    case .current(_, let days) where standing.budget.record.period == .monthly: MoneyNotes.daysLeft(days)
    case .current(_, let days): String(localized: "\(days) days left of the trip", table: "Money")
    case .ended: String(localized: "Ended \(MoneyDates.text(standing.period.end, locale: locale))", table: "Money")
    }
  }

  nonisolated static func financeError(_ error: any Error) -> FinanceError? {
    switch error {
    case let error as FinanceError: error
    case MemoirWriteError.command(.finance(let error)), MemoirWriteError.command(.refused(.finance(let error))): error
    case CommandIssueError.finance(let error), CommandIssueError.refused(.finance(let error)): error
    default: nil
    }
  }
}

/// How a standing's pace reads: a word, its intent, and a symbol that says it without colour.
enum BudgetTone: Equatable, Sendable {
  case neutral
  case success
  case warning
  case danger

  var symbol: String? {
    switch self {
    case .neutral: nil
    case .success: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .danger: "exclamationmark.octagon.fill"
    }
  }
}

/// One budget's row: what it spent against its limit in its own currency, its pace, and what else the owner should know about it.
struct BudgetRowContent: Equatable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let amount: String
  let status: String
  let tone: BudgetTone
  let details: [String]
  /// The share of the limit spent, capped at the whole; nil without a limit.
  let progress: Double?

  init(_ standing: BudgetPeriodStanding, locale: Locale) {
    let currency = standing.budget.currency
    let money = { (minor: Int64) in MoneyText.formatted(minor, currency, locale: locale) }
    let spent = money(standing.spend.spentMinor)
    id = standing.id
    title = BudgetCopy.name(of: standing.budget)
    kind = [BudgetCopy.kind(standing.budget.record.period, locale: locale), currency.code].joined(separator: " · ")
    if let limit = standing.limitMinor {
      amount = String(localized: "\(spent) of \(money(limit))", table: "Money")
      progress = limit > 0 ? min(1, Double(standing.spend.spentMinor) / Double(limit)) : (standing.spend.spentMinor > 0 ? 1 : 0)
    } else {
      amount = String(localized: "\(spent) spent", table: "Money")
      progress = nil
    }
    switch standing.pace {
    case .noLimit:
      status = String(localized: "No limit set", table: "Money")
      tone = .neutral
    case .onTrack:
      status = String(localized: "On track", table: "Money")
      tone = .success
    case .atRisk(.mostlySpent):
      status = String(localized: "At risk: mostly spent", table: "Money")
      tone = .warning
    case .atRisk(.projectedOver):
      status = String(localized: "At risk: on pace to go over", table: "Money")
      tone = .warning
    case .over(let by):
      status = String(localized: "Over by \(money(by))", table: "Money")
      tone = .danger
    }
    var details = [BudgetCopy.phase(standing, locale: locale)]
    if case .atRisk(.projectedOver) = standing.pace, let projected = standing.projectedMinor {
      details.append(String(localized: "On pace for \(money(projected))", table: "Money"))
    }
    if let safe = standing.safePerDayMinor {
      switch standing.phase {
      case .upcoming: details.append(String(localized: "\(money(safe)) a day once it starts", table: "Money"))
      case .current, .ended: details.append(String(localized: "\(money(safe)) a day to stay within", table: "Money"))
      }
    }
    if let pending = standing.pendingLimit {
      details.append(String(localized: "Limit \(money(pending.amountMinor)) from \(MoneyDates.text(pending.from, locale: locale))", table: "Money"))
    }
    details += MoneyNotes.leftOut(standing.spend.pending)
    self.details = details
  }

  var accessibilityLabel: String {
    ([title, kind, amount, status] + details).joined(separator: ", ")
  }
}

/// Every budget whose period holds today, added up in the home currency.
struct ConsolidatedContent: Equatable, Sendable {
  let title: String
  let amount: String
  let left: String?
  let tone: BudgetTone
  let notes: [String]

  init(_ consolidated: ConsolidatedStanding, locale: Locale) {
    let money = { (minor: Int64) in MoneyText.formatted(minor, consolidated.home, locale: locale) }
    let approximately = { (text: String) in consolidated.isApproximate ? String(localized: "≈ \(text)", table: "Money") : text }
    let spent = money(consolidated.spend.spentMinor)
    title = String(localized: "All budgets in \(consolidated.home.code)", table: "Money")
    if let limit = consolidated.limitMinor {
      amount = approximately(String(localized: "\(spent) of \(money(limit))", table: "Money"))
    } else {
      amount = approximately(String(localized: "\(spent) spent", table: "Money"))
    }
    switch consolidated.leftMinor {
    case nil:
      left = nil
      tone = .neutral
    case let left? where left < 0:
      self.left = approximately(String(localized: "\(money(left == .min ? .max : -left)) over", table: "Money"))
      tone = .danger
    case let left?:
      self.left = approximately(String(localized: "\(money(left)) left", table: "Money"))
      tone = .neutral
    }
    var notes = [String]()
    if consolidated.isApproximate {
      notes.append(
        String(localized: "Approximate: spending converts at each expense’s rate and limits at the latest rate, so the two can drift apart.", table: "Money"))
    }
    if consolidated.limitsPending.count > 0 {
      notes.append(String(localized: "\(consolidated.limitsPending.count) limits wait for an exchange rate and are left out.", table: "Money"))
    }
    if consolidated.budgetsWithoutLimit > 0 {
      notes.append(String(localized: "\(consolidated.budgetsWithoutLimit) budgets have no limit, so only their spending is counted.", table: "Money"))
    }
    if let pending = MoneyNotes.pending(consolidated.spend.pending) { notes.append(pending) }
    self.notes = notes
  }
}

/// The Money screen's budget figure: how many budgets under way are on track, and how many are at risk or over.
struct BudgetSummary: Equatable, Sendable {
  let value: String
  let caption: String

  init(_ standings: BudgetStandings) {
    let measured = standings.budgets.filter { standing in
      guard case .current = standing.phase else { return false }
      return standing.pace != .noLimit
    }
    guard !measured.isEmpty else {
      value = String(localized: "No limits set", table: "Money")
      caption = String(localized: "Give Home a limit in Budgets.", table: "Money")
      return
    }
    let onTrack = measured.count { $0.pace == .onTrack }
    let atRisk = measured.count { if case .atRisk = $0.pace { true } else { false } }
    let over = measured.count { if case .over = $0.pace { true } else { false } }
    value = String(localized: "\(onTrack) of \(measured.count) on track", table: "Money")
    var parts = [String]()
    if atRisk > 0 { parts.append(String(localized: "\(atRisk) at risk", table: "Money")) }
    if over > 0 { parts.append(String(localized: "\(over) over", table: "Money")) }
    caption = parts.isEmpty ? String(localized: "None at risk", table: "Money") : parts.joined(separator: " · ")
  }
}

extension BudgetStandings {
  /// Adding up is offered only when more than one budget's period holds today.
  var offersConsolidated: Bool { consolidated.budgets.count > 1 }

  /// What the Money screen's rail lists: every budget but a trip that ended before this month.
  var shownOnRail: [BudgetPeriodStanding] {
    let monthStart = DateSpan.month(of: today)?.start ?? today
    return budgets.filter { standing in
      guard case .ended = standing.phase else { return true }
      return standing.period.end >= monthStart
    }
  }
}
