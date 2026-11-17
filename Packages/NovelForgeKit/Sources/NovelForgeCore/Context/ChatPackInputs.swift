import ShadowCore

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:41
struct ChatPackStory: Codable, Equatable, Sendable {
  var title: String?
  var premise: String?
  var brief: String?
  var themes: [String]
  var theme: String?
  var endingQuestion: String?
  var ending: String?
  var readerPromise: String?
  var protagonistKey: String?
  var opposition: String?
  var authorInstructions: String?
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:46
struct ChatPackLedgerEntry: Codable, Equatable, Sendable {
  var kind: LedgerEntryKind
  var topic: String
  var statement: String
  var why: String?
  var rejectedAlternatives: [String]
  var writerLine: String?
  var decidedBy: LedgerDecidedBy
  var ideaId: String?
  var rejectionScope: LedgerRejectionScope?
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:48
struct ChatPackVolume: Codable, Equatable, Sendable {
  var volumeKey: String
  var ordinal: Int
  var title: String?
  var objective: String?
  var state: VolumeState
}

enum ChatPackPromiseKind: String, Codable, Sendable {
  case thread
  case mystery
}

/// A thread (`text` is its summary) or a mystery (`text` is its question); the reference types them apart, the chat renders them alike.
// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:49
struct ChatPackPromise: Codable, Equatable, Sendable {
  var kind: ChatPackPromiseKind
  var key: String
  var isOpen: Bool
  var text: String?
  var openedChapter: Int?
  var lastAdvancedChapter: Int?
  var payoffWindow: Int?
  var payoffMilestoneKey: String?
  var payoffVolumeKey: String?
  var intentionallyOpen: Bool
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:79
struct ChatPackEntity: Codable, Equatable, Sendable {
  var entityKey: String
  var name: String
  var type: String
  var isMajor: Bool
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:80
struct ChatPackPage: Codable, Equatable, Sendable {
  var section: String
  var slug: String
  var frontmatter: [String: JSONValue]?
}

/// `disclosedInChapter` is the chapter a final chapter first disclosed the secret in; nil while it is still a secret to the reader.
// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:81
struct ChatPackFact: Codable, Equatable, Sendable {
  var factKey: String
  var disclosedInChapter: Int?
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:83
struct ChatPackMilestone: Codable, Equatable, Sendable {
  var milestoneKey: String
  var label: String
  var state: MilestoneState
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:57
struct ChatPackChapter: Codable, Equatable, Sendable {
  var number: Int
  var title: String?
  var summary: String?
  var isolated: Bool
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:58
struct ChatPackDraft: Codable, Equatable, Sendable {
  var chapter: Int
  var title: String?
  var review: DraftReviewState
  var summary: String?
  var isolated: Bool
  var staleReason: String?
}

struct ChatPackScene: Codable, Equatable, Sendable {
  var summary: String
  var pov: String?
}

struct ChatPackEndingContract: Codable, Equatable, Sendable {
  var hookType: String?
  var emotionalBeat: String?
  var openQuestion: String?
  var handoffState: String?
}

/// `revision` is shown as given; the vault has no counter, so the caller says what a plan's revision reads as.
// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:59
struct ChatPackBrief: Codable, Equatable, Sendable {
  var chapter: Int
  var title: String?
  var chapterPurpose: String?
  var direction: String?
  var body: String
  var pov: String?
  var scenes: [ChatPackScene]
  var endingContract: ChatPackEndingContract?
  var claimedMilestones: [String]
  var contentMode: String?
  var isEnding: Bool
  var guidance: String?
  var revision: String
  var staleReason: String?
  var writeMode: BriefWriteMode
}

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts:529
struct ChatPackAwaitingAuthor: Codable, Equatable, Sendable {
  struct Asking: Codable, Equatable, Sendable {
    var chapter: Int
    var open: Int
  }

  var continuity: [Int]
  var asking: [Asking]
  var answered: [Int]

  static let none = ChatPackAwaitingAuthor(continuity: [], asking: [], answered: [])
}

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:868
struct ChatPackPipeline: Codable, Equatable, Sendable {
  struct Draft: Codable, Equatable, Sendable {
    var chapter: Int
    var review: DraftReviewState
  }

  var storyCurrentChapter: Int
  var drafts: [Draft]
  var staleBriefChapters: [Int]
  var pendingProposals: Int
  var awaiting: ChatPackAwaitingAuthor
}

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:924
struct ChatPackChanges: Codable, Equatable, Sendable {
  struct Volume: Codable, Equatable, Sendable {
    var volumeKey: String
    var revision: String
  }

  struct Brief: Codable, Equatable, Sendable {
    var chapter: Int
    var revision: String
  }

  struct Doc: Codable, Equatable, Sendable {
    var section: String
    var slug: String
    var revision: String
  }

  var volumes: [Volume]
  var briefs: [Brief]
  var docs: [Doc]
}

enum ChatPackProgressStatus: String, Codable, Sendable {
  case open
  case answered
  case undecided
  case dismissed
}

struct ChatPackProgressLine: Codable, Equatable, Sendable {
  var status: ChatPackProgressStatus
  var label: String
}

// apps/novel-forge-server/src/modules/ai/context/pack-render.ts:326
struct ChatPackEndingRow: Codable, Equatable, Sendable {
  var content: String?
  var summary: String?
  var isolated: Bool
}

// apps/novel-forge-server/src/modules/ai/context/pack-render.ts:327
struct ChatPackEndingDraft: Codable, Equatable, Sendable {
  var body: String?
  var summary: String?
  var isolated: Bool
  var staleReason: String?
}

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:753
struct ChatPackInputs: Codable, Equatable, Sendable {
  /// Nil when the novel has no record: the story and progress sections are then left out.
  var story: ChatPackStory?
  var progress: [ChatPackProgressLine]?
  /// The active entries, oldest first, with the rejections whose scope has lapsed already dropped.
  var ledger: [ChatPackLedgerEntry]
  var authorNotes: String?
  var volumes: [ChatPackVolume]
  var promises: [ChatPackPromise]
  var entities: [ChatPackEntity]
  var pages: [ChatPackPage]
  var facts: [ChatPackFact]
  var milestones: [ChatPackMilestone]
  var chapters: [ChatPackChapter]
  var drafts: [ChatPackDraft]
  var plannedChapters: [Int]
  /// The plans of the latest written chapter and of the next one; others are not read.
  var briefs: [ChatPackBrief]
  var latestChapter: ChatPackEndingRow?
  var latestDraft: ChatPackEndingDraft?
  var pipeline: ChatPackPipeline
  var changes: ChatPackChanges
}

extension ChatPackFact {
  /// A fault in the disclosure read model reads as nothing disclosed: the secret stays a secret.
  init(factKey: String, in disclosure: ReaderDisclosure) {
    self.init(factKey: factKey, disclosedInChapter: disclosure.chapter(of: factKey).value.flatMap { $0 })
  }
}

extension ChatPackProgressLine {
  init<ID>(_ item: ProgressItem<ID>) {
    self.init(status: ChatPackProgressStatus(rawValue: item.status.rawValue) ?? .dismissed, label: item.label)
  }
}
