import Foundation
import ShadowStore

/// How this device's launch sweep left a card's interrupted actions (`nf_local_pending_action`, never synced).
public struct ChatPendingActionStanding: Sendable, Equatable {
  public let proposal: UUID
  public let attempts: Int
  /// The code the last sweep left the actions pending with.
  public let fault: String?

  /// Swept on as many launches as `PendingActions.attemptLimit` allows: no later launch runs them.
  public var isGivenUp: Bool { attempts >= PendingActions.attemptLimit }

  /// The novel's rows, by proposal; a row this device cannot read is left out, as the sweep steps over it.
  public static func load(novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [UUID: ChatPendingActionStanding] {
    let rows = try PendingActions.rows(in: transaction.database).filter { $0.novel == novel }
    return Dictionary(rows.map { ($0.proposal, ChatPendingActionStanding(proposal: $0.proposal, attempts: $0.attempts, fault: $0.fault)) }) { first, _ in first }
  }
}
