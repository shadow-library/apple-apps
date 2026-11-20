import Foundation
import ShadowAI
import ShadowStore
import ShadowText

private let day: TimeInterval = 24 * 60 * 60

private let periodLabels: [UsagePeriod: String] = [.today: "the last 24 hours", .week: "the last 7 days", .month: "the last 30 days", .all: "all time"]

private struct RoleUsage {
  var calls = 0
  var nanoUSD: Int64 = 0
}

private func windowStart(_ period: UsagePeriod, now: Date) -> Date? {
  switch period {
  case .today: now.addingTimeInterval(-day)
  case .week: now.addingTimeInterval(-7 * day)
  case .month: now.addingTimeInterval(-30 * day)
  case .all: nil
  }
}

// tools/get-usage.tool.ts:32
private func formatUSD(nanoUSD: Int64) -> String {
  let amount = Double(nanoUSD) / Double(Cost.nanoUSDPerUSD)
  return "$\(amount > 0 && amount < 0.01 ? amount.jsToFixed(4) : amount.jsToFixed(2))"
}

// tools/get-usage.tool.ts:40: toLocaleString('en-US')
private func formatTokens(_ count: Int) -> String {
  let digits = String(count)
  var grouped = ""
  for (offset, digit) in digits.enumerated() {
    if offset > 0, (digits.count - offset) % 3 == 0 { grouped += "," }
    grouped.append(digit)
  }
  return grouped
}

private func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
  let (sum, overflow) = left.addingReportingOverflow(right)
  return overflow ? Int64.max : sum
}

extension ChatLookupReader {
  // tools/get-usage.tool.ts:82; the on-device ledger records neither a chapter, a run nor how long a call took, so those scopes and the duration are answered or left out plainly
  func usage(chapter: Double?, period: UsagePeriod?, lastRun: Bool?) throws(ChatLookupFailure) -> String {
    if lastRun == true { return "The on-device ledger does not group calls into runs, so there is no last run to report." }
    if let chapter { return "The on-device ledger records no chapter, so usage cannot be scoped to chapter \(chapter.jsString)." }
    let period = period ?? .all
    let start = windowStart(period, now: now)
    let entries = try query { () throws(StoreError) in try Ledger.entries(in: transaction) }.filter { entry in
      start.map { Double(entry.startedMillis) / 1_000 >= $0.timeIntervalSince1970 } ?? true
    }
    let scope = periodLabels[period] ?? ""
    guard !entries.isEmpty else { return "No usage recorded for \(scope)." }

    var input = 0
    var output = 0
    var total: Int64 = 0
    var estimated: Int64 = 0
    var unpriced = 0
    var roles: [String: RoleUsage] = [:]
    var roleOrder: [String] = []
    for entry in entries {
      let nano = max(entry.cost?.nanoUSD ?? 0, 0)
      input += entry.usage.input
      output += entry.usage.output
      total = saturatingAdd(total, nano)
      if entry.costSource == .computed { estimated = saturatingAdd(estimated, nano) }
      if entry.costSource == .pending { unpriced += 1 }
      let role = entry.task.rawValue
      if roles[role] == nil { roleOrder.append(role) }
      roles[role, default: RoleUsage()].calls += 1
      roles[role, default: RoleUsage()].nanoUSD = saturatingAdd(roles[role]?.nanoUSD ?? 0, nano)
    }
    var lines = [
      "Usage for \(scope): \(entries.count) calls, \(formatTokens(input + output)) tokens (\(formatTokens(input)) in / \(formatTokens(output)) out), \(formatUSD(nanoUSD: total)).",
      estimated > 0 || unpriced > 0 ? "Some of this figure is estimated — not every call recorded a price." : "Fully recorded — no estimate involved.",
    ]
    if roleOrder.count > 1 {
      lines.append(contentsOf: ["", "By role:"])
      for role in roleOrder.jsStableSorted(by: { (roles[$0]?.nanoUSD ?? 0) > (roles[$1]?.nanoUSD ?? 0) }) {
        lines.append("- \(role): \(roles[role]?.calls ?? 0) calls, \(formatUSD(nanoUSD: roles[role]?.nanoUSD ?? 0))")
      }
    }
    return lines.joined(separator: "\n")
  }
}
