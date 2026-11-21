import Foundation
import ShadowCore

/// What moves the day walk: a command's recorded instant, offset and `issuedOn`, or the app's horizon, with the ruleset the days it closes are judged
/// under.
struct WalkDriver: Sendable {
  let date: LocalDate
  let instantMillis: Int64
  let utcOffsetMinutes: Int
  let ruleset: Ruleset
}

/// `RolloverService.advanceOne`, run to its end before every command: each elapsed day closes under the settings it was lived under, then the staged
/// settings are promoted and the driver's day opens (`rollover.service.ts:155-181,368-447`). Days are read through the offsets commands recorded, never zone
/// data.
extension ReplayState {
  /// The reference's `rollover.catchup-max-days`: the walk never closes a day this far before the day it reached, so an absence of any length costs fixed
  /// work.
  public static let catchUpLimitDays = 90

  mutating func walk(to driver: WalkDriver) {
    guard let open = openDay else { return prepareDay(driver.date, driver: driver) }
    guard let (reached, target) = walkSpan(of: driver, from: open) else { return }
    let first = max(open, reached.adding(days: -Self.catchUpLimitDays) ?? open)
    for offset in 0..<max(0, reached.days(since: first)) {
      guard let day = first.adding(days: offset) else { break }
      closeDay(day, driver: driver)
    }
    settings.promotePending(on: target)
    prepareDay(target, driver: driver)
  }

  /// The day the zone in force has reached at the driver's instant, and the day the walk opens. With a zone change staged, the zone it replaces still
  /// measures the day, from the offset the change was issued under; once promoted, the new zone's date may be later, and the dates between were never
  /// lived, so never closed with every quest missed, or earlier, and the opened day then stays open until the new zone's date passes it (`inNewZone`).
  private func walkSpan(of driver: WalkDriver, from open: LocalDate) -> (reached: LocalDate, target: LocalDate)? {
    guard let pending = settings.pendingTimeZone else { return driver.date > open ? (driver.date, driver.date) : nil }
    guard let reached = Self.localDate(driver.instantMillis, offset: pending.utcOffsetMinutes), reached > open else { return nil }
    return (reached, max(reached, driver.date))
  }

  static func localDate(_ instantMillis: Int64, offset: Int) -> LocalDate? {
    try? MemoirCommand.localDate(instantMillis: instantMillis, utcOffsetMinutes: offset)
  }

  /// Logs in the order the reference's table holds them: by the instant each row was first written, a day's misses in quest creation order.
  func insertionOrdered(_ entries: [(occurrence: Occurrence, value: QuestLogEntry)]) -> [(occurrence: Occurrence, value: QuestLogEntry)] {
    let keyed = entries.map { entry in (entry: entry, order: quests[entry.occurrence.quest]?.createdOrder ?? 0) }
    return keyed.sorted { first, second in
      guard first.entry.value.createdAtMillis == second.entry.value.createdAtMillis else { return first.entry.value.createdAtMillis < second.entry.value.createdAtMillis }
      guard first.order == second.order else { return first.order < second.order }
      return first.entry.occurrence.quest.uuidString < second.entry.occurrence.quest.uuidString
    }.map(\.entry)
  }

  func dayHP(on date: LocalDate, logs dayLogs: [(occurrence: Occurrence, value: QuestLogEntry)], mode: IntensityMode, ruleset: Ruleset) -> DayHP {
    let breaks = dayLogs.filter { $0.value.isBreak }.map { entry in
      HPBreak(
        occurrenceKey: "\(entry.occurrence.quest.lowercasedString):\(date)", strictness: entry.value.strictness, state: entry.value.state,
        shielded: shieldConsumptions.contains(entry.occurrence), streakDaysBefore: 0)
    }
    return ruleset.dayHP(in: mode, previousHPEnd: date.adding(days: -1).flatMap { days[$0]?.hp?.hpEnd }, breaks: breaks)
  }
}
