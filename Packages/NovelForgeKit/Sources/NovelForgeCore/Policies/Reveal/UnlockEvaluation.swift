import ShadowText

struct UnlockContext: Equatable, Sendable {
  var chapter: Int
  var endingChapter: Int?
  var volumeKey: String?
  var volumeOrdinals: [JSString: Int]
  var reachedMilestones: Set<JSString>
}

struct UnlockEvaluation: Equatable, Sendable {
  let holds: Bool
  let missing: [UnlockTerm]
}

private func termHolds(_ term: UnlockTerm, _ context: UnlockContext) -> Bool {
  switch term {
  case .milestone(let key):
    return context.reachedMilestones.contains(JSString(key))
  case .chapter(let number):
    return context.chapter >= number
  case .ending:
    guard let endingChapter = context.endingChapter else { return false }
    return context.chapter >= endingChapter
  case .volume(let key):
    guard let planKey = context.volumeKey, let planOrdinal = context.volumeOrdinals[JSString(planKey)], let termOrdinal = context.volumeOrdinals[JSString(key)] else {
      return false
    }
    return planOrdinal >= termOrdinal
  }
}

// platform/apps/novel-forge-server/src/common/unlock-condition.ts:62
func evaluateUnlock(_ condition: UnlockCondition, _ context: UnlockContext) -> UnlockEvaluation {
  let missing = condition.all.filter { !termHolds($0, context) }
  return UnlockEvaluation(holds: missing.isEmpty, missing: missing)
}

// platform/apps/novel-forge-server/src/common/unlock-condition.ts:67
func describeUnlockTerm(_ term: UnlockTerm) -> String {
  switch term {
  case .milestone(let key): "milestone \(key) reached"
  case .volume(let key): "volume \(key) reached"
  case .chapter(let number): "chapter \(Double(number).jsString) or later"
  case .ending: "the planned ending or later"
  }
}
