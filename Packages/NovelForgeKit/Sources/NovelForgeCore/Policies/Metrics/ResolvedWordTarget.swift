struct WordTargetSource: Sendable {
  var wordTargetMin: Double?
  var wordTargetMax: Double?
}

struct ResolvedWordTarget: Equatable, Sendable {
  static let defaultMin = 1800.0
  static let defaultMax = 2600.0
  static let defaultAim = 2200.0

  let min: Double
  let max: Double
  let aim: Double

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:55
  static func resolve(_ project: WordTargetSource? = nil) -> ResolvedWordTarget {
    let min = project?.wordTargetMin ?? defaultMin
    let max = project?.wordTargetMax ?? defaultMax
    return ResolvedWordTarget(min: min, max: max, aim: JSMath.round((min + max) / 2))
  }

  static func resolve(_ wordTarget: WordTarget?) -> ResolvedWordTarget {
    resolve(wordTarget.map { WordTargetSource(wordTargetMin: Double($0.min), wordTargetMax: Double($0.max)) })
  }

  func contains(_ words: Int) -> Bool {
    Double(words) >= min && Double(words) <= max
  }
}
