import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowCore

/// The line under a reply (apps/novel-forge-web/src/components/nf/ChatModel.tsx:15-23 over src/lib/chat-model.ts:15-22): its pace, Unrestricted when it
/// was, its cost, how long the turn worked, and when it was written. The reference names the model for admins only, and no model is stored here.
enum ChatReplyTag {
  static func parts(of reply: ChatMessageRecord, cost: ChatReplyCost?, at date: Date, now: Date = Date()) -> [String] {
    var parts = [String]()
    if case .known(let tier)? = reply.pace { parts.append(pace(tier).displayName) }
    if reply.contentMode == .known(.unrestricted) { parts.append(String(localized: "Unrestricted", table: "Chat")) }
    if let cost { parts.append(cost.isPending ? String(localized: "cost pending", table: "Chat") : usd(cost.cost)) }
    if let worked = worked(reply.trace) { parts.append(worked.prefix(1).lowercased() + worked.dropFirst()) }
    parts.append(time(date, now: now))
    return parts
  }

  /// apps/novel-forge-web/src/lib/usage.ts:157-162
  static func usd(_ cost: Cost) -> String {
    let value = Decimal(cost.nanoUSD) / Decimal(Cost.nanoUSDPerUSD)
    let thousandth = Decimal(string: "0.001") ?? 0
    if value > 0 && value < thousandth { return "<" + thousandth.formatted(.currency(code: "USD").precision(.fractionLength(3))) }
    var rounded = Decimal()
    var scaled = value * 1000
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    let tenthOfCent = rounded / 1000
    if tenthOfCent > 0 && tenthOfCent < Decimal(string: "0.1") ?? 0 { return tenthOfCent.formatted(.currency(code: "USD").precision(.fractionLength(3))) }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
  }

  /// apps/novel-forge-web/src/lib/format.ts:36-47
  static func time(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let clock = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return clock }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let day = sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.year().month(.abbreviated).day())
    return "\(day), \(clock)"
  }

  /// apps/novel-forge-web/src/lib/chat-turn-timeline.ts:156-159: the saved trace's working time and the sources it read.
  static func worked(_ trace: JSONValue?) -> String? {
    guard let fields = trace?.objectValue, let milliseconds = fields["timing"]?.objectValue?["workedMs"]?.intValue else { return nil }
    let sources = fields["sources"]?.arrayValue ?? []
    let read = sources.count { $0.objectValue?["status"]?.stringValue != "error" }
    return ChatTurnTimeline.worked(TimeInterval(milliseconds) / 1000, stopped: false, sources: read)
  }

  static func pace(_ tier: CostTier) -> Pace {
    switch tier {
    case .economy: .swift
    case .balanced: .steady
    case .performant: .meticulous
    }
  }
}
