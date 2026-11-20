public struct RecentMiss: Sendable, Hashable {
  /// Whole local days before today; yesterday is 1. Today's misses are not knowable when the day arms.
  public var daysAgo: Int
  public var strictness: Strictness

  public init(daysAgo: Int, strictness: Strictness) {
    self.daysAgo = daysAgo
    self.strictness = strictness
  }
}

public struct ComebackArmingInput: Sendable, Hashable {
  public var intensityMode: IntensityMode
  public var momentum: MomentumBucket
  public var returnerFired: Bool
  public var recentMisses: [RecentMiss]

  public init(intensityMode: IntensityMode, momentum: MomentumBucket, returnerFired: Bool, recentMisses: [RecentMiss]) {
    self.intensityMode = intensityMode
    self.momentum = momentum
    self.returnerFired = returnerFired
    self.recentMisses = recentMisses
  }
}

public enum ComebackArming: Sendable, Hashable {
  case armed(by: ComebackTrigger)
  case disarmed
  case suppressedByReturner

  public var isArmed: Bool {
    guard case .armed = self else { return false }
    return true
  }

  public var trigger: ComebackTrigger? {
    guard case .armed(let trigger) = self else { return nil }
    return trigger
  }
}

public struct ComebackDayState: Sendable, Hashable {
  public static let empty = ComebackDayState(armed: false, fires: 0, armedViaRecovery: false)

  public var armed: Bool
  public var fires: Int
  /// A Recovery quest completion re-arms the day and lifts the fire allowance.
  public var armedViaRecovery: Bool

  public init(armed: Bool, fires: Int, armedViaRecovery: Bool) {
    self.armed = armed
    self.fires = fires
    self.armedViaRecovery = armedViaRecovery
  }

  public func armedViaRecoveryQuest() -> ComebackDayState {
    ComebackDayState(armed: true, fires: fires, armedViaRecovery: true)
  }
}

public enum ComebackFireKind: String, Sendable, Hashable {
  case fired
  case reFired = "re_fired"
}

public struct ComebackFire: Sendable, Hashable {
  public let kind: ComebackFireKind?
  public let state: ComebackDayState

  public var fired: Bool { kind != nil }
}

extension Ruleset {
  public func comebackArming(for input: ComebackArmingInput) -> ComebackArming {
    if input.returnerFired && returner.suppressesComeback { return .suppressedByReturner }
    guard let trigger = intensityModes[input.intensityMode].comebackTriggers.first(where: { Self.isSatisfied($0, by: input) }) else { return .disarmed }
    return .armed(by: trigger)
  }

  public func comebackFireAllowance(_ state: ComebackDayState) -> Int {
    state.armedViaRecovery ? comeback.maxFiresPerDayViaRecovery : comeback.maxFiresPerDay
  }

  public func canFireComeback(_ state: ComebackDayState, on strictness: Strictness) -> Bool {
    state.armed && self.strictness[strictness].consumesOneShot && state.fires < comebackFireAllowance(state)
  }

  public func fireComeback(_ state: ComebackDayState, on strictness: Strictness) -> ComebackFire {
    guard canFireComeback(state, on: strictness) else { return ComebackFire(kind: nil, state: state) }
    let fires = state.fires + 1
    let next = ComebackDayState(armed: fires < comebackFireAllowance(state), fires: fires, armedViaRecovery: state.armedViaRecovery)
    return ComebackFire(kind: fires > 1 ? .reFired : .fired, state: next)
  }

  public func comebackBonus(claimed: RewardInput) -> RewardAmount {
    var withBonus = claimed
    withBonus.oneShot = .comeback
    var without = claimed
    without.oneShot = .none
    let bonus = reward(for: withBonus)
    let plain = reward(for: without)
    return RewardAmount(xp: bonus.xp - plain.xp, coins: bonus.coins - plain.coins)
  }

  /// Negative for every reachable pairing: the bonus never repays the XP the arming miss gave up.
  public func comebackNetXP(forgone: RewardInput, claimed: RewardInput) -> Int {
    var forgoneWithout = forgone
    forgoneWithout.oneShot = .none
    return comebackBonus(claimed: claimed).xp - reward(for: forgoneWithout).xp
  }

  private static func isSatisfied(_ trigger: ComebackTrigger, by input: ComebackArmingInput) -> Bool {
    switch trigger {
    case .anchorMissYesterday:
      return input.recentMisses.contains { $0.daysAgo == 1 && $0.strictness == .anchor }
    case .missWithinDays(let days, let strictness, let requiresColdMomentum):
      if requiresColdMomentum && input.momentum != .cold { return false }
      return input.recentMisses.contains { $0.daysAgo >= 1 && $0.daysAgo <= days && strictness.contains($0.strictness) }
    }
  }
}
