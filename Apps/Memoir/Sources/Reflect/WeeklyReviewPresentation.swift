import Foundation
import MemoirCore

struct ReviewFact: Identifiable, Equatable {
  let label: String
  let value: String
  let comparison: String

  var id: String { label }
}

/// `deriveReview`'s copy (`reflect.derive.ts:743-931`) over the core's review.
enum WeeklyReviewPresentation {
  static func title(_ step: ReviewStep) -> String {
    switch step {
    case .kept: String(localized: "Kept", table: "Reflect")
    case .money: String(localized: "Money", table: "Reflect")
    case .body: String(localized: "Body", table: "Reflect")
    case .reflect: String(localized: "Reflect", table: "Reflect")
    case .done: String(localized: "Done", table: "Reflect")
    }
  }

  static func weekLabel(_ review: WeeklyReview) -> String {
    String(localized: "Week \(review.isoWeek.week) · \(ReflectFormat.range(review.week))", table: "Reflect")
  }

  static func keptHeadline(_ kept: ReviewKept) -> String {
    guard kept.occurrences > 0 else {
      return String(localized: "Nothing was logged last week. The week stays empty rather than guessing at it.", table: "Reflect")
    }
    let partials = String(localized: "\(kept.partials) partials", table: "Reflect")
    let misses = String(localized: "\(kept.missesWithReason) misses with a reason", table: "Reflect")
    return String(localized: "\(kept.held) of \(kept.occurrences) occurrences. \(partials), \(misses).", table: "Reflect")
  }

  static func result(_ row: ReviewQuestRow) -> String {
    String(localized: "\(row.held) of \(row.occurrences)", table: "Reflect")
  }

  static func outcome(_ outcome: ReviewDayOutcome) -> String {
    switch outcome {
    case .kept: String(localized: "Kept", table: "Reflect")
    case .partial: String(localized: "Partial", table: "Reflect")
    case .missed: String(localized: "Missed", table: "Reflect")
    case .none: String(localized: "Not scheduled", table: "Reflect")
    }
  }

  static func keptPattern(_ kept: ReviewKept) -> String {
    guard let top = kept.topReason else {
      return String(localized: "No pattern to name this week — nothing was missed with a reason attached.", table: "Reflect")
    }
    return String(localized: "The pattern worth naming: \(ReflectCopy.reason(top.reason)) accounts for \(top.count) of the misses this week.", table: "Reflect")
  }

  static func moneyHeadline(_ money: ReviewMoney?) -> String {
    guard let money else { return String(localized: "No home currency yet, so the week’s spending can’t be totalled. Choose one in Settings.", table: "Reflect") }
    guard money.expenseCount > 0 else { return String(localized: "Nothing was logged as spent this week.", table: "Reflect") }
    let home = money.spent.home
    let spent = ReflectFormat.money(money.spent.totalMinor, home)
    let expenses = String(localized: "\(money.expenseCount) expenses", table: "Reflect")
    guard money.weeklyAverageMinor != 0 else { return String(localized: "\(spent) across \(expenses).", table: "Reflect") }
    let difference = ReflectFormat.money(Int64(clamping: abs(Int128(money.spent.totalMinor) - Int128(money.weeklyAverageMinor))), home)
    return money.spent.totalMinor <= money.weeklyAverageMinor
      ? String(localized: "\(spent) across \(expenses), \(difference) below your weekly average.", table: "Reflect")
      : String(localized: "\(spent) across \(expenses), \(difference) above your weekly average.", table: "Reflect")
  }

  static func moneyFacts(_ money: ReviewMoney?, lookups: ReflectLookups?) -> [ReviewFact] {
    guard let money else { return [] }
    let home = money.spent.home
    var facts = [
      ReviewFact(
        label: String(localized: "Spent", table: "Reflect"), value: ReflectFormat.money(money.spent.totalMinor, home),
        comparison: String(localized: "over the week", table: "Reflect")),
      ReviewFact(
        label: String(localized: "No-spend days", table: "Reflect"), value: ReflectFormat.count(money.noSpendDays),
        comparison: String(localized: "\(money.spendDays) days with an expense", table: "Reflect")),
    ]
    if let biggest = money.biggestCategory {
      let label = lookups?.category(biggest.category) ?? ReflectCopy.builtInCategory(biggest.category) ?? biggest.category.key
      let expenses = String(localized: "\(biggest.count) expenses", table: "Reflect")
      facts.append(
        ReviewFact(
          label: String(localized: "Biggest category", table: "Reflect"), value: ReflectFormat.money(biggest.totalMinor, home),
          comparison: String(localized: "\(label) · \(expenses)", table: "Reflect")))
    }
    return facts
  }

  static func moneyNote(_ money: ReviewMoney?, lookups: ReflectLookups?) -> String? {
    guard let money else { return nil }
    guard !money.renewed.isEmpty else { return String(localized: "No subscription renewed inside this week.", table: "Reflect") }
    let names = money.renewed.map { lookups?.subscriptionNames[$0] ?? String(localized: "A subscription", table: "Reflect") }
    return String(localized: "\(money.renewed.count) subscriptions renewed this week: \(names.formatted(.list(type: .and))).", table: "Reflect")
  }

  /// `bodyFacts` (`reflect.derive.ts:840-889`).
  static func bodyHeadline(_ body: ReviewBody) -> String {
    guard !body.series.isEmpty else { return String(localized: "Too few body entries this week to read anything from.", table: "Reflect") }
    let names = body.series.map { lowered(ReflectCopy.subjectName($0.subject)) }.formatted(.list(type: .and))
    return String(localized: "\(sentence(names)) had enough entries to be worth reading.", table: "Reflect")
  }

