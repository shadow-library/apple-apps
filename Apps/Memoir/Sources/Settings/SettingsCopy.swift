import Foundation
import MemoirCore

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
    let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != short else { return short }
    return String(localized: "\(short) (\(build))", table: "Settings")
  }
}
