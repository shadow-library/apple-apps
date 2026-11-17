// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:15
let heldForReviewNote = "Not applied automatically: review the warnings on these suggestions first."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:16
let writerReadHeldNote = "Changes the chapter writer or your readers could see wait for your review, because this turn drew on your notes."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:17
let applyFailedNote = "Your words could not be applied as they stand, so every change is offered as a suggestion instead."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:18
let unlinkedNote = "Your words were applied, but this reply could not be linked to them — find the change in Change history to undo it."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:19
let cardsUnsavedNote = "Your words were applied, but the suggestions that came with them could not be saved — ask again to see them."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:20
let ideasDroppedNote = "Suggestions you turned down earlier were left out."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:21
let organiseStartedNote = "Organising your notes has started, and its results will arrive here for your review."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:22
let organiseBusyNote = "Another job is running on this novel, so organising your notes waits on the card: accept it once that job finishes."

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:23
let organiseRefusedNote = "Organising your notes could not start on its own, so it waits on the card."

// apps/novel-forge-server/src/modules/refinement/chat.service.ts:132
func negationFixRequest(_ warnings: [String]) -> String {
  "Your changeSet removes things by stating their absence, which hands them straight back to the chapter writer:\n\(warnings.map { "- \($0)" }.joined(separator: "\n"))\n\nRespond again with the same JSON shape and no lookups: rewrite each of those passages without the removed idea, and keep every other change. Keep any line that withholds knowledge or schedules a reveal (\"does not yet learn\", \"no longer\") — that is plot, not a removal."
}
