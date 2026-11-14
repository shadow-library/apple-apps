import Foundation

nonisolated public struct ShadowBadgeCount: Hashable, Sendable {
  public static let defaultMaximum = 99

  public let value: Int
  public let maximum: Int

  public init(_ value: Int, maximum: Int = Self.defaultMaximum) {
    self.value = value
    self.maximum = max(maximum, 1)
  }

  public var isVisible: Bool { value > 0 }
  public var isCapped: Bool { value > maximum }
  public var shownValue: Int { min(max(value, 0), maximum) }

  public func text(locale: Locale = .current) -> String {
    let shown = shownValue.formatted(.number.locale(locale))
    return isCapped ? "\(shown)+" : shown
  }
}
