import ShadowText

enum IdeaPolicy: Sendable, Equatable {
  case idea
  case card(AlwaysCardRule)
}

extension OpType {
  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:88
  var isDirectKind: Bool {
    switch self {
    case .premiseUpdate, .bibleDocumentUpsert, .entityUpsert, .factUpsert, .volumeUpsert, .promiseCreate, .promiseUpdate: true
    default: false
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:98
  var alwaysCardRule: AlwaysCardRule? {
    if isAction { return .action }
    switch self {
    case .bibleDocumentRemove, .volumeRemove, .briefRemove, .draftRemove, .entityRemove, .factRemove, .milestoneRemove, .promiseDrop: return .removal
    case .briefUpdate: return .plan
    case .draftUpdate, .draftRewritePassage: return .prose
    case .promiseSetPayoff: return .promiseDisposition
    default: return nil
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:115
  var ideaPolicy: IdeaPolicy {
    switch self {
    case .premiseUpdate, .bibleDocumentUpsert, .volumeUpsert, .entityUpsert, .milestoneUpsert, .promiseCreate, .promiseUpdate: .idea
    case .bibleDocumentRemove, .volumeRemove, .briefRemove, .draftRemove, .entityRemove, .factRemove, .milestoneRemove, .promiseDrop: .card(.removal)
    case .briefUpdate: .card(.plan)
    case .draftUpdate, .draftRewritePassage: .card(.prose)
    case .factUpsert: .card(.secretTruth)
    case .promiseSetPayoff: .card(.promiseDisposition)
    case .organiseRule: .card(.notebookDirection)
    case .actionGenerateChapter, .actionAuditBible, .actionEnhancePremise, .actionJudgeDraft, .actionReviseDraft, .actionApproveDraft, .actionApplyContinuity, .actionValidate,
      .actionFinalize, .actionOrganiseNotes, .actionPlanChapter, .actionAdvanceVolume:
      .card(.action)
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:141
  var isPlannerSide: Bool { self == .milestoneUpsert }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:154
  var textFields: [String] {
    switch self {
    case .premiseUpdate: WritePolicyTables.storyFields
    case .bibleDocumentUpsert: ["body", "frontmatter"]
    case .volumeUpsert: ["title", "objective", "body"]
    case .entityUpsert: ["status", "motivation", "notes", "body"]
    case .factUpsert: ["body", "constraintNote", "terms"]
    case .promiseCreate, .promiseUpdate, .milestoneUpsert: ["label"]
    default: []
    }
  }
}

enum WritePolicyTables {
  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:143
  static let minQuoteWords = 3
  static let noveltyFloor = 4.0
  static let removalFloor = 4.0
  static let budgetShare = 0.25
  static let storyFields = declaredOpFields(.premiseUpdate)
  static let payoffFields = ["payoffMilestoneKey", "payoffVolumeKey", "payoffWindow"]
  static let factDirectFields: Set<String> = ["factKey", "body", "subjects", "constraintNote", "terms"]
  static let identifierKeyFields = ["entityKey", "factKey", "volumeKey", "milestoneKey", "key"]
  static let displayKeyFields = ["section", "slug", "name"]

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:174
  static let quoteStopwords: Set<JSString> = Set(stopwordList.jsSplit(" ").map { JSString($0) })

  private static let stopwordList: String =
    "a an the and or but if then than so as at by for from in into of off on onto out over to up with about after before under again "
    + "is are was were be been being am do does did done have has had having will would shall should can could may might must "
    + "i me my we our you your he him his she her it it its they them their this that these those who whom whose which what where when why how "
    + "not no nor all any both each few more most other some such only own same too very just also there here now one"
}
