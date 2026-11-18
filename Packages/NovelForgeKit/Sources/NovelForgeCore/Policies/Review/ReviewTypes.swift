// apps/novel-forge-server/src/modules/review/review-findings.ts:13
struct DraftFinding: Equatable, Sendable {
  var severity: ReviewFindingSeverity
  var category: ReviewFindingCategory
  var text: String
  var evidence: String?

  init(severity: ReviewFindingSeverity, category: ReviewFindingCategory, text: String, evidence: String? = nil) {
    self.severity = severity
    self.category = category
    self.text = text
    self.evidence = evidence
  }
}

struct ReviewCompliance: Equatable, Sendable {
  var compliant: Bool
  var issues: [String]
}

// apps/novel-forge-server/src/modules/review/review-findings.ts:20
struct ReviewOutcome: Equatable, Sendable {
  var disposition = ChapterReviewDisposition.clear
  var verdict: String?
  var note: String?
  var findings: [ReviewFinding] = []
  var checked: [String] = []
  var briefCompliance: ReviewCompliance?
  var readabilityCompliance: ReviewCompliance?
  var endingCompliance: ReviewCompliance?
  var knowledgeCompliance: ReviewCompliance?
  var metrics: [String: Double]?
}

// apps/novel-forge-server/src/modules/review/review-findings.ts:33
struct ReviewedText: Equatable, Sendable {
  var draftRevision: String?
  var bodyHash: String

  init(draftRevision: String?, bodyHash: String) {
    self.draftRevision = draftRevision
    self.bodyHash = bodyHash
  }

  init(draftRevision: String?, body: String) {
    self.init(draftRevision: draftRevision, bodyHash: hashReviewedBody(body))
  }
}

// apps/novel-forge-server/src/modules/ai/schemas/judge.schema.ts:10
enum JudgeSeverity: String, Sendable {
  case hard
  case soft
}

struct JudgeOutputFinding: Equatable, Sendable {
  var severity: JudgeSeverity
  var text: String
}

// apps/novel-forge-server/src/modules/ai/schemas/judge.schema.ts:60
struct JudgeOutput: Equatable, Sendable {
  var verdict: String
  var findings: [JudgeOutputFinding]
  var endingCompliance: ReviewCompliance?
  var knowledgeCompliance: ReviewCompliance?
  var briefCompliance: ReviewCompliance?
  var readabilityCompliance: ReviewCompliance?

  init(
    verdict: String, findings: [JudgeOutputFinding] = [], endingCompliance: ReviewCompliance? = nil, knowledgeCompliance: ReviewCompliance? = nil,
    briefCompliance: ReviewCompliance? = nil, readabilityCompliance: ReviewCompliance? = nil
  ) {
    self.verdict = verdict
    self.findings = findings
    self.endingCompliance = endingCompliance
    self.knowledgeCompliance = knowledgeCompliance
    self.briefCompliance = briefCompliance
    self.readabilityCompliance = readabilityCompliance
  }
}

// apps/novel-forge-server/src/modules/review/review-findings.ts:38
struct JudgeEvidence: Sendable {
  var output: JudgeOutput?
  var hasBrief: Bool
  var hasEndingContract: Bool
  var lockedFromReader: [DisclosureFact]
  var hiddenFromCast: [DisclosureFact]
  var leaks: [KnowledgeLeakIssue]
}

// apps/novel-forge-server/src/modules/ai/schemas/enums.ts:9
enum ReviewOutputDisposition: String, Sendable {
  case approve
  case revisionRequested = "revision_requested"
}

// apps/novel-forge-server/src/modules/ai/schemas/enums.ts:8
enum EditorialSeverity: String, Sendable {
  case blocking
  case suggestion
}

struct EditorialFinding: Equatable, Sendable {
  var severity: EditorialSeverity
  var text: String
  var evidence: String?
}

// apps/novel-forge-server/src/modules/ai/schemas/enums.ts:10
enum ProofreadKind: String, CaseIterable, Sendable {
  case grammar
  case spelling
  case punctuation
  case tense
  case pov
  case name
  case reference
}

struct ProofreadSlip: Equatable, Sendable {
  var kind: ProofreadKind
  var quote: String
  var fix: String
  var reason: String?
}

// apps/novel-forge-server/src/modules/ai/schemas/review.schema.ts:33
struct ReviewOutput: Equatable, Sendable {
  var disposition: ReviewOutputDisposition
  var note: String?
  var findings: [EditorialFinding]?
  var proofreading: [ProofreadSlip]?

  init(disposition: ReviewOutputDisposition, note: String? = nil, findings: [EditorialFinding]? = nil, proofreading: [ProofreadSlip]? = nil) {
    self.disposition = disposition
    self.note = note
    self.findings = findings
    self.proofreading = proofreading
  }
}
