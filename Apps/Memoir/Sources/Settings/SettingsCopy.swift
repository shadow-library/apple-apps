import Foundation
import MemoirCore
import ShadowAppShell

/// The reference's words for Settings (`features/settings/settings-screen.tsx`), with times and lengths in the locale's formats.
nonisolated enum SettingsCopy {
  static func duration(_ minutes: Int) -> String {
    Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
  }

  /// `timeZoneOptions` (`lib/format/date-time.ts:67-74`) shows a zone by its identifier with spaces for underscores.
  static func zone(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "_", with: " ")
  }

  /// "UTC+05:30" at the instant, or nil for a zone this device does not know.
  static func offset(of identifier: String, at date: Date) -> String? {
    guard let zone = TimeZone(identifier: identifier) else { return nil }
    return offset(minutes: zone.secondsFromGMT(for: date) / 60)
  }

  static func offset(minutes: Int) -> String {
    let magnitude = abs(minutes)
    return String(format: "UTC%@%02d:%02d", minutes < 0 ? "-" : "+", magnitude / 60, magnitude % 60)
  }

  /// `pendingHelp` (`settings-screen.tsx:89-91`).
  static func pending(_ pending: String, active: String) -> String {
    String(localized: "\(pending) from your next rollover — \(active) stays active today.", table: "Settings")
  }

  static func weekStart(_ start: WeekStart, calendar: Calendar = .current) -> String {
    switch start {
    case .monday: calendar.weekdaySymbols[1]
    case .sunday: calendar.weekdaySymbols[0]
    }
  }

  static func version(bundle: Bundle = .main) -> String {
    AppVersion(bundle: bundle).text
  }

  /// The order Features lists the modules in.
  static let moduleOrder: [MemoirModule] = [.quests, .hero, .money, .journal, .meals, .body]

  static func module(_ module: MemoirModule) -> String {
    switch module {
    case .hero: String(localized: "Hero", table: "Settings")
    case .quests: String(localized: "Quests", table: "Settings")
    case .money: String(localized: "Money", table: "Settings")
    case .journal: String(localized: "Journal", table: "Settings")
    case .meals: String(localized: "Meals", table: "Settings")
    case .body: String(localized: "Body", table: "Settings")
    }
  }

  static func moduleDescription(_ module: MemoirModule) -> String {
    switch module {
    case .hero: String(localized: "Experience, levels, coins and titles for what you keep up. Needs Quests or Money.", table: "Settings")
    case .quests:
      String(localized: "Today, daily promises, your plan for the week, recovery and the weekly review. Turning it on turns Hero on too.", table: "Settings")
    case .money: String(localized: "Budgets, expenses, subscriptions, receipts and savings.", table: "Settings")
    case .journal: String(localized: "Entries in your own words.", table: "Settings")
    case .meals: String(localized: "What you ate, in a line.", table: "Settings")
    case .body: String(localized: "Weight, measurements, activity and Apple Health.", table: "Settings")
    }
  }

  static func refusal(_ refusal: ModuleSelectionError) -> String {
    switch refusal {
    case .empty: String(localized: "Keep at least one feature on.", table: "Settings")
    case .questsNeedHero: String(localized: "Quests need Hero. Turn Quests off first.", table: "Settings")
    case .heroNeedsQuestsOrMoney: String(localized: "Hero needs Quests or Money to be on.", table: "Settings")
    }
  }
}
