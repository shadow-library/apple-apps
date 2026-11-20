public struct MomentumInput: Sendable, Hashable {
  /// Completion counts by days before today, most recent first: today, yesterday, the day before.
  public var recentCompletions: [Int]
  /// Daily completion counts for the trailing window, most recent first; only the leading window is read.
  public var trailingCompletions: [Int]

  public init(recentCompletions: [Int], trailingCompletions: [Int]) {
    self.recentCompletions = recentCompletions
    self.trailingCompletions = trailingCompletions
  }
}

public struct Momentum: Sendable, Hashable {
  public let weighted: Tenths
  public let median: Halves
  /// Nil when the trailing median is zero, where no ratio is defined.
  public let ratio: Fraction?
  public let bucket: MomentumBucket
}

extension Ruleset {
  public func momentum(for input: MomentumInput) -> Momentum {
    let weightedTenths = momentum.recentDayWeights.enumerated().reduce(Int128(0)) { total, entry in
      let count = entry.offset < input.recentCompletions.count ? input.recentCompletions[entry.offset] : 0
      return total + Int128(entry.element.tenths) * Int128(max(0, count))
    }
    let weighted = Tenths(Int(clamping: weightedTenths))
    let median = Halves.trailingMedian(of: input.trailingCompletions, windowDays: momentum.medianWindowDays)
    guard let ratio = weighted.fraction / median.fraction else {
      return Momentum(weighted: weighted, median: median, ratio: nil, bucket: weighted.tenths > 0 ? .warm : .cold)
    }
    let bucket: MomentumBucket =
      if ratio < momentum.coldBelowRatio.fraction {
        .cold
      } else if ratio > momentum.warmAboveRatio.fraction {
        .warm
      } else {
        .steady
      }
    return Momentum(weighted: weighted, median: median, ratio: ratio, bucket: bucket)
  }
}
