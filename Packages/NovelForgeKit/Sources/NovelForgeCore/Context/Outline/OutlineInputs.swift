import ShadowCore

struct ChapterSpan: Equatable, Sendable {
  var start: Int
  var end: Int
}

enum OutlineVolumeSelection: Equatable, Sendable {
  case nearest
  case key(String?)
}

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:65 (OutlinePackOptions)
struct OutlineRequest: Equatable, Sendable {
  var chapter: Int
  var budgetTokens = OutlinePack.budget
  var span: ChapterSpan?
  var insertAfter: Int?
  var volume = OutlineVolumeSelection.nearest
  var readsIsolatedRaw = false

  init(
    chapter: Int, budgetTokens: Int = OutlinePack.budget, span: ChapterSpan? = nil, insertAfter: Int? = nil, volume: OutlineVolumeSelection = .nearest,
    readsIsolatedRaw: Bool = false
  ) {
    self.chapter = chapter
    self.budgetTokens = budgetTokens
    self.span = span
    self.insertAfter = insertAfter
    self.volume = volume
    self.readsIsolatedRaw = readsIsolatedRaw
  }

  var planSpan: ChapterSpan { span ?? ChapterSpan(start: chapter, end: chapter) }
}

struct OutlineChapter: Equatable, Sendable {
  var number: Int
  var title: String?
  var summary: String?
  var isolated: Bool
}

struct OutlineEntity: Equatable, Sendable {
  var entityKey: String
  var type: String
  var status: String?
  var body: String?
  var notes: String?
  var isMajor: Bool
}

struct OutlineFact: Equatable, Sendable {
  var factKey: String
  var text: String
  var revealChapter: Int?
  var unlock: UnlockCondition?
  var source: FactSource
  var terms: [String]
  var writerNote: String?
  var revealed: Bool

  var planFact: PlanFact {
    PlanFact(factKey: factKey, revealChapter: revealChapter, unlock: unlock, source: source, terms: terms, writerNote: writerNote)
  }
}

struct OutlineDocument: Equatable, Sendable {
  var section: String
  var slug: String
  var frontmatter: [String: JSONValue]?
  var body: String?
}

struct OutlineVolume: Equatable, Sendable {
  var volumeKey: String
  var ordinal: Int
  var title: String?
  var objective: String?
  var state: VolumeState
}

struct OutlinePromise: Equatable, Sendable {
  var kind: PromiseKind
  var key: String
  var text: String?
  var openedChapter: Int?
  var isOpen: Bool
  var intentionallyOpen: Bool
  var lastAdvancedChapter: Int?
  var payoff: PromisePayoff

  var planPromise: PlanPromise {
    PlanPromise(
      kind: kind, key: key, text: text, isOpen: isOpen, intentionallyOpen: intentionallyOpen, openedChapter: openedChapter, lastAdvancedChapter: lastAdvancedChapter, payoff: payoff
    )
  }
}

struct OutlineMilestone: Equatable, Sendable {
  var milestoneKey: String
  var label: String
  var subjectEntityKey: String?
  var state: MilestoneState

  var planMilestone: PlanMilestone { PlanMilestone(milestoneKey: milestoneKey, label: label, subjectEntityKey: subjectEntityKey, state: state) }
}

struct OutlineNeighbour: Equatable, Sendable {
  var chapter: Int
  var title: String?
  var body: String
}

struct OutlinePlanSlot: Equatable, Sendable {
  var volumeKey: String?
  var isEnding: Bool
}

// The rows context-assembler.service.ts:587-679 and catalog.service.ts:182-265 read, as the vault holds them.
struct OutlineWorld: Equatable, Sendable {
  var chapters: [OutlineChapter]
  var previous: WriterEndingRow?
  var previousDraft: WriterEndingDraft?
  var volumes: [OutlineVolume]
  var entities: [OutlineEntity]
  var threads: [OutlinePromise]
  var mysteries: [OutlinePromise]
  var facts: [OutlineFact]
  var documents: [OutlineDocument]
  var ledger: [ChatPackLedgerEntry]
  var planWorld: PlanWorld
  var milestones: [OutlineMilestone]
  var characters: [String]
  var slot: OutlinePlanSlot?
  var previousEnding: PlanEnding?
  var neighbours: [OutlineNeighbour]
  var minorNames: [String]
}
