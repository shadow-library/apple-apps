// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:3
enum OpFieldKind: String, Sendable {
  case string = "string"
  case nullableString = "string|null"
  case integer = "number"
  case nullableInteger = "number|null"
  case boolean = "boolean"
  case strings = "string[]"
  case nullableStrings = "string[]|null"
  case object = "object"
  case objects = "object[]"
  case nullableObjects = "object[]|null"
  case nullableObject = "object|null"

  var admitsNull: Bool { rawValue.jsEndsWith("|null") }
}

struct OpField: Sendable {
  let name: String
  let kind: OpFieldKind

  init(_ name: String, _ kind: OpFieldKind) {
    self.name = name
    self.kind = kind
  }
}

struct OpSpec: Sendable {
  let required: [OpField]
  let optional: [OpField]
  let description: String?
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:143
let opMetadataFields = ["rationale", "quote", "startedEmpty", "ideaId"]

private let serverMetadataFields = ["startedEmpty", "ideaId"]

struct OpVocabularyOptions: Sendable {
  var quotes: Bool

  init(quotes: Bool = false) {
    self.quotes = quotes
  }
}

extension OpType {
  // apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:20
  var declaredSpec: OpSpec {
    switch self {
    case .premiseUpdate:
      OpSpec(
        required: [],
        optional: [
          OpField("premise", .string), OpField("brief", .string), OpField("themes", .strings), OpField("instructions", .string), OpField("theme", .string),
          OpField("readerPromise", .string), OpField("protagonistKey", .string), OpField("opposition", .string), OpField("endingQuestion", .string), OpField("ending", .string),
        ],
        description:
          "The story basics. theme is what the book is about underneath the plot, in a sentence; readerPromise is what the reader is waiting for and expects paid off; protagonistKey is the entity key of the character the reader follows; opposition is what pushes back on the leads, so chapters have something to write against — a person or faction, but just as well the situation itself, survival, nature, scarcity, a system or the lead’s own flaw, named specifically enough to escalate; endingQuestion is the question the ending answers and ending is how the book ends, both planner-only and never shown to the reader early."
      )
    case .bibleDocumentUpsert:
      OpSpec(required: [OpField("section", .string), OpField("slug", .string)], optional: [OpField("frontmatter", .object), OpField("body", .string)], description: nil)
    case .bibleDocumentRemove:
      OpSpec(required: [OpField("section", .string), OpField("slug", .string)], optional: [], description: nil)
    case .volumeUpsert:
      OpSpec(
        required: [OpField("volumeKey", .string)],
        optional: [OpField("ordinal", .integer), OpField("title", .string), OpField("objective", .string), OpField("body", .string), OpField("state", .string)],
        description:
          #"objective is the goal the volume works towards; body holds the notes on it. A new volume always starts not_started; its state moves only through "goal met — start next"."#
      )
    case .volumeRemove:
      OpSpec(required: [OpField("volumeKey", .string)], optional: [], description: nil)
    case .briefUpdate:
      OpSpec(
        required: [OpField("chapter", .integer)],
        optional: [
          OpField("title", .string), OpField("body", .string), OpField("writeMode", .string), OpField("volumeKey", .string), OpField("contextRefs", .strings),
          OpField("pov", .nullableString), OpField("chapterPurpose", .string), OpField("readerValue", .strings), OpField("repetitionRisks", .nullableStrings),
          OpField("densityRisk", .nullableString), OpField("endingContract", .object), OpField("knowledgeContract", .nullableObject), OpField("direction", .nullableString),
          OpField("contentMode", .nullableString), OpField("scenes", .nullableObjects), OpField("claimedMilestones", .nullableStrings), OpField("isEnding", .boolean),
        ],
        description:
          #"direction is the agreed direction for the chapter; contentMode (standard | unrestricted, null = the project's) decides how it is written; scenes are [{"summary": <string>, "pov": <entity key or null>}]; claimedMilestones are the milestone keys the chapter reaches — each milestone is claimed by one plan at most; isEnding marks the planned final chapter, and only one plan may carry it. knowledgeContract.learns may name a fact only once the plan reaches its revealChapter and every term of its unlock holds for this plan (its own claimedMilestones and earlier plans' count as reached); an undated fact without an unlock cannot be revealed until it gets one. volumeKey names the volume whose goal the chapter serves; a new brief without one joins the volume of the nearest planned chapter before it. writeMode (one of: standard | external) governs batch selection: "external" halts the primary writer's batch at that chapter until it is finalized."#
      )
    case .briefRemove:
      OpSpec(required: [OpField("chapter", .integer)], optional: [], description: nil)
    case .draftUpdate:
      OpSpec(required: [OpField("chapter", .integer)], optional: [OpField("title", .string), OpField("body", .string), OpField("summary", .string)], description: nil)
    case .draftRemove:
      OpSpec(required: [OpField("chapter", .integer)], optional: [], description: nil)
    case .draftRewritePassage:
      OpSpec(
        required: [OpField("chapter", .integer), OpField("passage", .string), OpField("replacement", .string)],
        optional: [OpField("label", .string), OpField("contextIndex", .integer), OpField("anchor", .object)],
        description:
          #"rewrites one passage of a chapter draft and leaves every other word of the chapter as it is. passage is the exact text to replace, copied character for character from the draft or from a passage comment’s Quote lines without their indentation — never paraphrased, shortened or wrapped in quotation marks — and it must occur in the draft exactly once unless contextIndex names the passage comment it answers; replacement is the new text for exactly those words; label names the change in a few words ("the wrist injury"); contextIndex is the number of the passage comment it answers. Always a card the author applies passage by passage."#
      )
    case .entityUpsert:
      OpSpec(
        required: [OpField("entityKey", .string), OpField("type", .string)],
        optional: [OpField("name", .string), OpField("status", .string), OpField("motivation", .string), OpField("notes", .string), OpField("body", .string)], description: nil)
    case .entityRemove:
      OpSpec(required: [OpField("entityKey", .string)], optional: [], description: nil)
    case .factUpsert:
      OpSpec(
        required: [OpField("factKey", .string)],
        optional: [
          OpField("body", .string), OpField("subjects", .strings), OpField("constraintNote", .string), OpField("writerNote", .string), OpField("terms", .strings),
          OpField("revealChapter", .nullableInteger), OpField("unlock", .nullableObject), OpField("allowedClues", .nullableStrings),
        ], description: nil)
    case .factRemove:
      OpSpec(required: [OpField("factKey", .string)], optional: [], description: nil)
    case .milestoneUpsert:
      OpSpec(
        required: [OpField("milestoneKey", .string)], optional: [OpField("label", .string), OpField("subjectEntityKey", .nullableString), OpField("kind", .string)],
        description:
          "a story event a chapter plan claims to reach and a fact's unlock may name; label is required for a new milestone; subjectEntityKey is the character it concerns (null clears it); kind is one of: rank | event | learned_from | custom. Its state follows the plans and finalized chapters and cannot be set."
      )
    case .milestoneRemove:
      OpSpec(required: [OpField("milestoneKey", .string)], optional: [], description: "refused while a plan claims the milestone or a fact's unlock names it.")
    case .promiseCreate:
      OpSpec(
        required: [OpField("kind", .string), OpField("key", .string), OpField("label", .string)], optional: [OpField("openedChapter", .integer)],
        description: "kind is one of: thread | mystery — a promise is something the reader is waiting for. label is the thread's summary or the mystery's question.")
    case .promiseUpdate:
      OpSpec(
        required: [OpField("kind", .string), OpField("key", .string)], optional: [OpField("label", .string), OpField("lastAdvancedChapter", .integer), OpField("status", .string)],
        description:
          "status (open | paid_off) closes a promise as paid off or reopens it; dropping one uses promise.drop instead. lastAdvancedChapter records the chapter that last moved it forward."
      )
    case .promiseSetPayoff:
      OpSpec(
        required: [OpField("kind", .string), OpField("key", .string)],
        optional: [
          OpField("payoffMilestoneKey", .nullableString), OpField("payoffVolumeKey", .nullableString), OpField("payoffWindow", .nullableInteger), OpField("someday", .boolean),
          OpField("dormant", .boolean),
        ],
        description:
          "sets what a promise pays off by — a milestone, a volume, or a chapter number — and whether it is dormant on purpose (silences the obligations recap and the dormant-thread report). Omit a payoff field to leave it; pass null to clear just that one; someday: true clears all three deliberately, instead of leaving every field out."
      )
    case .promiseDrop:
      OpSpec(required: [OpField("kind", .string), OpField("key", .string)], optional: [], description: "gives up on a promise without deleting its record.")
    case .organiseRule:
      OpSpec(required: [OpField("rule", .string), OpField("optionId", .string)], optional: [], description: "a hard rule from the notes the author keeps as a Notebook direction.")
    case .actionGenerateChapter:
      OpSpec(required: [OpField("chapter", .integer)], optional: [], description: nil)
    case .actionAuditBible:
      OpSpec(required: [], optional: [], description: nil)
    case .actionEnhancePremise:
      OpSpec(required: [], optional: [OpField("overview", .string)], description: nil)
    case .actionJudgeDraft:
      OpSpec(required: [OpField("chapter", .integer)], optional: [], description: nil)
    case .actionReviseDraft:
      OpSpec(required: [OpField("chapter", .integer), OpField("note", .string)], optional: [], description: nil)
    case .actionApproveDraft:
      OpSpec(required: [OpField("chapter", .integer)], optional: [OpField("revision", .integer), OpField("saveSeq", .integer), OpField("draftId", .string)], description: nil)
    case .actionApplyContinuity:
      OpSpec(required: [OpField("chapter", .integer)], optional: [], description: nil)
    case .actionValidate:
      OpSpec(required: [OpField("scope", .string)], optional: [OpField("chapter", .integer)], description: nil)
    case .actionFinalize:
      OpSpec(required: [], optional: [OpField("upTo", .integer)], description: nil)
    case .actionOrganiseNotes:
      OpSpec(required: [], optional: [], description: nil)
    case .actionPlanChapter:
      OpSpec(required: [], optional: [OpField("chapter", .integer), OpField("intent", .string), OpField("direction", .string), OpField("empty", .boolean)], description: nil)
    case .actionAdvanceVolume:
      OpSpec(required: [OpField("volumeKey", .string)], optional: [], description: nil)
    }
  }

  // apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:152
  var spec: OpSpec {
    let declared = declaredSpec
    let metadata = [OpField("rationale", .string), OpField("quote", .string), OpField("ideaId", .string)] + (self == .briefUpdate ? [OpField("startedEmpty", .boolean)] : [])
    return OpSpec(required: declared.required, optional: declared.optional + metadata, description: declared.description)
  }

  fileprivate var serverStampedFields: [String] {
    switch self {
    case .actionApproveDraft: ["revision", "saveSeq", "draftId"]
    case .draftRewritePassage: ["anchor"]
    default: []
    }
  }

  fileprivate var isUnquoted: Bool { self == .draftRewritePassage }
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:160
func declaredOpFields(_ op: OpType) -> [String] {
  let spec = op.declaredSpec
  let stamped = op.serverStampedFields
  return (spec.required + spec.optional).map(\.name).filter { field in !stamped.contains { $0.jsEquals(field) } }
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:171
func isActionOp(_ op: OpType) -> Bool {
  op.isAction
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:186
func modelHiddenFields(_ op: OpType, _ options: OpVocabularyOptions) -> [String] {
  let quoted = options.quotes && !op.isAction && !op.isUnquoted
  return serverMetadataFields + op.serverStampedFields + (quoted ? [] : ["quote"])
}
