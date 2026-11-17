import Foundation
import ShadowAI
import ShadowStore

public struct ChatReplyCalls: Sendable, Equatable {
  public let message: UUID
  public let calls: [UUID]

  public init(message: UUID, calls: [UUID]) {
    self.message = message
    self.calls = calls
  }
}

/// A reply's model spend (apps/novel-forge-server/src/modules/ai/usage/call-usage.ts:37-46). The ledger keeps no latency, so none is summed.
public struct ChatReplyCost: Sendable, Equatable {
  /// Ledger entries read: the reply's calls and every attempt they abandoned.
  public let calls: Int
  public let usage: TokenUsage
  /// What the priced entries cost.
  public let cost: Cost
  /// The share of `cost` computed from catalog prices rather than reported by the provider (call-usage.ts:43, `estimatedCostUsd`).
  public let estimated: Cost
  /// Entries whose price is not known yet, such as an OpenRouter call before its cost is reconciled.
  public let pendingCalls: Int
  /// Calls the reply names that this device holds no readable ledger entry for, as before their entries arrive by sync.
  public let missingCalls: Int

  /// "cost pending": `cost` is a lower bound until every call is recorded and priced.
  public var isPending: Bool { pendingCalls > 0 || missingCalls > 0 }

  static func summing(_ entries: [ModelCallEntry], missing: Int) -> ChatReplyCost {
    var usage = TokenUsage.zero
    var cost: Int64 = 0
    var estimated: Int64 = 0
    var pending = 0
    for entry in entries {
      usage = saturatingSum(usage, entry.usage)
      guard entry.costSource != .pending, let price = entry.cost else {
        pending += 1
        continue
      }
      let nanoUSD = max(price.nanoUSD, 0)
      cost = saturatingAdd(cost, nanoUSD)
      if entry.costSource == .computed { estimated = saturatingAdd(estimated, nanoUSD) }
    }
    return ChatReplyCost(
      calls: entries.count, usage: usage, cost: Cost(nanoUSD: cost), estimated: Cost(nanoUSD: estimated), pendingCalls: pending, missingCalls: missing)
  }

  private static func saturatingAdd<Count: FixedWidthInteger>(_ left: Count, _ right: Count) -> Count {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Count.max : sum
  }

  /// Stored counts are clamped to `Int.max`, so a plain sum of two could trap.
  private static func saturatingSum(_ left: TokenUsage, _ right: TokenUsage) -> TokenUsage {
    TokenUsage(
      input: saturatingAdd(left.input, right.input), output: saturatingAdd(left.output, right.output), cacheRead: saturatingAdd(left.cacheRead, right.cacheRead),
      cacheWriteShort: saturatingAdd(left.cacheWriteShort, right.cacheWriteShort), cacheWriteLong: saturatingAdd(left.cacheWriteLong, right.cacheWriteLong))
  }
}

/// apps/novel-forge-server/src/modules/refinement/turn-cost.service.ts:17-55: each reply's cost from the calls it made. A reply stores its own call ids
/// (orchestrator decision 9) in place of the reference's run and child runs; each call's abandoned attempts are its ledger children.
public struct ChatReplyCosts: ReadModel {
  public let costs: [UUID: ChatReplyCost]

  public static func load(_ replies: [ChatReplyCalls], in transaction: ReadTransaction) throws(StoreError) -> ChatReplyCosts {
    var costs = [UUID: ChatReplyCost]()
    for reply in replies {
      var entries = [ModelCallEntry]()
      var missing = 0
      for call in Set(reply.calls).sorted(by: { $0.uuidString < $1.uuidString }) {
        let read = try Ledger.entries(ofCall: call, in: transaction)
        if read.isEmpty { missing += 1 }
        entries += read
      }
      costs[reply.message] = ChatReplyCost.summing(entries, missing: missing)
    }
    return ChatReplyCosts(costs: costs)
  }
}

extension ChatTranscriptPage {
  /// The page's replies that name their model calls; an author message never carries a figure (turn-cost.service.ts:17-19).
  public var replyCalls: [ChatReplyCalls] {
    messages.compactMap { message in
      guard let record = message.record, record.role == .known(.assistant), let calls = record.modelCalls else { return nil }
      return ChatReplyCalls(message: record.id, calls: calls)
    }
  }
}
