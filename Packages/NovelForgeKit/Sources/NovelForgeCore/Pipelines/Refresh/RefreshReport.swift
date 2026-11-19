import ShadowCore

/// apps/novel-forge-server/src/database/schemas/jobs.ts:9, as a chapter's refresh groups its findings: it never finds a contradiction and never removes.
enum RefreshGroup: String, CaseIterable, Sendable {
  case add
  case revise

  // apps/novel-forge-server/src/modules/audit/bible-audit-report.ts:45-50
  var label: String {
    switch self {
    case .add: "to add"
    case .revise: "to revise"
    }
  }
}

// jobs.ts:11-16
struct RefreshEvidence: Sendable, Equatable {
  let ref: String
  /// Copied verbatim from what the refresh read of `ref`; nil when the model's quote was not found there.
  let quote: String?
}

// jobs.ts:18-29
struct RefreshFinding: Sendable, Equatable {
  let id: String
  let group: RefreshGroup
  let ref: String
  let text: String
  let evidence: [RefreshEvidence]
  let opIndexes: [Int]
  let withheld: String?

  var json: [String: JSONValue] {
    [
      "id": .string(id), "group": .string(group.rawValue), "ref": .string(ref), "text": .string(text),
      "evidence": .array(evidence.map { ["ref": .string($0.ref), "quote": $0.quote.map(JSONValue.string) ?? .null] }),
      "opIndexes": .array(opIndexes.map { .int(Int64($0)) }), "withheld": withheld.map(JSONValue.string) ?? .null,
    ]
  }
}

/// One entry of the model's `updates` (chapter-canon-refresh.schema.ts:13-25).
struct RefreshUpdate: Sendable {
  let finding: String
  let evidence: [(ref: String, quote: String)]
  let changeSet: OrderedJSON?

  /// The updates of a reply that passed the schema; nil when it is not one.
  static func updates(in output: OrderedJSON) -> [RefreshUpdate]? {
    guard let updates = output.objectValue?["updates"]?.arrayValue else { return nil }
    var read = [RefreshUpdate]()
    for update in updates {
      guard let fields = update.objectValue, let finding = fields["finding"]?.stringValue, let evidence = fields["evidence"]?.arrayValue else { return nil }
      var pairs = [(ref: String, quote: String)]()
      for item in evidence {
        guard let ref = item.objectValue?["ref"]?.stringValue, let quote = item.objectValue?["quote"]?.stringValue else { return nil }
        pairs.append((ref, quote))
      }
      read.append(RefreshUpdate(finding: finding, evidence: pairs, changeSet: fields["changeSet"]))
    }
    return read
  }
}

/// A truth the reader has not been told, as `secretRisk` reads it (knowledge-view.ts FactLike).
struct RefreshSecret: Sendable, Equatable {
  let text: String
  let terms: [String]?
}

struct RefreshReportInput: Sendable {
  let updates: [RefreshUpdate]
  /// `chapter:<n>`: the label the finalized chapter was read under.
  let chapterRef: String
  let sources: [JSString: String]
  /// Refs read only in part: a rewrite written from the part would drop the rest.
  let partial: Set<JSString>
  let existingRefs: Set<JSString>
  /// The fields of each page and record as the refresh read them, by ref, named as the ops name them.
  let current: [JSString: [String: OrderedJSON]]
  let secrets: [RefreshSecret]
}

struct BuiltRefreshReport: Sendable, Equatable {
  let findings: [RefreshFinding]
  /// The one change-set the report stages as a card; every finding's `opIndexes` point into it.
  let changeSet: [ChangeOp]
}

// bible-audit-report.ts:36-41
enum RefreshWithheld {
  static let secret = "The suggested fix would write a secret the reader has not been told into a page or record the chapter writer reads, so no card was staged for it."
  static let collision = "Another finding already changes this page or record, so this change was not staged — keep that finding or run the audit again."
  static let planPage = "This page holds the author’s plans, not what the story has established, so a chapter’s refresh never changes it."
  static let newRecord = "New records come from the chapter’s finalize review, so this refresh does not add one."
  static let unread = "This page or record was too long to read whole, so a rewrite of it would lose what was not read — update it yourself."
}

