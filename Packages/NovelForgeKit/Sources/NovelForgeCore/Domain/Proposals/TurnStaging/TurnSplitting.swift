import ShadowText

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:81
struct TurnPolicyContext: Sendable {
  var authorMessage: String
  var mode: RefinementChatMode
  var justDiscussing: Bool
  var warnings: [String]
}

// turn-proposals.ts:90
struct TurnSplit: Sendable, Equatable {
  let split: ChangeSetSplit
  /// Ideas left out because the author turned them down, or because they leaned on one that was.
  let droppedIdeas: [String]
}

extension ChangeSetSplit {
  fileprivate func holding(_ held: WriteHold) -> ChangeSetSplit {
    ChangeSetSplit(ops: ops, direct: direct, cards: cards, sources: sources, dispositions: dispositions, held: held)
  }
}

/// turn-proposals.ts:102 over the records as they stand when the turn stages. `rejectedIdeas` answers which candidate ideas the author turned down in a
/// scope that still holds, or nil when they cannot be read, and then no idea applies; one answering none leaves the split as the policy made it.
func splitTurnChangeSet(_ ops: [ChangeOp], context: TurnPolicyContext, state: WritePolicyState, rejectedIdeas: ([String]) -> Set<JSString>?) -> TurnSplit {
  func input(_ ops: [ChangeOp], _ ideas: IdeaHandling) -> WritePolicyInput {
    WritePolicyInput(
      ops: ops, authorMessage: context.authorMessage, mode: context.mode, ideas: ideas, justDiscussing: context.justDiscussing, hold: turnHold(context.warnings),
      state: state)
  }
  let split = WritePolicy.split(input(ops, .apply))
  let candidates = IdeaIdentity.filterableIdeaIds(split)
  if candidates.isEmpty { return TurnSplit(split: split, droppedIdeas: []) }
  guard let rejected = rejectedIdeas(candidates) else { return TurnSplit(split: WritePolicy.split(input(ops, .card)), droppedIdeas: []) }
  let filtered = IdeaIdentity.dropRejectedIdeas(split, rejected: rejected, current: state)
  if filtered.dropped.isEmpty { return TurnSplit(split: filtered.split, droppedIdeas: []) }
  let held = WritePolicy.split(input(filtered.split.ops, .apply)).held
  return TurnSplit(split: filtered.split.holding(held), droppedIdeas: filtered.dropped)
}
