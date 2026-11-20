import ShadowText

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-refs.ts:5
func actionDecisionKeys(_ ops: [ChangeOp]) -> [String] {
  let keys = ops.filter(isActionOp).map { op -> String in
    let name = op.type.rawValue
    switch op.operation {
    case .actionPlanChapter: return name
    case .actionGenerateChapter(let action): return "\(name):\(action.chapter)"
    case .actionJudgeDraft(let action): return "\(name):\(action.chapter)"
    case .actionReviseDraft(let action): return "\(name):\(action.chapter)"
    case .actionApproveDraft(let action): return "\(name):\(action.chapter)"
    case .actionApplyContinuity(let action): return "\(name):\(action.chapter)"
    case .actionValidate(let action): return action.chapter.map { "\(name):\($0)" } ?? name
    case .actionAdvanceVolume(let action): return "\(name):\(action.volumeKey)"
    default: return name
    }
  }
  return keys.jsUnique()
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-refs.ts:16
func changeSetRefs(_ ops: [ChangeOp]) -> [String] {
  let refs = ops.flatMap { op -> [String] in
    switch op.operation {
    case .premiseUpdate: ["premise"]
    case .bibleDocumentUpsert(let doc): ["doc:\(doc.section.rawValue)/\(doc.slug)"]
    case .bibleDocumentRemove(let doc): ["doc:\(doc.section.rawValue)/\(doc.slug)"]
    case .volumeUpsert(let volume): ["volume:\(volume.volumeKey)"]
    case .volumeRemove(let volume): ["volume:\(volume.volumeKey)"]
    case .entityUpsert(let entity): ["entity:\(entity.entityKey)"]
    case .entityRemove(let entity): ["entity:\(entity.entityKey)"]
    case .factUpsert(let fact): ["fact:\(fact.factKey)"]
    case .factRemove(let fact): ["fact:\(fact.factKey)"]
    case .milestoneUpsert(let milestone): ["milestone:\(milestone.milestoneKey)"]
    case .milestoneRemove(let milestone): ["milestone:\(milestone.milestoneKey)"]
    case .promiseCreate(let promise): ["promise:\(promise.kind.rawValue):\(promise.key)"]
    case .promiseUpdate(let promise): ["promise:\(promise.kind.rawValue):\(promise.key)"]
    case .promiseSetPayoff(let promise): ["promise:\(promise.kind.rawValue):\(promise.key)"]
    case .promiseDrop(let promise): ["promise:\(promise.kind.rawValue):\(promise.key)"]
    case .organiseRule: []
    case .draftUpdate(let draft): ["draft:\(draft.chapter)"]
    case .draftRemove(let draft): ["draft:\(draft.chapter)"]
    case .draftRewritePassage(let draft): ["draft:\(draft.chapter)"]
    case .briefUpdate(let brief): ["chapter:\(brief.chapter)"]
    case .briefRemove(let brief): ["chapter:\(brief.chapter)"]
    default: []
    }
  }
  return refs.jsUnique()
}
