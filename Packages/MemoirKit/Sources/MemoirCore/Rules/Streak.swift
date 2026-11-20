public enum StreakOutcome: String, Sendable, Hashable {
  case hold
  case bridge
  case `break`
  case neutral
}

public struct StreakState: Sendable, Hashable {
  public static let empty = StreakState(currentDays: 0, longestDays: 0, shields: 0, completionsTowardShield: 0, pendingShieldGrant: 0)

  public var currentDays: Int
  public var longestDays: Int
  public var shields: Int
  public var completionsTowardShield: Int
  /// A Returner shield aimed at a quest already at the cap waits here until a bridge frees a slot.
  public var pendingShieldGrant: Int

  public init(currentDays: Int, longestDays: Int, shields: Int, completionsTowardShield: Int, pendingShieldGrant: Int) {
    self.currentDays = currentDays
    self.longestDays = longestDays
    self.shields = shields
    self.completionsTowardShield = completionsTowardShield
    self.pendingShieldGrant = pendingShieldGrant
  }
}

public struct StreakEvent: Sendable, Hashable {
  public var state: QuestLogState
  public var strictness: Strictness
  public var intensityMode: IntensityMode
  public var streakOptIn: Bool
  public var onTime: Bool

  public init(state: QuestLogState, strictness: Strictness, intensityMode: IntensityMode, streakOptIn: Bool, onTime: Bool) {
    self.state = state
    self.strictness = strictness
    self.intensityMode = intensityMode
    self.streakOptIn = streakOptIn
    self.onTime = onTime
  }
}

public struct StreakTransition: Sendable, Hashable {
  public let outcome: StreakOutcome
  public let state: StreakState
  public let shieldsEarned: Int
  public let shieldsConsumed: Int
  public let endedAtDays: Int
  public let announceBreak: Bool
  public let milestone: StreakTierID?
}

public struct ShieldGrantResult: Sendable, Hashable {
  public let state: StreakState
  public let granted: Int
  public let heldPending: Int
}

extension Ruleset {
  public func streakApplies(to strictness: Strictness, optIn: Bool) -> Bool {
    switch self.strictness[strictness].streakEligibility {
    case .always: true
    case .optIn: optIn
    case .never: false
    }
  }

  public func applyStreakEvent(_ event: StreakEvent, to state: StreakState) -> StreakTransition {
    guard streakApplies(to: event.strictness, optIn: event.streakOptIn) else { return neutral(state) }
    switch event.state {
    case .completed, .partial, .late, .recovery: return hold(state, event)
    case .skipped, .missed, .postponed: return state.shields > 0 ? bridge(state) : breakRun(state)
    case .rescheduled: return neutral(state)
    }
  }

  public func grantStreakShields(_ count: Int, to state: StreakState) -> ShieldGrantResult {
    var settled = state
    settleShields(&settled, shields: state.shields, pending: Exact.adding(state.pendingShieldGrant, max(0, count)))
    return ShieldGrantResult(state: settled, granted: settled.shields - state.shields, heldPending: settled.pendingShieldGrant)
  }

  public func recomputeStreak(_ events: [StreakEvent], from initial: StreakState = .empty) -> StreakState {
    events.reduce(initial) { applyStreakEvent($1, to: $0).state }
  }

  private func settleShields(_ state: inout StreakState, shields: Int, pending: Int) {
    let grantable = min(max(0, pending), max(0, Exact.subtracting(self.shields.capPerQuest, shields)))
    state.shields = shields + grantable
    state.pendingShieldGrant = max(0, pending) - grantable
  }

  private func neutral(_ state: StreakState) -> StreakTransition {
    StreakTransition(outcome: .neutral, state: state, shieldsEarned: 0, shieldsConsumed: 0, endedAtDays: 0, announceBreak: false, milestone: nil)
  }

  private func hold(_ state: StreakState, _ event: StreakEvent) -> StreakTransition {
    let cadence = intensityModes[event.intensityMode].shieldEarnCadence
    let accrues = event.state == .partial || event.onTime
    let progress = Exact.adding(state.completionsTowardShield, accrues ? 1 : 0)
    let reachedCadence = accrues && cadence > 0 && progress >= cadence
    let shieldsEarned = reachedCadence && state.shields < shields.capPerQuest ? 1 : 0
    let currentDays = Exact.adding(state.currentDays, 1)
    let tierBefore = streakTier(forStreakDays: state.currentDays).id
    let tierAfter = streakTier(forStreakDays: currentDays).id

    var next = state
    next.currentDays = currentDays
    next.longestDays = max(state.longestDays, currentDays)
    next.completionsTowardShield = reachedCadence ? 0 : progress
    settleShields(&next, shields: state.shields + shieldsEarned, pending: state.pendingShieldGrant)
    return StreakTransition(
      outcome: .hold, state: next, shieldsEarned: shieldsEarned, shieldsConsumed: 0, endedAtDays: 0, announceBreak: false,
      milestone: tierAfter == tierBefore ? nil : tierAfter)
  }

  private func bridge(_ state: StreakState) -> StreakTransition {
    var next = state
    settleShields(&next, shields: state.shields - 1, pending: state.pendingShieldGrant)
    return StreakTransition(outcome: .bridge, state: next, shieldsEarned: 0, shieldsConsumed: 1, endedAtDays: 0, announceBreak: false, milestone: nil)
  }

  private func breakRun(_ state: StreakState) -> StreakTransition {
    var next = StreakState(currentDays: 0, longestDays: state.longestDays, shields: 0, completionsTowardShield: 0, pendingShieldGrant: 0)
    settleShields(&next, shields: 0, pending: state.pendingShieldGrant)
    return StreakTransition(
      outcome: .break, state: next, shieldsEarned: 0, shieldsConsumed: 0, endedAtDays: state.currentDays,
      announceBreak: state.currentDays >= streaks.breakAnnounceMinDays, milestone: nil)
  }
}
