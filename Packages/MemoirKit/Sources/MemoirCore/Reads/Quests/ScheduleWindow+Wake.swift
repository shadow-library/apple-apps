extension ScheduleWindow {
  private static let wakeDayMinutes = 1440

  /// Minutes from `minute` (the local minute of today, from `IssueClock`) until the owner's sleep time; an end after midnight keeps today's window open
  /// past the calendar day, and zero or less means it has closed (`lib/data/sleep-window.rules.ts:33-36`).
  public func minutesUntilSleep(from minute: Int) -> Int {
    if end > start { return end - minute }
    return minute < end ? end - minute : end + Self.wakeDayMinutes - minute
  }
}
