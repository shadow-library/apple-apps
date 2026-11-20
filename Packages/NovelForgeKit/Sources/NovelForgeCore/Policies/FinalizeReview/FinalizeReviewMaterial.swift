import ShadowText

// apps/novel-forge-server/src/modules/ai/schemas/continuity.schema.ts:206, only the parts a finalize review reads; missing lists are empty.
struct FinalizeExtraction: Sendable {
  enum Confidence: String, Sendable {
    case high
    case low
  }

  struct Assessed<Value: Sendable>: Sendable {
    var value: Value
    var confidence: Confidence?

    init(_ value: Value, confidence: Confidence? = nil) {
      self.value = value
      self.confidence = confidence
    }
  }

  struct Milestone: Sendable {
    var milestoneKey: String
    var reached: Bool
    var evidence: String?
  }

  var appeared: [String] = []
  var newEntities: [ProposedChange.Entity] = []
  var threads: [Assessed<ProposedChange.PlotThread>] = []
  var mysteries: [Assessed<ProposedChange.Mystery>] = []
  var relationships: [Assessed<ProposedChange.Relationship>] = []
  var characterStates: [Assessed<ProposedChange.CharacterState>] = []
  var knowledgeChanges: [ProposedChange.Knowledge] = []
  var chapterSummary: String?
  var milestones: [Milestone] = []
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:40 without `bridgeOnly`: phase 7 reads no isolation bridges.
struct FinalizeReviewMaterial: Sendable {
  struct Milestone: Sendable {
    var milestoneKey: String
    var label: String
    var state: MilestoneState
  }

  struct Learn: Sendable {
    var entityKey: String
    var factKey: String
  }

  var extraction: FinalizeExtraction
  var isolated: Bool
  var claimedMilestones: [String]
  var milestones: [Milestone]
  var entityNames: [JSString: String]
  var closedThreads: Set<JSString>
  var resolvedMysteries: Set<JSString>
  var plannedLearns: [Learn]
  var plannedFactKeys: [String]
  var facts: [RevealFact]
  var unlock: UnlockContext
  var autoKeep: Set<FinalizeCategory>
}
