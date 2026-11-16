import Foundation

public struct SpendLimits: Sendable, Equatable, Codable {
  public var daily: Cost?
  public var monthly: Cost?

  public init(daily: Cost? = nil, monthly: Cost? = nil) {
    self.daily = daily
    self.monthly = monthly
  }
}

public struct SpendSummary: Sendable, Equatable {
  public let today: Cost
  public let month: Cost
  /// Includes calls that were begun but never finished.
  public let pendingCalls: Int

  public init(today: Cost, month: Cost, pendingCalls: Int) {
    self.today = today
    self.month = month
    self.pendingCalls = pendingCalls
  }
}

public enum SpendDecision: Sendable, Equatable {
  case allowed
  case dailyLimitReached(spent: Cost, limit: Cost)
  case monthlyLimitReached(spent: Cost, limit: Cost)
}

public enum Spend {
  public static func summary(of entries: [ModelCallEntry], now: Date, calendar: Calendar) -> SpendSummary {
    var today = Cost.zero
    var month = Cost.zero
    var pending = 0
    for entry in entries {
      let started = Date(timeIntervalSince1970: Double(entry.startedMillis) / 1_000)
      guard calendar.isDate(started, equalTo: now, toGranularity: .month) else { continue }
      guard entry.costSource != .pending else {
        pending += 1
        continue
      }
      let cost = Cost(nanoUSD: max(entry.cost?.nanoUSD ?? 0, 0))
      month = saturatingSum(month, cost)
      if calendar.isDate(started, inSameDayAs: now) { today = saturatingSum(today, cost) }
    }
    return SpendSummary(today: today, month: month, pendingCalls: pending)
  }

  public static func decision(for summary: SpendSummary, limits: SpendLimits) -> SpendDecision {
    if let limit = limits.monthly, summary.month >= limit { return .monthlyLimitReached(spent: summary.month, limit: limit) }
    if let limit = limits.daily, summary.today >= limit { return .dailyLimitReached(spent: summary.today, limit: limit) }
    return .allowed
  }

  private static func saturatingSum(_ lhs: Cost, _ rhs: Cost) -> Cost {
    let (sum, overflow) = lhs.nanoUSD.addingReportingOverflow(rhs.nanoUSD)
    return Cost(nanoUSD: overflow ? Int64.max : sum)
  }
}
