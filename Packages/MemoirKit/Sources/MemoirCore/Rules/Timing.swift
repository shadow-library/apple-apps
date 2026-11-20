public struct TimingBandInput: Sendable, Hashable {
  public var strictness: Strictness
  public var startMinute: Int?
  public var durationMinutes: Int
  /// Negative when the completion resolved before the occurrence's own day began.
  public var daysElapsed: Int
  public var minuteOfDay: Int

  public init(strictness: Strictness, startMinute: Int?, durationMinutes: Int, daysElapsed: Int, minuteOfDay: Int) {
    self.strictness = strictness
    self.startMinute = startMinute
    self.durationMinutes = durationMinutes
    self.daysElapsed = daysElapsed
    self.minuteOfDay = minuteOfDay
  }
}

extension Ruleset {
  public func timingBand(for input: TimingBandInput) -> TimingBand {
    if input.daysElapsed < 0 { return .onTime }
    if input.daysElapsed > 0 { return Self.dayBand(daysElapsed: input.daysElapsed) }
    guard let windowEnd = onTimeWindowEnd(input), Int128(input.minuteOfDay) >= windowEnd else { return .onTime }
    return Int128(input.minuteOfDay) - windowEnd < Int128(reward.timing.lateStepMinutes) ? .late0To2h : .late2hPlus
  }

  private func onTimeWindowEnd(_ input: TimingBandInput) -> Int128? {
    guard let startMinute = input.startMinute else { return nil }
    return switch strictness[input.strictness].schedulingModel {
    case .strictTime: Int128(startMinute) + Int128(reward.timing.anchorGraceMinutes)
    case .timeWindow: Int128(startMinute) + Int128(input.durationMinutes)
    case .dayLevel: nil
    }
  }

  private static func dayBand(daysElapsed: Int) -> TimingBand {
    switch daysElapsed {
    case 1: .day1
    case 2: .day2
    case 3: .day3
    default: .day4
    }
  }
}
