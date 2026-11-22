import ShadowStore

/// memoir-web `LoggableModule` (`lib/data/entry-caps.ts:1`).
public enum LoggableModule: String, Sendable, CaseIterable {
  case expenses
  case journal
  case meals
  case weight
  case sideQuests = "sidequests"

  /// Weights are health class and are counted in the restricted store.
  public var syncClass: SyncClass { self == .weight ? .health : .general }
}

public enum EntryCapLevel: String, Sendable, CaseIterable {
  case clear
  case approaching
  case reached
}

/// memoir-web `deriveCapAdvisory` (`lib/data/entry-caps.ts:16-33`): advisory only, so nothing here can block a save. Native Memoir has no plan tiers,
/// so whether to show it is the app's choice; the web shows it only on the free plan (`capAdvisoryForTier`, `:45-47`).
public struct EntryCapAdvisory: Sendable, Hashable {
  public static let monthlyLimit = 100
  /// The share of the limit, in percent, from which the advisory reads `approaching`.
  public static let advisoryPercent = 80

  public let module: LoggableModule
  public let used: Int
  public let limit: Int
  public let level: EntryCapLevel

  public init(module: LoggableModule, used: Int, limit: Int = monthlyLimit) {
    self.module = module
    self.used = used
    self.limit = limit
    if limit <= 0 {
      level = .clear
    } else if used >= limit {
      level = .reached
    } else {
      level = Int128(used) * 100 >= Int128(limit) * Int128(Self.advisoryPercent) ? .approaching : .clear
    }
  }

  /// `used / limit`, exactly; `nil` for a limit of zero or less, which the web reads as zero.
  public var ratio: Fraction? { limit > 0 ? Fraction(numerator: used, denominator: limit) : nil }
}

/// Each module's advisory for the calendar month holding `today`, counting the entries dated in it, as memoir-web's `monthlyCounts` does
/// (`lib/sync/synced-quick-log-provider.ts:95-112`, `synced-finance-provider.ts:36-42`).
public struct EntryCapsOverview: Sendable, Hashable {
  public let month: DateSpan
  /// The classes whose stores were counted: general always, health when weights were.
  public let classes: Set<SyncClass>
  public let advisories: [EntryCapAdvisory]

  public func advisory(_ module: LoggableModule) -> EntryCapAdvisory? {
    advisories.first { $0.module == module }
  }
}
