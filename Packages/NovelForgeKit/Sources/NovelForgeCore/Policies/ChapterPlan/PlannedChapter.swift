struct PlannedChapter: Equatable, Sendable {
  var title: String
  var objective: String
  var scenes: [BriefScene]
  var continuesIntoNextChapter: Bool = false
  var startsFromPreviousChapter: Bool = false
  var handoffBeat: String?
  var endingContract: EndingContract
  var knowledgeContract: ChangeKnowledgeContract?
  var claimedMilestones: [String]?
  var chapterPurpose: String
  var readerValue: [String]
  var repetitionRisks: [String]?
  var densityRisk: String?
  var moves: String?
}

struct PlanFact: Equatable, Sendable {
  var factKey: String
  var revealChapter: Int?
  var unlock: UnlockCondition?
  var source: FactSource
  var terms: [String]
  var writerNote: String?

  var reveal: RevealFact { RevealFact(factKey: factKey, revealChapter: revealChapter, unlock: unlock, source: source) }
}

struct PlanMilestone: Equatable, Sendable {
  var milestoneKey: String
  var label: String
  var subjectEntityKey: String?
  var state: MilestoneState
}

struct VettedPlan: Equatable, Sendable {
  var chapter: Int
  var plan: PlannedChapter
  var moves: String?
  var claimedMilestones: [String]
  var droppedClaims: [String]
  var sanitised: [RevealViolation]
}
