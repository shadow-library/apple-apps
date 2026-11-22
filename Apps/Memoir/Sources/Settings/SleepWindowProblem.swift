import Foundation
import MemoirCore

/// Why a wake and sleep pair is not a day (`sleep-window.rules.ts:12-30`): the sleep from the sleep time round to the wake time lasts 3 to 14 hours, the
/// same check `ScheduleWindow` makes before it will hold the pair.
nonisolated enum SleepWindowProblem: Hashable, Sendable {
  case sameTime
  case tooShort(sleepMinutes: Int)
  case tooLong(sleepMinutes: Int)

  private static let minutesPerDay = 1440

  init?(wake: Int, sleep: Int) {
    let minutes = Self.sleepMinutes(wake: wake, sleep: sleep)
    if minutes == 0 {
      self = .sameTime
    } else if minutes < ScheduleWindow.minimumSleepMinutes {
      self = .tooShort(sleepMinutes: minutes)
    } else if minutes > ScheduleWindow.maximumSleepMinutes {
      self = .tooLong(sleepMinutes: minutes)
    } else {
      return nil
    }
  }

  /// A sleep time earlier on the clock than the wake time is after midnight, so 00:00 to 07:00 is seven hours.
  static func sleepMinutes(wake: Int, sleep: Int) -> Int {
    ((wake - sleep) % minutesPerDay + minutesPerDay) % minutesPerDay
  }

  var message: String {
    switch self {
    case .sameTime:
      String(localized: "Sleep and wake time can’t be the same.", table: "Settings")
    case .tooShort(let minutes):
      String(
        localized: "That leaves \(SettingsCopy.duration(minutes)) of sleep. Allow at least \(SettingsCopy.duration(ScheduleWindow.minimumSleepMinutes)).",
        table: "Settings")
    case .tooLong(let minutes):
      String(
        localized: "That’s \(SettingsCopy.duration(minutes)) of sleep. Allow at most \(SettingsCopy.duration(ScheduleWindow.maximumSleepMinutes)).",
        table: "Settings")
    }
  }
}
