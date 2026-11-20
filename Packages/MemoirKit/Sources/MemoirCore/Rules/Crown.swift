public struct CrownPeriod: Sendable, Hashable {
  public let cadence: CrownCadence
  public let start: LocalDate
  public let closesOn: LocalDate
}

public struct CrownDayState: Sendable, Hashable {
  public let endowedWeight: Halves
  public let forfeitedWeight: Halves
  public let grantedXP: Int
  public let grantedCoins: Int
  public let remainingXP: Int
  public let remainingCoins: Int

  /// Daily remainders accumulate across a weekly period and bank once, on its closing day.
  public static func bankAmount(_ days: [CrownDayState]) -> RewardAmount {
    RewardAmount(xp: Exact.sum(days.map(\.remainingXP)), coins: Exact.sum(days.map(\.remainingCoins)))
  }
}

extension Ruleset {
  public func crownWeight(for strictness: Strictness) -> Halves {
    self.strictness[strictness].crownWeight
  }

  public func crownCadence(for mode: IntensityMode) -> CrownCadence {
    intensityModes[mode].crownCadence
  }

  public func crownShare(weight: Halves) -> RewardAmount {
    let surviving = Int128(max(0, weight.halves))
    let xp = Exact.roundHalfUp(surviving * Int128(crown.xpPerWeight), 2)
    let coins = -Exact.floorDivide(-surviving, 2 * Int128(crown.coinsWeightDivisor))
    return RewardAmount(xp: Int(clamping: xp), coins: min(crown.maxCoins, Int(clamping: coins)))
  }

  public func endowCrown(weights: [Halves]) -> CrownDayState {
    let endowed = Self.sumWeights(weights)
    let granted = crownShare(weight: endowed)
    return withRemainder(endowed: endowed, forfeited: .zero, granted: granted)
  }

  public func forfeitCrownSlice(_ state: CrownDayState, weight: Halves) -> CrownDayState {
    let forfeited = min(state.endowedWeight, Halves(Exact.adding(state.forfeitedWeight.halves, max(0, weight.halves))))
    return withRemainder(endowed: state.endowedWeight, forfeited: forfeited, granted: RewardAmount(xp: state.grantedXP, coins: state.grantedCoins))
  }

  /// A mid-period weight change may shrink the remainder but never lift it above the endowment the period opened with.
  public func rescaleCrown(_ state: CrownDayState, weights: [Halves]) -> CrownDayState {
    let endowed = Self.sumWeights(weights)
    return withRemainder(endowed: endowed, forfeited: min(endowed, state.forfeitedWeight), granted: RewardAmount(xp: state.grantedXP, coins: state.grantedCoins))
  }

  public func recomputeCrownDay(weights: [Halves], forfeited: [Halves]) -> CrownDayState {
    forfeited.reduce(endowCrown(weights: weights)) { forfeitCrownSlice($0, weight: $1) }
  }

  /// Nil only when the period would leave the supported calendar (years 0000 to 9999).
  public func crownPeriod(_ cadence: CrownCadence, containing date: LocalDate) -> CrownPeriod? {
    guard cadence == .weekly else { return CrownPeriod(cadence: cadence, start: date, closesOn: date) }
    let offset = (date.weekday.rawValue - crown.weeklyAnchorWeekday.rawValue + 7) % 7
    guard let start = date.adding(days: -offset), let closesOn = start.adding(days: 6) else { return nil }
    return CrownPeriod(cadence: cadence, start: start, closesOn: closesOn)
  }

  public func isCrownPeriodClose(_ cadence: CrownCadence, on date: LocalDate) -> Bool {
    cadence == .daily || date.weekday.rawValue == (crown.weeklyAnchorWeekday.rawValue + 5) % 7 + 1
  }

  private func withRemainder(endowed: Halves, forfeited: Halves, granted: RewardAmount) -> CrownDayState {
    let remainder = crownShare(weight: Halves(Exact.subtracting(endowed.halves, forfeited.halves)))
    return CrownDayState(
      endowedWeight: endowed, forfeitedWeight: forfeited, grantedXP: granted.xp, grantedCoins: granted.coins, remainingXP: min(granted.xp, remainder.xp),
      remainingCoins: min(granted.coins, remainder.coins))
  }

  private static func sumWeights(_ weights: [Halves]) -> Halves {
    Halves(Exact.sum(weights.map { max(0, $0.halves) }))
  }
}
