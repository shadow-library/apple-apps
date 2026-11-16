public enum ModelTask: String, Sendable, Codable, CaseIterable {
  case writing
  case planning
  case review
  case chat
  case helper
}

public enum Pace: String, Sendable, Codable, CaseIterable, Comparable {
  case swift
  case steady
  case meticulous

  public var deeper: Pace {
    switch self {
    case .swift: .steady
    case .steady, .meticulous: .meticulous
    }
  }

  private var rank: Int {
    switch self {
    case .swift: 0
    case .steady: 1
    case .meticulous: 2
    }
  }

  public static func < (lhs: Pace, rhs: Pace) -> Bool {
    lhs.rank < rhs.rank
  }
}
