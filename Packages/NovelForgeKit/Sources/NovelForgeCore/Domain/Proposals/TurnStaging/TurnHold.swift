import ShadowText

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:25-27
enum TurnHoldReason: String, CaseIterable, Sendable {
  case warnings
  case plannerSources = "planner_sources"
}

struct TurnHoldNote: Sendable, Equatable {
  let note: String
  let reason: TurnHoldReason
}

// turn-proposals.ts:96: reading the notes or a planner-only page holds what the chapter writer or a reader can see; any other warning holds the whole turn
func turnHold(_ warnings: [String]) -> WriteHold {
  if warnings.isEmpty { return .none }
  return warnings.allSatisfy { $0.jsEquals(plannerOnlyWarning) } ? .writerRead : .turn
}

// turn-proposals.ts:29
func turnHoldNote(_ hold: WriteHold) -> TurnHoldNote? {
  switch hold {
  case .none: nil
  case .turn: TurnHoldNote(note: heldForReviewNote, reason: .warnings)
  case .writerRead: TurnHoldNote(note: writerReadHeldNote, reason: .plannerSources)
  }
}
