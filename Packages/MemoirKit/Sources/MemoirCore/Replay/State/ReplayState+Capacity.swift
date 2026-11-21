import Foundation

/// The advisory capacity a plan lock reports; it never refuses the lock.
public struct LockCapacity: Sendable, Hashable {
  public let capacity: Capacity
  public let warning: CapacityWarning
}

extension ReplayState {
  /// Daily hold-state counts before `day`, most recent first, a day without one counting zero; only days since the account began count, and an
  /// account with nothing before is a new owner at the baseline cap.
  public func trailingCompletions(before day: LocalDate, windowDays: Int) -> [Int] {
    guard let began = activityBegan else { return [] }
    let window = (1...max(1, windowDays)).compactMap { day.adding(days: -$0) }.filter { $0 >= began }
    return window.map { logs.count(on: $0) { $0.isHold } }
  }

  public func lockCapacity(on day: LocalDate, plannedLoad: Int, ruleset: Ruleset) -> LockCapacity {
    let input = CapacityInput(
      trailingCompletions: trailingCompletions(before: day, windowDays: ruleset.capacity.medianWindowDays), momentum: days[day]?.momentum ?? .steady,
      priorDayHeavyMiss: false)
    let capacity = ruleset.capacity(for: input)
    let warning = ruleset.capacityWarning(
      for: CapacityWarningInput(plannedLoad: plannedLoad, capacity: capacity.capacity, onLockAttempt: true, daysSinceLastSoftWarning: nil))
    return LockCapacity(capacity: capacity, warning: warning)
  }

  /// The earlier of the first logged occurrence and the day the first quest was created.
  private var activityBegan: LocalDate? {
    [logs.earliestDate, earliestQuestDay].compactMap(\.self).min()
  }
}
