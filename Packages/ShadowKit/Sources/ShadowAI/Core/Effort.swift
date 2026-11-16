public enum Effort: String, Sendable, Codable, CaseIterable, Comparable {
  case low
  case medium
  case high
  case xhigh
  case max

  public var raised: Effort {
    let levels = Effort.allCases
    guard let index = levels.firstIndex(of: self), index + 1 < levels.count else { return self }
    return levels[index + 1]
  }

  private var rank: Int {
    switch self {
    case .low: 0
    case .medium: 1
    case .high: 2
    case .xhigh: 3
    case .max: 4
    }
  }

  public static func < (lhs: Effort, rhs: Effort) -> Bool {
    lhs.rank < rhs.rank
  }
}