struct RefreshReportBuilder {
  // bible-audit-report.ts:51-56
  private static let minTruthTokens = 3
  private static let truthOverlap = 0.75
  private static let keyFields: Set<JSString> = ["op", "section", "slug", "entityKey", "type", "factKey"]
  private static let sentenceBreak = ProseRegex.literal(#"(?<=[.!?。！？]["'”’)\]]*)\s+|\n+"#)

  let rule: QuoteRule

  /// bible-audit-report.ts:241-266: an update stands only on the chapter's own words found in the chapter, and its ops reach the card only when they change a page
  /// or record the refresh read whole, never a plan page and never a new record.
  func build(_ input: RefreshReportInput) throws -> BuiltRefreshReport {
    var stager = Stager(input: input, builder: self)
    var drafts = [(group: RefreshGroup, ref: String, text: String, evidence: [RefreshEvidence], staged: (opIndexes: [Int], withheld: String?))]()
    for update in input.updates {
      let evidence = evidence(update.evidence, sources: input.sources)
      guard evidence.contains(where: { $0.ref.jsEquals(input.chapterRef) && $0.quote != nil }) else { continue }
      let ops = try parseOptionalChangeSet(update.changeSet, allowedOps: canonRefreshOps, options: ChangeSetValidationOptions(entityMaterialization: false))
      guard let first = ops.first else { continue }
      let ref = Self.ref(of: first)
      let group: RefreshGroup = input.existingRefs.contains(JSString(ref)) ? .revise : .add
      drafts.append((group, ref, update.finding, evidence, try stager.stageAll(ops)))
    }
    // bible-audit-report.ts:198-200
    let ordered = RefreshGroup.allCases.flatMap { group in drafts.filter { $0.group == group } }
    let findings = ordered.enumerated().map { index, draft in
      RefreshFinding(
        id: "f\(index + 1)", group: draft.group, ref: draft.ref, text: draft.text, evidence: draft.evidence, opIndexes: draft.staged.opIndexes,
        withheld: draft.staged.withheld)
    }
    return BuiltRefreshReport(findings: findings, changeSet: stager.changeSet)
  }

  // bible-audit-report.ts:125-136
  private func evidence(_ quoted: [(ref: String, quote: String)], sources: [JSString: String]) -> [RefreshEvidence] {
    var seen = Set<JSString>()
    return quoted.compactMap { item in
      guard let source = sources[JSString(item.ref)] else { return nil }
      let verified = rule.quoteFoundIn(item.quote, source) ? item.quote : nil
      guard seen.insert(JSString("\(item.ref)\u{0}\(verified ?? "")")).inserted else { return nil }
      return RefreshEvidence(ref: item.ref, quote: verified)
    }
  }

  // bible-audit-report.ts:246-252
  fileprivate func guarded(_ op: ChangeOp, _ input: RefreshReportInput) -> String? {
    if case .bibleDocumentUpsert(let doc) = op.operation, isWriterExcludedBibleDoc(BibleDocAddress(section: doc.section.rawValue, slug: doc.slug)) {
      return RefreshWithheld.planPage
    }
    let ref = JSString(Self.ref(of: op))
    if case .entityUpsert = op.operation, !input.existingRefs.contains(ref) { return RefreshWithheld.newRecord }
    if input.existingRefs.contains(ref), input.partial.contains(ref) || input.sources[ref] == nil { return RefreshWithheld.unread }
    return nil
  }

  /// bible-audit-report.ts:111-123 for the two ops a refresh stages: an op adds a secret where the chapter writer reads it (a give-away term, the truth quoted,
  /// or most of its words in one sentence). Only what the fix adds counts, so correcting a page that already names a secret is not held against it.
  fileprivate func secretRisk(_ op: ChangeOp, secrets: [RefreshSecret], current: [String: OrderedJSON]?) throws -> String? {
    let fields = op.fields
    let after = Self.writerVisibleText(op) { fields[$0] }
    guard !after.jsTrim().isEmpty else { return nil }
    let before = Self.writerVisibleText(op) { field in fields[field] == nil || Self.keyFields.contains(JSString(field)) ? fields[field] : current?[field] }
    for secret in secrets where try addsSecret(secret, after: after, before: before) { return RefreshWithheld.secret }
    return nil
  }

  // bible-audit-report.ts:105-109
  private func addsSecret(_ secret: RefreshSecret, after: String, before: String) throws -> Bool {
    for term in secret.terms ?? [] where try Self.termCount(term, after) > Self.termCount(term, before) { return true }
    if rule.quoteFoundIn(secret.text, after) && !rule.quoteFoundIn(secret.text, before) { return true }
    return addedSentences(after, before).contains { restatesTruth(secret, $0) }
  }

  // bible-audit-report.ts:82-85
  private func addedSentences(_ after: String, _ before: String) -> [String] {
    let existing = Set(Self.sentences(of: before).map { JSString(rule.normaliseForQuote($0)) })
    return Self.sentences(of: after).filter { !existing.contains(JSString(rule.normaliseForQuote($0))) }
  }

  // bible-audit-report.ts:93-98
  private func restatesTruth(_ secret: RefreshSecret, _ sentence: String) -> Bool {
    let truth = Set(rule.contentTokens(secret.text))
    guard truth.count >= Self.minTruthTokens else { return false }
    let written = Set(rule.contentTokens(sentence))
    return Double(truth.filter(written.contains).count) / Double(truth.count) >= Self.truthOverlap
  }

  // bible-audit-report.ts:75-80
  private static func sentences(of text: String) -> [String] {
    text.jsSplit(sentenceBreak).map { $0.jsTrim() }.filter { !$0.isEmpty }
  }

  // bible-audit-report.ts:87-90
  private static func termCount(_ term: String, _ text: String) throws(DisclosureError) -> Int {
    guard let pattern = try revealTermPattern(term, global: true) else { return 0 }
    return text.jsMatchAll(pattern).count
  }

  // bible-audit-report.ts:68-73, for the two ops a refresh stages; `value` reads a field of the op, or what it holds before the fix.
  private static func writerVisibleText(_ op: ChangeOp, _ value: (String) -> OrderedJSON?) -> String {
    switch op.operation {
    case .bibleDocumentUpsert(let doc):
      isWriterExcludedBibleDoc(BibleDocAddress(section: doc.section.rawValue, slug: doc.slug)) ? "" : text(of: ["body", "frontmatter"].map(value))
    case .entityUpsert: text(of: ["name", "status", "motivation", "notes", "body"].map(value))
    default: ""
    }
  }

  // bible-audit-report.ts:60-65, over a list whose absent members read as undefined
  private static func text(of values: [OrderedJSON?]) -> String {
    values.map { $0.map(text) ?? "" }.joined(separator: "\n")
  }

  private static func text(_ value: OrderedJSON) -> String {
    switch value {
    case .string(let text): text
    case .array(let items): items.map(text).joined(separator: "\n")
    case .object(let object): object.entries.map { text($0.value) }.joined(separator: "\n")
    default: ""
    }
  }

  // bible-audit-report.ts:159-161
  static func ref(of op: ChangeOp) -> String {
    changeSetRefs([op]).first ?? op.type.rawValue
  }

  // bible-audit-report.ts:163-171
  fileprivate static func canonical(_ value: OrderedJSON) -> String {
    switch value {
    case .array(let items): "[\(items.map(canonical).joined(separator: ","))]"
    case .object(let object):
      "{\(object.keys.jsSorted().map { "\($0):\(canonical(object[$0] ?? .null))" }.joined(separator: ","))}"
    default: value.jsonText
    }
  }
}

/// bible-audit-report.ts:178-196: a single change-set every finding points into; an op that risks a secret, or that would change a record another finding already
/// changes differently, stays off the card and its finding says why.
private struct Stager {
  let input: RefreshReportInput
  let builder: RefreshReportBuilder
  private(set) var changeSet = [ChangeOp]()
  private var indexByRef = [JSString: Int]()

