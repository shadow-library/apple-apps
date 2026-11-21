import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

enum CanonRefreshError: ShadowError {
  case novelUnavailable
  case contentModeUnknown(String)
  case canonUnreadable(chapter: Int)
  case refsUnreadable([String])
  case reviewUnreadable(chapter: Int)
  case quoteRuleUnavailable
  case route(ChapterCallError)
  case call(JobStepCallError)
  case outputUnreadable
  case changeSet(ChangeSetError)
  case disclosure(DisclosureError)
  case unstorable
  case checkpointUnreadable
  case staging(ProposalStagingError)
  case store(StoreError)

  var code: String {
    switch self {
    case .novelUnavailable: "canon_refresh.novel_unavailable"
    case .contentModeUnknown: "canon_refresh.content_mode_unknown"
    case .canonUnreadable: "canon_refresh.canon_unreadable"
    case .refsUnreadable: "canon_refresh.refs_unreadable"
    case .reviewUnreadable: "canon_refresh.review_unreadable"
    case .quoteRuleUnavailable: "canon_refresh.quote_rule_unavailable"
    case .route(let error): error.code
    case .call(let error): error.code
    case .outputUnreadable: "canon_refresh.output_unreadable"
    case .changeSet(let error): error.code
    case .disclosure(let error): error.code
    case .unstorable: "canon_refresh.unstorable"
    case .checkpointUnreadable: "canon_refresh.checkpoint_unreadable"
    case .staging(let error): error.code
    case .store(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .novelUnavailable: "The novel cannot be read on this device, so its Story Bible cannot be refreshed."
    case .contentModeUnknown(let raw): "The novel's content mode \(raw) is not one this version knows, so the refresh is not routed."
    case .canonUnreadable(let chapter): "Chapter \(chapter)'s final text cannot be read on this device, so the Story Bible cannot be checked against it."
    case .refsUnreadable(let parts): "The story's \(parts.joined(separator: ", ")) cannot be read on this device, so the Story Bible cannot be checked whole."
    case .reviewUnreadable(let chapter): "Chapter \(chapter)'s finalize review cannot be read on this device, so what the author answered there is not known."
    case .quoteRuleUnavailable: "The quote check could not be built on this device."
    case .route(let error): error.errorDescription
    case .call(let error): error.errorDescription
    case .outputUnreadable: "The refresh's reply is not a list of updates."
    case .changeSet(let error): error.errorDescription
    case .disclosure(let error): error.errorDescription
    case .unstorable: "A change the refresh proposed holds a number or member names the vault cannot store exactly."
    case .checkpointUnreadable: "The report this attempt built cannot be read back."
    case .staging(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }
}

/// The canon refresh job (apps/novel-forge-server/src/modules/audit/chapter-canon-refresh.service.ts:68-161): one structured call over the Story Bible and the
/// finalized chapter whose report is checkpointed, then the report and its one bible_audit card written in the commit that ends the attempt. It never applies
/// anything, and a report already stored for the canon answers every later run.
enum RefreshPipeline {
  static let version = 1

  static let logger = Logger(category: "canon_refresh.pipeline")

  enum Step: String {
    case refresh
    case stage
  }

  static let definition = NovelPipelineDefinition.ready(
    NovelPipeline(
      version: version, first: Step.refresh.rawValue, steps: [Step.refresh.rawValue: RefreshStep(), Step.stage.rawValue: RefreshStageStep()],
      course: PipelineCourse([Step.refresh.rawValue, Step.stage.rawValue], tasks: [Step.refresh.rawValue: .review])))
}

/// Ids derived from the job (orchestrator decision 11): at most one card and one report per job, which two replicas may each have written.
enum RefreshRecords {
  static func card(of job: EntityRef) -> UUID { derived("refresh-card", job) }

  static func report(of job: EntityRef) -> UUID { derived("refresh-report", job) }

  private static func derived(_ purpose: String, _ job: EntityRef) -> UUID {
    derivedID("com.shadow.library.novelforgekit.\(purpose)", job.key.rawValue)
  }

  /// chapter-canon-refresh.service.ts:69-70 and :110-111, by canon: a report of the canon from any run or device, or one this version cannot read, which may be.
  static func refreshed<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, canonDigest: String, in transaction: borrowing Transaction
  ) throws(StoreError) -> Bool {
    let listing = try RefreshReportRecord.listing(novel: novel, chapter: chapter, in: transaction)
    return listing.unreadable > 0 || listing.records.contains { $0.canonDigest.utf8.elementsEqual(canonDigest.utf8) }
  }

  static func canonDigest<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws -> String? {
    try finalChapter(novel: novel, chapter: chapter, in: transaction)?.canonDigest
  }

  static func finalChapter<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws -> FinalChapterRecord? {
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
    switch try FinalChapterRecord.read(ref, in: transaction) {
    case .absent: return nil
    case .unreadable: throw CanonRefreshError.canonUnreadable(chapter: chapter)
    case .readable(let entry): return entry.record
    }
  }
}

struct RefreshCheckpoint: Sendable, Equatable {
  let findings: [[String: JSONValue]]
  let checked: [String: JSONValue]
  let copy: String
  let changeSet: [JSONValue]
  let baseline: ArtifactStates

  private enum Member: String {
    case findings
    case checked
    case copy
    case changeSet
    case baseline
  }

  init(findings: [[String: JSONValue]], checked: [String: JSONValue], copy: String, changeSet: [JSONValue], baseline: ArtifactStates) {
    self.findings = findings
    self.checked = checked
    self.copy = copy
    self.changeSet = changeSet
    self.baseline = baseline
  }

  init?(json: JSONValue) {
    guard let members = json.objectValue, let findings = members[Member.findings.rawValue]?.arrayValue?.map(\.objectValue),
      let checked = members[Member.checked.rawValue]?.objectValue, let copy = members[Member.copy.rawValue]?.stringValue,
      let changeSet = members[Member.changeSet.rawValue]?.arrayValue, let baseline = members[Member.baseline.rawValue].flatMap(ArtifactStates.init(json:)),
      findings.allSatisfy({ $0 != nil })
    else { return nil }
    self.init(findings: findings.compactMap { $0 }, checked: checked, copy: copy, changeSet: changeSet, baseline: baseline)
  }

  var json: JSONValue {
    [
      Member.findings.rawValue: .array(findings.map(JSONValue.object)), Member.checked.rawValue: .object(checked), Member.copy.rawValue: .string(copy),
      Member.changeSet.rawValue: .array(changeSet), Member.baseline.rawValue: baseline.json,
    ]
  }
}

struct RefreshStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let input = CanonRefreshJobInput(job: context.attempt.job, chapter: context.target.chapter)
    let (novel, chapter) = (context.target.novel, context.target.chapter)
    let done = AttemptStepOutput(state: .null, next: nil)
    let subject: RefreshSubject
    switch try await RefreshRead.read(context.store, novel: novel, chapter: chapter, canonDigest: input.canonDigest) {
    case .settled(let outcome):
      RefreshPipeline.logger.info("Canon refresh: nothing to read chapter=\(chapter, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
      return done
    case .subject(let read):
      subject = read
    }
    guard let report = try await RefreshCall.report(subject, in: context) else {
      RefreshPipeline.logger.info("Canon refresh: unchanged chapter=\(chapter, privacy: .public)")
      return done
    }
    return AttemptStepOutput(state: report.json, next: RefreshPipeline.Step.stage.rawValue)
  }
}

struct RefreshStageStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let input = CanonRefreshJobInput(job: context.attempt.job, chapter: context.target.chapter)
    guard let checkpoint = RefreshCheckpoint(json: state) else { throw CanonRefreshError.checkpointUnreadable }
    let (job, target, attempt) = (context.attempt.job.ref, context.target, context.attempt.attempt)
    return AttemptStepOutput(state: .null, next: nil) { transaction in
      try RefreshStage.write(checkpoint, canonDigest: input.canonDigest, job: job, novel: target.novel, chapter: target.chapter, attempt: attempt, in: &transaction)
    }
  }
}

