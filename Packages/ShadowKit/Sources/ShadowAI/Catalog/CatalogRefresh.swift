import Foundation

public enum CatalogRefresh {
  public static let interval: TimeInterval = 7 * 86_400

  public static func isDue(lastRefresh: Date?, now: Date, keyJustValidated: Bool) -> Bool {
    guard !keyJustValidated, let lastRefresh else { return true }
    let elapsed = now.timeIntervalSince(lastRefresh)
    return elapsed < 0 || elapsed >= interval
  }
}