  init(input: RefreshReportInput, builder: RefreshReportBuilder) {
    self.input = input
    self.builder = builder
  }

  private enum Outcome {
    case index(Int)
    case withheld(String)
  }

  private mutating func stage(_ op: ChangeOp) throws -> Outcome {
    let ref = JSString(RefreshReportBuilder.ref(of: op))
    if let risk = try builder.guarded(op, input) ?? builder.secretRisk(op, secrets: input.secrets, current: input.current[ref]) { return .withheld(risk) }
    if let existing = indexByRef[ref] {
      let same = RefreshReportBuilder.canonical(.object(changeSet[existing].fields)).jsEquals(RefreshReportBuilder.canonical(.object(op.fields)))
      return same ? .index(existing) : .withheld(RefreshWithheld.collision)
    }
    changeSet.append(op)
    indexByRef[ref] = changeSet.count - 1
    return .index(changeSet.count - 1)
  }

  mutating func stageAll(_ ops: [ChangeOp]) throws -> (opIndexes: [Int], withheld: String?) {
    var indexes = [Int]()
    var reasons = [String]()
    for op in ops {
      switch try stage(op) {
      case .index(let index): if !indexes.contains(index) { indexes.append(index) }
      case .withheld(let reason): reasons.append(reason)
      }
    }
    let unique = reasons.jsUnique()
    return (indexes, unique.isEmpty ? nil : unique.joined(separator: " "))
  }
}

// bible-audit-report.ts:268-276; a refresh with no finding stores no report, so only the counted form is reached.
func renderRefreshSummary(_ findings: [RefreshFinding], checkedCopy: String) -> String {
  let counts = RefreshGroup.allCases.compactMap { group -> String? in
    let count = findings.count { $0.group == group }
    return count > 0 ? "\(count) \(group.label)" : nil
  }
  return "\(findings.count) \(findings.count == 1 ? "finding" : "findings"): \(counts.joined(separator: ", ")). \(checkedCopy)"
}