enum RefreshStage {
  /// chapter-canon-refresh.service.ts:108-146: nothing when the canon was refreshed meanwhile or no longer stands; else the card (when the change-set holds an op)
  /// and the report that names it.
  static func write(
    _ checkpoint: RefreshCheckpoint, canonDigest: String, job: EntityRef, novel: UUID, chapter: Int, attempt: AttemptID, in transaction: inout WriteTransaction
  ) throws {
    guard try RefreshRecords.canonDigest(novel: novel, chapter: chapter, in: transaction)?.utf8.elementsEqual(canonDigest.utf8) == true,
      try !RefreshRecords.refreshed(novel: novel, chapter: chapter, canonDigest: canonDigest, in: transaction)
    else { return }
    let card = checkpoint.changeSet.isEmpty ? nil : RefreshRecords.card(of: job)
    if let card, case .absent = try ProposalRecord.read(id: card, in: transaction) {
      try stageCard(checkpoint, id: card, job: job, novel: novel, in: &transaction)
    }
    let report = RefreshReportRecord(
      id: RefreshRecords.report(of: job), novel: novel, chapter: chapter, canonDigest: canonDigest, findings: checkpoint.findings, checked: checkpoint.checked,
      copy: checkpoint.copy, proposal: card, attempt: attempt)
    _ = try report.append(in: &transaction)
  }

  // chapter-canon-refresh.service.ts:112-128
  private static func stageCard(_ checkpoint: RefreshCheckpoint, id: UUID, job: EntityRef, novel: UUID, in transaction: inout WriteTransaction) throws {
    let changeSet: ValidatedChangeSet
    do {
      changeSet = try ValidatedChangeSet(
        .array(checkpoint.changeSet.map(OrderedJSON.init)), allowedOps: canonRefreshOps, options: ChangeSetValidationOptions(entityMaterialization: false))
    } catch {
      throw CanonRefreshError.changeSet(error)
    }
    var input = ProposalStagingInput(novel: novel, kind: .bibleAudit, summary: checkpoint.copy.jsSlice(0, 300), changeSet: changeSet, run: job.key.rawValue)
    input.baseline = checkpoint.baseline
    do {
      _ = try ProposalStager.stage(input, id: id, in: &transaction)
    } catch {
      throw CanonRefreshError.staging(error)
    }
  }
}
