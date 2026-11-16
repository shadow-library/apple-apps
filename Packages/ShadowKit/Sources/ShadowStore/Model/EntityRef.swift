public struct EntityRef: Hashable, Comparable, Sendable, Codable {
  public let kind: EntityKind
  public let key: EntityKey

  public init(kind: EntityKind, key: EntityKey) {
    self.kind = kind
    self.key = key
  }

  public static func < (lhs: EntityRef, rhs: EntityRef) -> Bool {
    guard lhs.kind == rhs.kind else { return lhs.kind < rhs.kind }
    return lhs.key < rhs.key
  }
}
