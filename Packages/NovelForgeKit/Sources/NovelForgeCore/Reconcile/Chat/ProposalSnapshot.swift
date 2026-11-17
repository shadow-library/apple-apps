import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum ProposalReadability: String, Sendable, DatabaseValueConvertible {
  case readable
  /// The card reads but the first applier's `applied` does not, so an index without a change record reads as awaiting, never as declined.
  case applicationUnreadable = "application_unreadable"
  /// Only the decision and the novel can be read. A proposal whose card is absent or names no readable novel gets no row.
  case cardUnreadable = "card_unreadable"
}

/// A proposal read member by member, so a card shown in the chat keeps its decision when its `applied` is malformed, and a card this version cannot read
/// keeps its decision and novel.
struct ProposalSnapshot {
  let id: UUID
  let novel: UUID
  let card: ProposalCard?
  let decision: StoredEnum<ProposalDecision>?
  let application: ProposalApplication?
  let readability: ProposalReadability
  let staged: HLCTimestamp

  init?(_ ref: EntityRef, _ state: EntityState?) {
    guard let id = ChatColumns.id(of: ref, .proposal), case .record(let record)? = state, let stored = record[field: ProposalField.card.rawValue] else { return nil }
    let card = ProposalCard(json: stored.value)
    guard let novel = card?.novel ?? stored.value[ProposalCardMember.novel.rawValue].flatMap(UUID.init(json:)) else { return nil }
    var application: ProposalApplication?
    var applicationReadable = true
    if let applied = record[field: ProposalField.applied.rawValue]?.value, !applied.isNull {
      application = ProposalApplication(json: applied)
      applicationReadable = application != nil
    }
    self.id = id
    self.novel = novel
    self.card = card
    decision = record[field: ProposalField.decision.rawValue].flatMap { StoredEnum(json: $0.value) }
    self.application = application
    readability = card == nil ? .cardUnreadable : applicationReadable ? .readable : .applicationUnreadable
    staged = stored.clock
  }

  /// The decision's place in the monotone merge order (pending < superseded < discarded < applied); nil for a value this version does not know.
  static func rank(of decision: StoredEnum<ProposalDecision>?) -> Int? {
    decision?.known.flatMap { ProposalDecision.allCases.firstIndex(of: $0) }
  }

  func isAction(at index: Int) -> Bool {
    guard let ops = card?.changeSet, ops.indices.contains(index) else { return false }
    let op = ops[index]
    if let parsed = op.op { return isActionOp(parsed) }
    return op.stored["op"]?.stringValue?.jsStartsWith("action.") ?? false
  }
}
