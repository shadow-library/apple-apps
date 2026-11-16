public struct ExactString: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
  public let value: String

  public init(_ value: String) {
    self.value = value
  }

  public init(stringLiteral value: String) {
    self.value = value
  }

  public var description: String { value }

  public static func == (lhs: ExactString, rhs: ExactString) -> Bool {
    lhs.value.utf8.elementsEqual(rhs.value.utf8)
  }

  public static func < (lhs: ExactString, rhs: ExactString) -> Bool {
    lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(Array(value.utf8))
  }
}
