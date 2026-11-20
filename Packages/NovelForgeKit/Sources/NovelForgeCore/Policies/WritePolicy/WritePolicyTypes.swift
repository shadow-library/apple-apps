import ShadowText

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:8
enum OpSide: String, Sendable {
  case direct
  case card
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:10
enum WriteHold: String, CaseIterable, Sendable {
  case none
  case turn
  case writerRead = "writer_read"
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:11
enum CardReason: String, CaseIterable, Sendable {
  case justDiscussing = "just_discussing"
  case manualMode = "manual_mode"
  case heldForReview = "held_for_review"
  case alwaysCard = "always_card"
  case notAllowlisted = "not_allowlisted"
  case noQuote = "no_quote"
  case quoteNotFound = "quote_not_found"
  case tentative
  case removal
  case novelContent = "novel_content"
  case dependsOnCard = "depends_on_card"
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:23
enum AlwaysCardRule: String, CaseIterable, Sendable {
  case removal
  case action
  case plan
  case prose
  case plannerOnlyPage = "planner_only_page"
  case replacesStory = "replaces_story"
  case secretTruth = "secret_truth"
  case secretGating = "secret_gating"
  case volumeStructure = "volume_structure"
  case promiseDisposition = "promise_disposition"
  case promiseProgress = "promise_progress"
  case promiseReuse = "promise_reuse"
  case plannerOnlyField = "planner_only_field"
  case notebookDirection = "notebook_direction"
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:39
public enum OpSource: String, CaseIterable, Sendable {
  case quoted
  case idea
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:56
enum OpDisposition: Sendable, Equatable {
  case direct(index: Int, source: OpSource)
  case card(index: Int, reason: CardReason, rule: AlwaysCardRule?)

  var index: Int {
    switch self {
    case .direct(let index, _), .card(let index, _, _): index
    }
  }

  var side: OpSide {
    switch self {
    case .direct: .direct
    case .card: .card
    }
  }
}

/// The fields `loadCurrentRecords` reads for one existing record, as the reference's `Record<string, unknown>`: an absent key is `undefined`.
typealias WritePolicyRecordFields = OrderedJSONObject

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:58
struct WritePolicyState: Sendable {
  private let current: [JSString: WritePolicyRecordFields]
  /// Records that exist but this device cannot read: an op that writes or names one is always held for the author, and never counts as creating it.
  private let unreadable: Set<JSString>

  /// A ref listed twice keeps its last fields, as `new Map(entries)` does.
  init(current: [(ref: String, fields: WritePolicyRecordFields)] = [], unreadable: Set<JSString> = []) {
    var records: [JSString: WritePolicyRecordFields] = [:]
    for entry in current { records[JSString(entry.ref)] = entry.fields }
    self.current = records
    self.unreadable = unreadable
  }

  func has(_ ref: String) -> Bool {
    current[JSString(ref)] != nil || unreadable.contains(JSString(ref))
  }

  func touchesUnreadable(_ op: ChangeOp) -> Bool {
    (changeSetRefs([op]) + opReferences(op)).contains { unreadable.contains(JSString($0)) }
  }

  func fields(of ref: String?) -> WritePolicyRecordFields? {
    ref.flatMap { current[JSString($0)] }
  }
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:153
enum RefinementChatMode: String, CaseIterable, Sendable {
  case manual
  case auto
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:71
enum IdeaHandling: String, CaseIterable, Sendable {
  case apply
  case card
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:63
struct WritePolicyInput: Sendable {
  var ops: [ChangeOp]
  var authorMessage: String
  var vocabulary: String?
  var mode: RefinementChatMode
  var ideas: IdeaHandling?
  var justDiscussing: Bool
  var hold: WriteHold
  var state: WritePolicyState

  init(
    ops: [ChangeOp], authorMessage: String, vocabulary: String? = nil, mode: RefinementChatMode, ideas: IdeaHandling? = nil, justDiscussing: Bool = false, hold: WriteHold,
    state: WritePolicyState
  ) {
    self.ops = ops
    self.authorMessage = authorMessage
    self.vocabulary = vocabulary
    self.mode = mode
    self.ideas = ideas
    self.justDiscussing = justDiscussing
    self.hold = hold
    self.state = state
  }
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:77
struct ChangeSetSplit: Sendable, Equatable {
  let ops: [ChangeOp]
  let direct: [ChangeOp]
  let cards: [ChangeOp]
  let sources: [OpSource]
  let dispositions: [OpDisposition]
  let held: WriteHold
}
