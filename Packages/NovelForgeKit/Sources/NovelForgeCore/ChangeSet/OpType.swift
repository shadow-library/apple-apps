import ShadowText

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:345
public enum OpType: String, CaseIterable, Sendable {
  case premiseUpdate = "premise.update"
  case bibleDocumentUpsert = "bible_document.upsert"
  case bibleDocumentRemove = "bible_document.remove"
  case volumeUpsert = "volume.upsert"
  case volumeRemove = "volume.remove"
  case briefUpdate = "brief.update"
  case briefRemove = "brief.remove"
  case draftUpdate = "draft.update"
  case draftRemove = "draft.remove"
  case draftRewritePassage = "draft.rewrite_passage"
  case entityUpsert = "entity.upsert"
  case entityRemove = "entity.remove"
  case factUpsert = "fact.upsert"
  case factRemove = "fact.remove"
  case milestoneUpsert = "milestone.upsert"
  case milestoneRemove = "milestone.remove"
  case promiseCreate = "promise.create"
  case promiseUpdate = "promise.update"
  case promiseSetPayoff = "promise.set_payoff"
  case promiseDrop = "promise.drop"
  case organiseRule = "organise.rule"
  case actionGenerateChapter = "action.generate_chapter"
  case actionAuditBible = "action.audit_bible"
  case actionEnhancePremise = "action.enhance_premise"
  case actionJudgeDraft = "action.judge_draft"
  case actionReviseDraft = "action.revise_draft"
  case actionApproveDraft = "action.approve_draft"
  case actionApplyContinuity = "action.apply_continuity"
  case actionValidate = "action.validate"
  case actionFinalize = "action.finalize"
  case actionOrganiseNotes = "action.organise_notes"
  case actionPlanChapter = "action.plan_chapter"
  case actionAdvanceVolume = "action.advance_volume"

  var isAction: Bool { rawValue.jsStartsWith("action.") }

  // apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:167
  static let actions: [OpType] = allCases.filter(\.isAction)

  // apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:168
  static let content: [OpType] = allCases.filter { !$0.isAction }

  init?(exactly text: String) {
    guard let match = Self.allCases.first(where: { $0.rawValue.jsEquals(text) }) else { return nil }
    self = match
  }
}
