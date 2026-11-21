import Foundation

public enum CosmeticSource: String, RuleKey {
  case coin
  case achievement
}

public struct OwnedCosmetic: Sendable, Hashable {
  public let source: CosmeticSource
  public internal(set) var equipped: Bool
}

/// Achievements, titles and cosmetics with the counters their catalogues read. `counters` holds the lifetime counts the reference's
/// `progress_counters` row stores; XP, level and stats come from the hero ledger and the 90-day reschedule window from the reschedule log when evaluated.
public struct ProgressionState: Sendable, Hashable {
  public static let empty = ProgressionState()

  public internal(set) var counters = ProgressCounters.empty
  public internal(set) var lastActiveCountedDate: LocalDate?
  /// Set when a Returner ritual fires and cleared by the next quest completion, which the `returner` title counts.
  public internal(set) var returnerPending = false
  public internal(set) var achievements: [AchievementID: LocalDate] = [:]
  public internal(set) var titles: [TitleID: LocalDate] = [:]
  public internal(set) var cosmetics: [CosmeticID: OwnedCosmetic] = [:]
  public internal(set) var displayedTitle: TitleID?
}
