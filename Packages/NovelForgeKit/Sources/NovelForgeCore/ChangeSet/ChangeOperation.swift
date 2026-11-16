// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:344
enum ChangeOperation: Sendable, Equatable {
  case premiseUpdate(PremiseUpdate)
  case bibleDocumentUpsert(BibleDocumentUpsert)
  case bibleDocumentRemove(BibleDocumentRemove)
  case volumeUpsert(VolumeUpsert)
  case volumeRemove(VolumeRemove)
  case briefUpdate(BriefUpdate)
  case briefRemove(BriefRemove)
  case draftUpdate(DraftUpdate)
  case draftRemove(DraftRemove)
  case draftRewritePassage(DraftRewritePassage)
  case entityUpsert(EntityUpsert)
  case entityRemove(EntityRemove)
  case factUpsert(FactUpsert)
  case factRemove(FactRemove)
  case milestoneUpsert(MilestoneUpsert)
  case milestoneRemove(MilestoneRemove)
  case promiseCreate(PromiseCreate)
  case promiseUpdate(PromiseUpdate)
  case promiseSetPayoff(PromiseSetPayoff)
  case promiseDrop(PromiseDrop)
  case organiseRule(OrganiseRule)
  case actionGenerateChapter(GenerateChapterAction)
  case actionAuditBible(AuditBibleAction)
  case actionEnhancePremise(EnhancePremiseAction)
  case actionJudgeDraft(JudgeDraftAction)
  case actionReviseDraft(ReviseDraftAction)
  case actionApproveDraft(ApproveDraftAction)
  case actionApplyContinuity(ApplyContinuityAction)
  case actionValidate(ValidateAction)
  case actionFinalize(FinalizeAction)
  case actionOrganiseNotes(OrganiseNotesAction)
  case actionPlanChapter(PlanChapterAction)
  case actionAdvanceVolume(AdvanceVolumeAction)

  init?(type: OpType, fields: OpFields) {
    guard let built = Self.build(type, fields) else { return nil }
    self = built
  }

  private static func build(_ type: OpType, _ fields: OpFields) -> ChangeOperation? {
    switch type {
    case .premiseUpdate: PremiseUpdate(fields).map(ChangeOperation.premiseUpdate)
    case .bibleDocumentUpsert: BibleDocumentUpsert(fields).map(ChangeOperation.bibleDocumentUpsert)
    case .bibleDocumentRemove: BibleDocumentRemove(fields).map(ChangeOperation.bibleDocumentRemove)
    case .volumeUpsert: VolumeUpsert(fields).map(ChangeOperation.volumeUpsert)
    case .volumeRemove: VolumeRemove(fields).map(ChangeOperation.volumeRemove)
    case .briefUpdate: BriefUpdate(fields).map(ChangeOperation.briefUpdate)
    case .briefRemove: BriefRemove(fields).map(ChangeOperation.briefRemove)
    case .draftUpdate: DraftUpdate(fields).map(ChangeOperation.draftUpdate)
    case .draftRemove: DraftRemove(fields).map(ChangeOperation.draftRemove)
    case .draftRewritePassage: DraftRewritePassage(fields).map(ChangeOperation.draftRewritePassage)
    case .entityUpsert: EntityUpsert(fields).map(ChangeOperation.entityUpsert)
    case .entityRemove: EntityRemove(fields).map(ChangeOperation.entityRemove)
    case .factUpsert: FactUpsert(fields).map(ChangeOperation.factUpsert)
    case .factRemove: FactRemove(fields).map(ChangeOperation.factRemove)
    case .milestoneUpsert: MilestoneUpsert(fields).map(ChangeOperation.milestoneUpsert)
    case .milestoneRemove: MilestoneRemove(fields).map(ChangeOperation.milestoneRemove)
    case .promiseCreate: PromiseCreate(fields).map(ChangeOperation.promiseCreate)
    case .promiseUpdate: PromiseUpdate(fields).map(ChangeOperation.promiseUpdate)
    case .promiseSetPayoff: PromiseSetPayoff(fields).map(ChangeOperation.promiseSetPayoff)
    case .promiseDrop: PromiseDrop(fields).map(ChangeOperation.promiseDrop)
    case .organiseRule: OrganiseRule(fields).map(ChangeOperation.organiseRule)
    case .actionGenerateChapter: GenerateChapterAction(fields).map(ChangeOperation.actionGenerateChapter)
    case .actionAuditBible: AuditBibleAction(fields).map(ChangeOperation.actionAuditBible)
    case .actionEnhancePremise: EnhancePremiseAction(fields).map(ChangeOperation.actionEnhancePremise)
    case .actionJudgeDraft: JudgeDraftAction(fields).map(ChangeOperation.actionJudgeDraft)
    case .actionReviseDraft: ReviseDraftAction(fields).map(ChangeOperation.actionReviseDraft)
    case .actionApproveDraft: ApproveDraftAction(fields).map(ChangeOperation.actionApproveDraft)
    case .actionApplyContinuity: ApplyContinuityAction(fields).map(ChangeOperation.actionApplyContinuity)
    case .actionValidate: ValidateAction(fields).map(ChangeOperation.actionValidate)
    case .actionFinalize: FinalizeAction(fields).map(ChangeOperation.actionFinalize)
    case .actionOrganiseNotes: OrganiseNotesAction(fields).map(ChangeOperation.actionOrganiseNotes)
    case .actionPlanChapter: PlanChapterAction(fields).map(ChangeOperation.actionPlanChapter)
    case .actionAdvanceVolume: AdvanceVolumeAction(fields).map(ChangeOperation.actionAdvanceVolume)
    }
  }

