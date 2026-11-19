import Foundation
import ShadowAI
import ShadowCore

extension CheckSeverity: Codable {}
extension RepairMode: Codable {}
extension JudgeRoute: Codable {}
extension GenerationVerdict: Codable {}

/// generation.service.ts:282; regenerate asks with repairs on and no guidance (:272), capped by the graph's default (chapter-generation.graph.ts:66).
struct GenerationJobPayload: Equatable, Sendable {
  let guidance: String
  let autoFix: Bool
  let maxFixes: Int

  init(guidance: String = "", autoFix: Bool = true, maxFixes: Int = GenerationRouting.defaultMaxFixes) {
    self.guidance = guidance
    self.autoFix = autoFix
    self.maxFixes = maxFixes
  }

  var json: JSONValue { ["guidance": .string(guidance), "autoFix": .bool(autoFix), "maxFixes": .int(Int64(maxFixes))] }

  init(json: JSONValue) throws(GenerationJobError) {
    guard let members = json.objectValue, let guidance = members["guidance"]?.stringValue, case .bool(let autoFix)? = members["autoFix"],
      let maxFixes = members["maxFixes"]?.intValue.flatMap({ Int(exactly: $0) })
    else { throw .payload }
    self.init(guidance: guidance, autoFix: autoFix, maxFixes: maxFixes)
  }
}

/// Which part of the judge node a finding came from (chapter-generation.graph.ts:669-697): the stored pass is categorised by it, never by its text.
enum FindingSource: String, Codable, Sendable {
  case continuity
  case ending
  case brief
  case readability
  case knowledge
  case mechanics
}

struct SourcedFinding: Codable, Equatable, Sendable {
  let severity: CheckSeverity
  let text: String
  let source: FindingSource

  init(_ finding: GenerationFinding, source: FindingSource) {
    severity = finding.severity
    text = finding.text
    self.source = source
  }

  var finding: GenerationFinding { GenerationFinding(severity: severity, text: text) }
}

/// The fields of a fact the judge's blocks, leak scan and writer-safe leak lines read.
struct JudgeFact: Codable, Equatable, Sendable {
  let factKey: String
  let text: String
  let constraintNote: String?
  let writerNote: String?
  let terms: [String]?
  let source: FactSource?

  init(_ fact: DisclosureFact) {
    factKey = fact.factKey
    text = fact.text
    constraintNote = fact.constraintNote
    writerNote = fact.writerNote
    terms = fact.terms
    source = fact.source
  }

  var fact: DisclosureFact { DisclosureFact(factKey: factKey, text: text, constraintNote: constraintNote, writerNote: writerNote, terms: terms, source: source) }
}

/// A writer attempt's messages as sent, recorded in the transaction that saves the revision it produced (writer-snapshot.service.ts:76-86).
struct PendingSnapshot: Codable, Equatable, Sendable {
  let role: WriterAttemptRole
  let attempt: Int
  let messages: [WriterSnapshotMessage]
  let keptBack: JSONValue
  let bibleHash: String?
  let promptKey: String
  let promptVersion: String
  let route: WriterSnapshotRoute
  let isolated: Bool
}

struct GenerationJobState: Codable, Equatable, Sendable {
  struct Target: Codable, Equatable, Sendable {
    let min: Double
    let max: Double
    let aim: Double

    var resolved: ResolvedWordTarget { ResolvedWordTarget(min: min, max: max, aim: aim) }
  }

  /// What the judge reads from the plan and the knowledge ledger, unscrubbed: the judge sees the whole forbidden list (chapter-generation.graph.ts:634).
  struct JudgeInputs: Codable, Equatable, Sendable {
    let pov: String?
    let briefBody: String?
    let endingContract: JSONValue?
    let hidden: [JudgeFact]
    let readerKnows: [JudgeFact]

    var contract: ChapterEndingContract? { endingContract.flatMap(ChapterEndingContract.init(json:)) }
  }

  struct TitleChapter: Codable, Equatable, Sendable {
    let number: Int
    let title: String?
    let isolated: Bool
  }

  /// Read once by the pin step, so no later step reads the live store for it; the guidance is already scrubbed by the pack's policy.
  struct Pinned: Codable, Equatable, Sendable {
    let minorNames: [String]
    let unrestricted: Bool
    let pace: Pace
    let target: Target
    let guidance: String
    let autoFix: Bool
    let maxFixes: Int
    /// The draft's head when the run started; nil for a chapter with no live draft.
    let head: String?
    let judge: JudgeInputs
    let titles: [TitleChapter]
  }

  enum Phase: String, Codable, Sendable {
    case draft
    case rewrite
  }

  struct Expansion: Codable, Equatable, Sendable {
    let words: Int
    let passes: Int
    let initialWords: Int
    let stopped: Bool
  }

  struct Checks: Codable, Equatable, Sendable {
    let mechanical: [SourcedFinding]
    let readabilityEvidence: String?
  }

  struct JudgePass: Codable, Equatable, Sendable {
    let verdict: GenerationVerdict
    let findings: [SourcedFinding]
    let knowledgeWriterFindings: [SourcedFinding]
    /// A non-compliant ending or brief block that named no issue: the stored pass gets a line for it, the routing findings do not.
    let silent: [FindingSource]
    let endingCompliant: Bool
    let knowledgeCompliant: Bool
    let mechanicallyCompliant: Bool
    let briefCompliant: Bool
    let readabilityCompliant: Bool
    var route = JudgeRoute.awaitReview
    var calls: [UUID] = []
  }

  let pinned: Pinned
  var attempt = 0
  var repairMode = RepairMode.patch
  var phase = Phase.draft
  var title = ""
  var prose = ""
  var summary = ""
  var continuation: [String: JSONValue] = [:]
  /// The guidance the current phase's writer and its expansions read.
  var writerGuidance = ""
  var expansion: Expansion?
  /// How many revisions this attempt has saved; the next save is ordinal `saves`.
  var saves = 0
  /// The saved prose's own flag, which every later call routes by.
  var isolated = false
  var snapshots: [PendingSnapshot] = []
  var checks: Checks?
  var pass: JudgePass?
  var previousFindings: [SourcedFinding] = []

  init(pinned: Pinned) {
    self.pinned = pinned
    writerGuidance = pinned.guidance
  }

  var packOptions: WriterPackOptions {
    WriterPackOptions(permissive: pinned.unrestricted, minorNames: pinned.minorNames, enforceReservations: true)
  }

  var expansionState: DraftExpansionState? {
    expansion.map { DraftExpansionState(body: prose, words: $0.words, passes: $0.passes, initialWords: $0.initialWords, stopped: $0.stopped) }
  }

  mutating func expand(_ settled: DraftExpansionState) {
    prose = settled.body
    expansion = Expansion(words: settled.words, passes: settled.passes, initialWords: settled.initialWords, stopped: settled.stopped)
  }

  /// Another expansion pass while one is due (draft-expansion.ts:47), then the title an untitled draft asks for (chapter-generation.graph.ts:525), then the save.
  var afterWriting: GenerationStep {
    if let state = expansionState, DraftExpansion.nextRequest(state, target: pinned.target.resolved) != nil { return .expand }
    return phase == .draft && title.isEmpty ? .title : .save
  }

  var json: JSONValue {
    get throws(GenerationJobError) {
      guard let data = try? JSONEncoder().encode(self), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw .checkpoint }
      return json
    }
  }

  init(json: JSONValue) throws(GenerationJobError) {
    guard let state = try? JSONDecoder().decode(Self.self, from: CanonicalJSON.encode(json)) else { throw .checkpoint }
    self = state
  }
}
