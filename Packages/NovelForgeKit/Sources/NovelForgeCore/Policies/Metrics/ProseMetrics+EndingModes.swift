import ShadowText

struct EndingModeEntry: Sendable {
  let chapter: Int
  let hookType: String?
}

struct HookTypeCount: Equatable, Sendable {
  let hookType: String
  let count: Int
}

struct EndingModeDistribution: Equatable, Sendable {
  let counts: [HookTypeCount]
  let distinctCount: Int
  let total: Int
}

extension ProseMetrics {
  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:530
  static func computeEndingModeDistribution(_ entries: [EndingModeEntry]) -> EndingModeDistribution {
    var tallies: [JSString: Int] = [:]
    var insertionOrder: [String] = []
    var total = 0
    for hookType in entries.compactMap(\.hookType) where !hookType.isEmpty {
      total += 1
      if tallies.updateValue(tallies[JSString(hookType), default: 0] + 1, forKey: JSString(hookType)) == nil { insertionOrder.append(hookType) }
    }
    let counts = JSText.ownPropertyKeyOrder(insertionOrder).map { HookTypeCount(hookType: $0, count: tallies[JSString($0), default: 0]) }
    return EndingModeDistribution(counts: counts, distinctCount: counts.count, total: total)
  }
}
