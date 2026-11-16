import Foundation
import ShadowCore

public struct FieldState: Sendable, Equatable {
  public let value: JSONValue
  public let clock: HLCTimestamp
  public let rule: FieldRule

  public static func == (lhs: FieldState, rhs: FieldState) -> Bool {
    lhs.clock == rhs.clock && lhs.rule.canonicalBytes == rhs.rule.canonicalBytes && CanonicalJSON.encode(lhs.value) == CanonicalJSON.encode(rhs.value)
  }

  public func joined(with other: FieldState) -> FieldState {
    let ruleBytes = rule.canonicalBytes
    let otherRuleBytes = other.rule.canonicalBytes
    guard ruleBytes == otherRuleBytes else {
      if rule.isExtended(by: other.rule) { return restamped(with: other.rule).joined(with: other) }
      if other.rule.isExtended(by: rule) { return joined(with: other.restamped(with: rule)) }
      return ruleBytes.lexicographicallyPrecedes(otherRuleBytes) ? other : self
    }
    switch rule {
    case .register: return precedes(other) ? other : self
    case .firstWriterWins: return precedes(other) ? self : other
    case .monotone:
      let rank = rule.rank(of: value) ?? -1
      let otherRank = rule.rank(of: other.value) ?? -1
      guard rank == otherRank else { return rank < otherRank ? other : self }
      return precedes(other) ? other : self
    }
  }

  func restamped(with newer: FieldRule) -> FieldState {
    guard rule.isExtended(by: newer) else { return self }
    return FieldState(value: value, clock: clock, rule: newer)
  }

  private func precedes(_ other: FieldState) -> Bool {
    guard clock == other.clock else { return clock < other.clock }
    return CanonicalJSON.encode(value).lexicographicallyPrecedes(CanonicalJSON.encode(other.value))
  }
}
