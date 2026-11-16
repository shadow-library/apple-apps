extension OpType {
  // apps/novel-forge-server/src/modules/refinement/change-set/op-vocabulary.ts:7
  var purpose: String? {
    switch self {
    case .actionGenerateChapter:
      "draft one planned chapter from its plan (drafted, judged, and queued for review) — chapters are written in order, so it must be the next one without a draft; never auto-applied"
    case .actionAuditBible:
      "queue a Story Bible audit: missing, thin or pointless pages and records, and contradictions between pages, records, facts and finalized chapters — its report holds the findings and one card of proposed changes"
    case .actionEnhancePremise: "evaluate and strengthen the premise as a web novel — stages a premise proposal"
    case .actionJudgeDraft: "run the continuity judge on one chapter draft"
    case .actionReviseDraft: "revise one chapter draft using `note` as the revision feedback"
    case .actionApproveDraft: "approve one reviewed chapter draft"
    case .actionApplyContinuity:
      "add one chapter's pending Story Bible additions (the continuity proposal waiting on the author) to the Story Bible — writes canon, never auto-applied"
    case .actionValidate: "run continuity validation over the novel or one chapter"
    case .actionFinalize:
      "finalize an approved chapter (`upTo`) into locked canon, writing the Story Bible updates its review kept — refused while any of them still waits on the author's call, which they make on the chapter's Story Bible card; approval already finalizes a chapter that left nothing to ask — irreversible, never auto-applied"
    case .actionOrganiseNotes: "organise the author's stored notes into Story Bible pages, records, a timeline and open questions — runs as a job and stages the result as a card"
    case .actionPlanChapter:
      "plan the next chapter — the lowest-numbered one without a draft; `chapter` must be that chapter when given. Before planning, recap in your reply the two or three obligations that matter now (the previous chapter's hook, the longest-quiet promise, what the volume goal needs); when the author has not said what happens, offer two or three directions, each saying which obligation it moves and what it costs, and let the author choose. Then plan from `direction` (the one the author chose, as offered), `intent` (what the author says happens, in their words), or `empty: true` (an empty plan the author fills in). Runs as a job and stages the plan as a card; the plan never sets the chapter's content mode"
    case .actionAdvanceVolume:
      #"the author's "goal met — start next": `volumeKey` must name the currently active volume, which becomes goal met; the next not-started volume in order becomes active, or none does if there isn't one yet — never auto-applied"#
    default: nil
    }
  }
}
