public enum CapacityWarning: String, Sendable, Hashable {
  case none
  case soft
  case modal
}

public struct CapacityInput: Sendable, Hashable {
  /// Daily completion counts, most recent first; empty means a new owner, who starts at the baseline cap.
  public var trailingCompletions: [Int]
  public var momentum: MomentumBucket
  public var priorDayHeavyMiss: Bool

  public init(trailingCompletions: [Int], momentum: MomentumBucket, priorDayHeavyMiss: Bool) {
    self.trailingCompletions = trailingCompletions
    self.momentum = momentum
    self.priorDayHeavyMiss = priorDayHeavyMiss
  }
}

public struct Capacity: Sendable, Hashable {
  public let baseline: Fraction
  public let capacity: Int
}

public struct CapacityWarningInput: Sendable, Hashable {
  public var plannedLoad: Int
  public var capacity: Int
  /// The modal only ever appears on a lock attempt; the soft advisory is ambient.
  public var onLockAttempt: Bool
  /// Nil when no soft warning has been shown yet.
  public var daysSinceLastSoftWarning: Int?

  public init(plannedLoad: Int, capacity: Int, onLockAttempt: Bool, daysSinceLastSoftWarning: Int?) {
    self.plannedLoad = plannedLoad
    self.capacity = capacity
    self.onLockAttempt = onLockAttempt
    self.daysSinceLastSoftWarning = daysSinceLastSoftWarning
  }
}

extension Ruleset {
  public func capacity(for input: CapacityInput) -> Capacity {
    let baseline =
      input.trailingCompletions.isEmpty
      ? Fraction(capacity.newUserBaselineCap)
      : Halves.trailingMedian(of: input.trailingCompletions, windowDays: capacity.medianWindowDays).fraction * capacity.ratchetFactor.fraction
    let cold = input.momentum == .cold ? capacity.coldMomentumFactor.fraction : Fraction(1)
    let heavyMiss = input.priorDayHeavyMiss ? capacity.heavyMissDayFactor.fraction : Fraction(1)
    return Capacity(baseline: baseline, capacity: max(1, (baseline * cold * heavyMiss).roundedHalfUp))
  }

  public func capacityWarning(for input: CapacityWarningInput) -> CapacityWarning {
    if input.onLockAttempt && Self.load(input, exceeds: capacity.modalWarningRatio) { return .modal }
    let throttled = input.daysSinceLastSoftWarning.map { $0 < capacity.softWarningThrottleDays } ?? false
    return Self.load(input, exceeds: capacity.softWarningRatio) && !throttled ? .soft : .none
  }

  /// Warns while creating an anchor beyond the soft cap, never blocking it.
  public func anchorSoftCapWarned(existingAnchorCount: Int) -> Bool {
    existingAnchorCount >= capacity.anchorWarnAboveCount
  }

  private static func load(_ input: CapacityWarningInput, exceeds ratio: Thousandths) -> Bool {
    guard input.capacity > 0 else { return true }
    return Int128(input.plannedLoad) * 1000 > Int128(ratio.thousandths) * Int128(input.capacity)
  }
}
