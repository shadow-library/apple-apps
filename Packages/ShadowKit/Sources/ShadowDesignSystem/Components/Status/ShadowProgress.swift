import Foundation

nonisolated public enum ShadowProgress {
  public static func fraction(value: Double, total: Double = 1) -> Double {
    guard value.isFinite, total.isFinite, total > 0 else { return 0 }
    return min(max(value / total, 0), 1)
  }

  public static func isComplete(_ fraction: Double?) -> Bool {
    guard let fraction else { return false }
    return fraction >= 1
  }
}
