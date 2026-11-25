import Foundation
import MemoirCore

/// The hero card's money lines, localized in `Today.xcstrings`.
enum TodayMoneyCopy {
  static func streak(_ weeks: Int, week: MoneyWeekProgress?) -> String {
    let streak = String(localized: "Money streak \(String(localized: "\(weeks) weeks", table: "Today"))", table: "Today")
    guard let week else { return streak }
    return [streak, String(localized: "\(week.covered.count) of \(week.required) days this week", table: "Today")].joined(separator: " · ")
  }

  /// The week before, while its last days can still be logged and it is still short.
  static func settling(_ week: MoneyWeekProgress) -> String {
    String(localized: "Last week \(week.covered.count) of \(week.required) days, still open", table: "Today")
  }

  static func savingStreak(_ closes: Int) -> String {
    String(localized: "Saving streak \(closes)", table: "Today")
  }

  static func debuff(_ debuff: MoneyRow.Debuff, locale: Locale) -> String {
    let penalty = (Double(1000 - debuff.multiplier.thousandths) / 1000).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    return String(localized: "XP −\(penalty) until \(TodayFormat.shortDate(debuff.through))", table: "Today")
  }

  /// Home's pace as the budgets show it.
  static func home(_ status: String) -> String {
    String(localized: "Home: \(status)", table: "Today")
  }
}