  var type: OpType {
    switch self {
    case .premiseUpdate: .premiseUpdate
    case .bibleDocumentUpsert: .bibleDocumentUpsert
    case .bibleDocumentRemove: .bibleDocumentRemove
    case .volumeUpsert: .volumeUpsert
    case .volumeRemove: .volumeRemove
    case .briefUpdate: .briefUpdate
    case .briefRemove: .briefRemove
    case .draftUpdate: .draftUpdate
    case .draftRemove: .draftRemove
    case .draftRewritePassage: .draftRewritePassage
    case .entityUpsert: .entityUpsert
    case .entityRemove: .entityRemove
    case .factUpsert: .factUpsert
    case .factRemove: .factRemove
    case .milestoneUpsert: .milestoneUpsert
    case .milestoneRemove: .milestoneRemove
    case .promiseCreate: .promiseCreate
    case .promiseUpdate: .promiseUpdate
    case .promiseSetPayoff: .promiseSetPayoff
    case .promiseDrop: .promiseDrop
    case .organiseRule: .organiseRule
    case .actionGenerateChapter: .actionGenerateChapter
    case .actionAuditBible: .actionAuditBible
    case .actionEnhancePremise: .actionEnhancePremise
    case .actionJudgeDraft: .actionJudgeDraft
    case .actionReviseDraft: .actionReviseDraft
    case .actionApproveDraft: .actionApproveDraft
    case .actionApplyContinuity: .actionApplyContinuity
    case .actionValidate: .actionValidate
    case .actionFinalize: .actionFinalize
    case .actionOrganiseNotes: .actionOrganiseNotes
    case .actionPlanChapter: .actionPlanChapter
    case .actionAdvanceVolume: .actionAdvanceVolume
    }
  }

  fileprivate func encode(into encoder: inout OpEncoder) {
    switch self {
    case .premiseUpdate(let payload): payload.encode(into: &encoder)
    case .bibleDocumentUpsert(let payload): payload.encode(into: &encoder)
    case .bibleDocumentRemove(let payload): payload.encode(into: &encoder)
    case .volumeUpsert(let payload): payload.encode(into: &encoder)
    case .volumeRemove(let payload): payload.encode(into: &encoder)
    case .briefUpdate(let payload): payload.encode(into: &encoder)
    case .briefRemove(let payload): payload.encode(into: &encoder)
    case .draftUpdate(let payload): payload.encode(into: &encoder)
    case .draftRemove(let payload): payload.encode(into: &encoder)
    case .draftRewritePassage(let payload): payload.encode(into: &encoder)
    case .entityUpsert(let payload): payload.encode(into: &encoder)
    case .entityRemove(let payload): payload.encode(into: &encoder)
    case .factUpsert(let payload): payload.encode(into: &encoder)
    case .factRemove(let payload): payload.encode(into: &encoder)
    case .milestoneUpsert(let payload): payload.encode(into: &encoder)
    case .milestoneRemove(let payload): payload.encode(into: &encoder)
    case .promiseCreate(let payload): payload.encode(into: &encoder)
    case .promiseUpdate(let payload): payload.encode(into: &encoder)
    case .promiseSetPayoff(let payload): payload.encode(into: &encoder)
    case .promiseDrop(let payload): payload.encode(into: &encoder)
    case .organiseRule(let payload): payload.encode(into: &encoder)
    case .actionGenerateChapter(let payload): payload.encode(into: &encoder)
    case .actionAuditBible(let payload): payload.encode(into: &encoder)
    case .actionEnhancePremise(let payload): payload.encode(into: &encoder)
    case .actionJudgeDraft(let payload): payload.encode(into: &encoder)
    case .actionReviseDraft(let payload): payload.encode(into: &encoder)
    case .actionApproveDraft(let payload): payload.encode(into: &encoder)
    case .actionApplyContinuity(let payload): payload.encode(into: &encoder)
    case .actionValidate(let payload): payload.encode(into: &encoder)
    case .actionFinalize(let payload): payload.encode(into: &encoder)
    case .actionOrganiseNotes(let payload): payload.encode(into: &encoder)
    case .actionPlanChapter(let payload): payload.encode(into: &encoder)
    case .actionAdvanceVolume(let payload): payload.encode(into: &encoder)
    }
  }
}

struct ChangeOp: Sendable, Equatable {
  let operation: ChangeOperation
  let metadata: OpMetadata

  var type: OpType { operation.type }

  init(operation: ChangeOperation, metadata: OpMetadata) {
    self.operation = operation
    self.metadata = metadata
  }

  init?(validated record: OrderedJSONObject) {
    let fields = OpFields(record: record)
    guard let type = OpType(exactly: fields.string("op") ?? ""), let operation = ChangeOperation(type: type, fields: fields) else { return nil }
    self.operation = operation
    metadata = OpMetadata(fields)
  }

  var fields: OrderedJSONObject {
    var encoder = OpEncoder()
    encoder.string("op", type.rawValue)
    operation.encode(into: &encoder)
    metadata.encode(into: &encoder)
    return OrderedJSONObject(encoder.pairs)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:177
func opFields(_ op: ChangeOp) -> OrderedJSONObject {
  op.fields
}

func isActionOp(_ op: ChangeOp) -> Bool {
  op.type.isAction
}
