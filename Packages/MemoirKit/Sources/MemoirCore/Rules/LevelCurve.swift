public struct LevelCurve: Sendable, Hashable, Encodable {
  public let maxLevel: Int
  public let xpToAdvance: [Int]
  private let thresholds: [Int]

  init(maxLevel: Int, xpToAdvance: [Int]) {
    self.maxLevel = maxLevel
    self.xpToAdvance = xpToAdvance
    var thresholds = [0]
    for cost in xpToAdvance { thresholds.append(Exact.adding(thresholds[thresholds.count - 1], cost)) }
    self.thresholds = thresholds
  }

  private enum CodingKeys: String, CodingKey {
    case maxLevel
    case xpToAdvance
  }

  public func xpToAdvance(fromLevel level: Int) -> Int {
    guard level >= 1, level < maxLevel, level <= xpToAdvance.count else { return 0 }
    return xpToAdvance[level - 1]
  }

  public func xpThreshold(forLevel level: Int) -> Int {
    thresholds[clamped(level) - 1]
  }

  public func level(forTotalXP totalXP: Int) -> Int {
    let xp = max(0, totalXP)
    var low = 1
    var high = maxLevel
    while low < high {
      let middle = low + (high - low + 1) / 2
      if xpThreshold(forLevel: middle) <= xp {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return low
  }

  private func clamped(_ level: Int) -> Int {
    min(max(level, 1), thresholds.count)
  }
}
