import Foundation

nonisolated public struct ShadowDelta: Hashable, Sendable {
  public enum Direction: Hashable, Sendable {
    case up
    case down
    case flat
  }

  public enum Sentiment: Hashable, Sendable {
    case positive
    case negative
    case neutral
  }

  public let change: Double
  public let higherIsBetter: Bool
  public let fractionDigits: Int

  public init(change: Double, higherIsBetter: Bool = true, fractionDigits: Int = 0) {
    let digits = max(fractionDigits, 0)
    let scale = pow(10, Double(digits))
    let rounded = change.isFinite ? (change * scale).rounded(.toNearestOrAwayFromZero) / scale : 0
    self.change = rounded == 0 ? 0 : rounded
    self.higherIsBetter = higherIsBetter
    self.fractionDigits = digits
  }

  public var direction: Direction {
    if change > 0 { return .up }
    return change < 0 ? .down : .flat
  }

  public var sentiment: Sentiment {
    switch direction {
    case .flat: .neutral
    case .up: higherIsBetter ? .positive : .negative
    case .down: higherIsBetter ? .negative : .positive
    }
  }

  public var systemImage: String {
    switch direction {
    case .up: "arrow.up"
    case .down: "arrow.down"
    case .flat: "equal"
    }
  }

  public func magnitudeText(unit: ShadowDeltaUnit = .none, locale: Locale = .current) -> String {
    unit.appended(to: abs(change).formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale)))
  }

  public func signedText(unit: ShadowDeltaUnit = .none, locale: Locale = .current) -> String {
    unit.appended(to: change.formatted(.number.precision(.fractionLength(fractionDigits)).sign(strategy: .always(includingZero: false)).locale(locale)))
  }
}

nonisolated public enum ShadowDeltaUnit: Hashable, Sendable {
  case none
  case percent
  case suffix(String)

  func appended(to number: String) -> String {
    switch self {
    case .none: number
    case .percent: "\(number)%"
    case .suffix(let suffix): "\(number)\u{00A0}\(suffix)"
    }
  }
}
