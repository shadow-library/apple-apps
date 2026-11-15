import Foundation

nonisolated public enum ShadowRatingFill: Hashable, Sendable, CaseIterable {
  case empty
  case half
  case full

  public var systemImage: String {
    switch self {
    case .empty: "star"
    case .half: "star.leadinghalf.filled"
    case .full: "star.fill"
    }
  }
}

nonisolated public struct ShadowRatingScale: Hashable, Sendable {
  static let previewOpacity = 0.5

  public let maximum: Int

  public init(maximum: Int = 5) {
    self.maximum = max(maximum, 1)
  }

  public func clamped(_ value: Int) -> Int {
    min(max(value, 0), maximum)
  }

  public func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return value == .infinity ? Double(maximum) : 0 }
    return min(max(value, 0), Double(maximum))
  }

  public func displayValue(_ value: Double) -> Double {
    (clamped(value) * 2).rounded(.toNearestOrAwayFromZero) / 2
  }

  public func fill(at index: Int, for value: Double) -> ShadowRatingFill {
    let remainder = displayValue(value) - Double(index)
    if remainder >= 1 { return .full }
    return remainder >= 0.5 ? .half : .empty
  }

  func isPreviewed(at index: Int, committed: Double, shown: Double) -> Bool {
    let position = Double(index) + 1
    return position > displayValue(committed) && position <= displayValue(shown)
  }

  public func value(atOffset offset: CGFloat, width: CGFloat) -> Int {
    guard width > 0, offset >= 0 else { return 0 }
    let slot = width / CGFloat(maximum)
    return clamped(Int(offset / slot) + 1)
  }

  public func stepped(_ value: Int, by delta: Int) -> Int {
    clamped(value + delta)
  }
}