  static func bodyFacts(_ body: ReviewBody) -> [ReviewFact] {
    body.series.map { series in
      switch series.subject {
      case .weight:
        ReviewFact(
          label: String(localized: "Weight", table: "Reflect"), value: series.points.last?.value.map(ReflectCopy.kilograms) ?? "—",
          comparison: String(localized: "\(ReflectCopy.movement(series.change)) over the week", table: "Reflect"))
      case .metric(let metric):
        ReviewFact(
          label: String(localized: "Average \(lowered(ReflectCopy.metricName(metric)))", table: "Reflect"),
          value: series.mean.map { ReflectCopy.metricValue($0, of: metric) } ?? "—",
          comparison: String(localized: "\(series.points.count { $0.value != nil }) days logged", table: "Reflect"))
      }
    }
  }

  static func bodyGap(_ body: ReviewBody) -> (title: String, message: String)? {
    guard let thinnest = body.thin.first else { return nil }
    return (
      String(localized: "Not enough \(lowered(ReflectCopy.subjectName(thinnest))) entries to say anything", table: "Reflect"),
      String(localized: "Rather than guess a weekly average from one or two numbers, this section stays empty — it will fill in on its own.", table: "Reflect")
    )
  }

  static func question(_ prompt: ReviewPrompt) -> String {
    switch prompt {
    case .better: String(localized: "What went better than you expected?", table: "Reflect")
    case .change: String(localized: "What will you change about next week?", table: "Reflect")
    case .carry: String(localized: "Anything you want to stop carrying?", table: "Reflect")
    }
  }

  static func placeholder(_ prompt: ReviewPrompt) -> String {
    switch prompt {
    case .better, .change: String(localized: "One sentence is enough", table: "Reflect")
    case .carry: String(localized: "Optional", table: "Reflect")
    }
  }

  static func completionTitle(_ review: WeeklyReview) -> String {
    String(localized: "Week \(review.isoWeek.week) closed", table: "Reflect")
  }

  static func summary(_ review: WeeklyReview, modules: ModuleSelection = .all) -> [String] {
    let kept = review.kept
    var lines = [String]()
    if modules.contains(.quests) {
      lines.append(
        kept.occurrences == 0
          ? String(localized: "No occurrences were logged this week", table: "Reflect")
          : String(localized: "\(kept.held) of \(kept.occurrences) kept · \(ReflectFormat.percent(kept.percent ?? 0))", table: "Reflect"))
    }
    if let money = review.money, modules.contains(.money) { lines.append(spentLine(money)) }
    if modules.contains(.body) {
      if let weight = review.body.series.first(where: { $0.subject == .weight }) {
        let movement = ReflectCopy.movement(weight.change)
        lines.append(
          weight.change.map(ReflectFormat.isZero) ?? true
            ? String(localized: "Weight \(movement)", table: "Reflect") : String(localized: "Weight \(movement) kg", table: "Reflect"))
      } else {
        lines.append(String(localized: "Not enough weight entries to read a trend", table: "Reflect"))
      }
    }
    if modules.contains(.quests) {
      lines.append(
        kept.topReason.map { String(localized: "Most common reason for a miss: \(ReflectCopy.reason($0.reason)) (\($0.count))", table: "Reflect") }
          ?? String(localized: "No reasons were given for a miss this week", table: "Reflect"))
    }
    if modules.contains(.hero) { lines.append(String(localized: "\(ReflectFormat.count(review.glance.weekXP)) XP earned", table: "Reflect")) }
    return lines
  }

  static func glance(_ review: WeeklyReview, modules: ModuleSelection = .all) -> [String] {
    let kept = review.kept
    let glance = review.glance
    var lines = [String]()
    if modules.contains(.quests) {
      lines.append(
        kept.occurrences == 0
          ? String(localized: "No occurrences logged", table: "Reflect")
          : String(localized: "\(kept.occurrences) occurrences · \(kept.held) kept · \(ReflectFormat.percent(kept.percent ?? 0))", table: "Reflect"))
    }
    if modules.contains(.hero) {
      lines.append(String(localized: "Level \(glance.level ?? 1) · \(ReflectFormat.count(glance.weekXP)) XP earned", table: "Reflect"))
      lines.append(glance.hp.map { String(localized: "HP \($0.hpEnd) of \($0.hpMax)", table: "Reflect") } ?? String(localized: "No HP yet", table: "Reflect"))
    }
    if let money = review.money, modules.contains(.money) { lines.append(spentLine(money)) }
    let journal = String(localized: "\(glance.journalEntries) journal entries", table: "Reflect")
    let meals = String(localized: "\(glance.meals) meals logged", table: "Reflect")
    switch (modules.contains(.journal), modules.contains(.meals)) {
    case (true, true): lines.append(String(localized: "\(journal) · \(meals)", table: "Reflect"))
    case (true, false): lines.append(journal)
    case (false, true): lines.append(meals)
    case (false, false): break
    }
    return lines
  }

  private static func spentLine(_ money: ReviewMoney) -> String {
    let expenses = String(localized: "\(money.expenseCount) expenses", table: "Reflect")
    return String(localized: "\(ReflectFormat.money(money.spent.totalMinor, money.spent.home)) spent across \(expenses)", table: "Reflect")
  }

  private static func lowered(_ text: String) -> String {
    text.lowercased()
  }

  private static func sentence(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }
}
