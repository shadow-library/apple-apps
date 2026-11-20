public struct ReturnerCandidate: Sendable, Hashable {
  public var questID: String
  /// The streak the quest carried when the absence began, never recomputed from the absence itself.
  public var preAbsenceStreakDays: Int
  /// Monotonic creation ordinal; the most recently created quest wins a streak-length tie.
  public var createdOrder: Int
  public var shields: Int

  public init(questID: String, preAbsenceStreakDays: Int, createdOrder: Int, shields: Int) {
    self.questID = questID
    self.preAbsenceStreakDays = preAbsenceStreakDays
    self.createdOrder = createdOrder
    self.shields = shields
  }
}

public struct ReturnerShieldGrant: Sendable, Hashable {
  public enum Placement: Sendable, Hashable {
    case granted(questID: String)
    case heldPending(questID: String)
    /// With no pre-absence quest to aim at, the gift waits for the next quest the owner creates.
    case heldTargetless
  }

  public let shields: Int
  public let placement: Placement

  public var questID: String? {
    switch placement {
    case .granted(let questID), .heldPending(let questID): questID
    case .heldTargetless: nil
    }
  }
}

extension Ruleset {
  public func returnerThreshold(_ thresholdDays: Int?) -> Int {
    thresholdDays ?? returner.defaultThresholdDays
  }

  public func returnerFires(daysSinceLastActivity: Int, thresholdDays: Int?) -> Bool {
    daysSinceLastActivity >= returnerThreshold(thresholdDays)
  }

  public static func returnerShieldTarget(_ candidates: [ReturnerCandidate]) -> ReturnerCandidate? {
    candidates.reduce(nil) { best, candidate in
      guard let best else { return candidate }
      let outranks =
        candidate.preAbsenceStreakDays > best.preAbsenceStreakDays
        || (candidate.preAbsenceStreakDays == best.preAbsenceStreakDays && candidate.createdOrder > best.createdOrder)
      return outranks ? candidate : best
    }
  }

  public func planReturnerShieldGrant(_ candidates: [ReturnerCandidate]) -> ReturnerShieldGrant {
    let shields = returner.shieldGrant
    guard let target = Self.returnerShieldTarget(candidates) else { return ReturnerShieldGrant(shields: shields, placement: .heldTargetless) }
    let placement: ReturnerShieldGrant.Placement =
      target.shields >= self.shields.capPerQuest ? .heldPending(questID: target.questID) : .granted(questID: target.questID)
    return ReturnerShieldGrant(shields: shields, placement: placement)
  }
}
