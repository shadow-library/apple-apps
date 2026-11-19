import Foundation
import GRDB
import OSLog
import ShadowCore
import ShadowJobs
import ShadowStore

public enum ChapterPlanError: ShadowError {
  case notNextChapter(chapter: Int, next: Int)
  case alreadyPlanned(chapter: Int)
  case outOfDate(chapter: Int, next: Int)
  case anotherPlanRunning(chapter: Int)
  case chapterBeingWritten(chapter: Int)
  /// The chapters' or the jobs' derived state is faulted here, so which chapter is next, or which plan is running, is not known.
  case chaptersUnavailable
  case jobsUnavailable
  case steeringUnavailable
  case engine(JobEngineError)
  case store(StoreError)

  // apps/novel-forge-server/src/classes/app-error-code.ts:40-43
  public var code: String {
    switch self {
    case .notNextChapter: "PLN_006"
    case .alreadyPlanned: "PLN_007"
    case .outOfDate: "PLN_008"
    case .anotherPlanRunning: "PLN_009"
    case .chapterBeingWritten: "JOB_002"
    case .chaptersUnavailable: "chapters.lifecycle_unavailable"
    case .jobsUnavailable: "plan.jobs_unavailable"
    case .steeringUnavailable: "plan.steering_unavailable"
    case .engine(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notNextChapter(let chapter, let next): "Only the next chapter can be planned — that is chapter \(next), not chapter \(chapter)"
    case .alreadyPlanned(let chapter): "Chapter \(chapter) already has a plan — edit it instead"
    case .outOfDate(let chapter, let next): "The plan for chapter \(chapter) is out of date — the story has moved on to chapter \(next); plan again"
    case .anotherPlanRunning(let chapter): "A plan for chapter \(chapter) is already being made — wait for it or cancel it"
    case .chapterBeingWritten: "A chapter is being written, planned or finalized for this novel — wait for it to finish or cancel it, then try again"
    case .chaptersUnavailable: "The novel's chapters cannot be read on this device just now, so which chapter comes next is not known."
    case .jobsUnavailable: "The novel's jobs cannot be read on this device just now, so whether a plan is already being made is not known."
    case .steeringUnavailable: "The author's words could not be checked against the plan's intent on this device."
    case .engine(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }
}

/// The card a plan was asked for from: the reference's action context (action-jobs.ts:27-30).
public struct ChapterPlanOrigin: Sendable, Equatable {
  public var session: UUID
  public var message: UUID?
  public var proposal: UUID
  public var opIndex: Int

  public init(session: UUID, message: UUID?, proposal: UUID, opIndex: Int) {
    self.session = session
    self.message = message
    self.proposal = proposal
    self.opIndex = opIndex
  }
}

public enum ChapterPlanSteer: Sendable, Equatable {
  case none
  /// Words the author wrote for this plan themselves, read as their intent unless they hedge it.
  case author(String)
  /// What a chat card asked for: its intent holds only where the author's own messages in that chat state it (plan-job.service.ts:96).
  case card(intent: String?, direction: String?, origin: ChapterPlanOrigin)
}

public struct ChapterPlanJobRequest: Sendable, Equatable {
  public var novel: UUID
  /// Nil plans the next writable chapter.
  public var chapter: Int?
  public var steer: ChapterPlanSteer
  /// An empty plan for the author to fill in: no model call, and only for a chapter with no plan yet.
  public var empty: Bool

  public init(novel: UUID, chapter: Int? = nil, steer: ChapterPlanSteer = .none, empty: Bool = false) {
    self.novel = novel
    self.chapter = chapter
    self.steer = steer
    self.empty = empty
  }
}

public struct ChapterPlanReceipt: Sendable, Equatable {
  public let job: JobKey
  public let chapter: Int
  /// The same plan was already queued or running; `job` names it.
  public let deduped: Bool
  /// An intent the author's messages do not state, left out for the direction they chose.
  public let droppedIntent: String?
}

/// What a plan job plans: the payload holds this alone, the origin rides beside it (plan-job.service.ts:117-123).
struct PlanJobInput: Sendable, Equatable {
  var chapter: Int
  var intent: String?
  var direction: String?
  var empty: Bool

  private enum Member: String {
    case chapter
    case intent
    case direction
    case empty
  }

  init(chapter: Int, intent: String?, direction: String?, empty: Bool) {
    self.chapter = chapter
    self.intent = intent.flatMap(PlanJobInput.trimmed)
    self.direction = direction.flatMap(PlanJobInput.trimmed)
    self.empty = empty
  }

  init(payload: JSONValue, chapter: Int) {
    let members = payload.objectValue ?? [:]
    self.init(
      chapter: chapter, intent: members[Member.intent.rawValue]?.stringValue, direction: members[Member.direction.rawValue]?.stringValue,
      empty: members[Member.empty.rawValue]?.boolValue ?? false)
  }

  var payload: JSONValue {
    var members: [String: JSONValue] = [Member.chapter.rawValue: .int(Int64(chapter))]
    if let intent { members[Member.intent.rawValue] = .string(intent) }
    if let direction { members[Member.direction.rawValue] = .string(direction) }
    if empty { members[Member.empty.rawValue] = .bool(true) }
    return .object(members)
  }

  /// Orchestrator decision 8: the chapter is the job's target, so the fingerprint is the steer's digest.
  var fingerprint: String {
    ChapterFingerprint.digest(
      [Member.intent.rawValue: intent.map(JSONValue.string) ?? .null, Member.direction.rawValue: direction.map(JSONValue.string) ?? .null, Member.empty.rawValue: .bool(empty)])
  }

  var steer: String? { intent ?? direction }

  private static func trimmed(_ text: String) -> String? {
    let trimmed = text.jsTrim()
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct PlanAssessment: Sendable {
  let input: PlanJobInput
  let droppedIntent: String?
  let open: JobKey?
  let settled: Bool
}

extension JobEngine {
  /// apps/novel-forge-server/src/modules/actions/action-job.service.ts:87-101: only the next writable chapter (PLN_006), one plan at a time (PLN_009), an empty
  /// plan only where none is (PLN_007), the steer checked against the author's words. The same plan asked again while it runs answers that job; once it settled,
  /// its next run. The job is only requested: the caller runs it.
  @concurrent
  public func requestPlan(_ request: ChapterPlanJobRequest) async throws(ChapterPlanError) -> ChapterPlanReceipt {
    let now = clock.now()
    let assessment: PlanAssessment
    do {
      assessment = try await store.read { transaction in try PlanRequests.assess(request, at: now, in: transaction) }
    } catch {
      throw PlanRequests.unwrapping(error)
    }
    let input = assessment.input
    if let open = assessment.open { return ChapterPlanReceipt(job: open, chapter: input.chapter, deduped: true, droppedIntent: assessment.droppedIntent) }
    if let dropped = assessment.droppedIntent {
      PlanRequests.logger.info(
        "Dropped an intent the author never stated for the direction they chose chapter=\(input.chapter, privacy: .public) intent=\(dropped, privacy: .private)")
    }
    let key: JobKey
    do {
      key = try await self.request(
        NovelJobRequest(
          kind: .plan, novel: request.novel, chapter: input.chapter, fingerprint: input.fingerprint, payload: input.payload, origin: PlanRequests.origin(of: request.steer),
          rerun: assessment.settled))
    } catch {
      throw .engine(error)
    }
    return ChapterPlanReceipt(job: key, chapter: input.chapter, deduped: false, droppedIntent: assessment.droppedIntent)
  }
}

enum PlanRequests {
  static let logger = Logger(category: "plan.requests")

  fileprivate static func assess(_ request: ChapterPlanJobRequest, at now: LeaseInstant, in transaction: ReadTransaction) throws(ChapterPlanError) -> PlanAssessment {
    let next = try nextWritableChapter(novel: request.novel, in: transaction)
    let chapter = request.chapter ?? next
    guard chapter == next else { throw .notNextChapter(chapter: chapter, next: next) }
    let steer = try steering(request.steer, in: transaction)
    let input = PlanJobInput(chapter: chapter, intent: steer.intent, direction: steer.direction, empty: request.empty)
    let highest = try highestRun(novel: request.novel, input: input, in: transaction)
    if let highest, [.queued, .running].contains(JobStatus(highest.snapshot, at: now).phase) {
      return PlanAssessment(input: input, droppedIntent: steer.droppedIntent, open: highest.key, settled: false)
    }
    try requireNoOtherPlan(novel: request.novel, chapter: chapter, at: now, in: transaction)
    try requireNoGeneration(novel: request.novel, chapter: chapter, at: now, in: transaction)
    if request.empty, try planExists(novel: request.novel, chapter: chapter, in: transaction) { throw .alreadyPlanned(chapter: chapter) }
    return PlanAssessment(input: input, droppedIntent: steer.droppedIntent, open: nil, settled: highest != nil)
  }

  fileprivate static func origin(of steer: ChapterPlanSteer) -> JSONValue {
    guard case .card(_, _, let origin) = steer else { return .null }
    return [
      "sessionId": .string(origin.session.lowercasedString), "messageId": origin.message.map { .string($0.lowercasedString) } ?? .null,
      "proposalId": .string(origin.proposal.lowercasedString), "opIndex": .int(Int64(origin.opIndex)),
    ]
  }

  fileprivate static func unwrapping(_ error: StoreError) -> ChapterPlanError {
    guard case .aborted(let inner) = error, let inner = inner as? ChapterPlanError else { return .store(error) }
    return inner
  }

  // apps/novel-forge-server/src/common/next-chapter.ts:11, from the lifecycle as reconciled
  static func nextWritableChapter(novel: UUID, in transaction: ReadTransaction) throws(ChapterPlanError) -> Int {
    let table = ChapterLifecycleEntry.databaseTableName
    let entries: Derived<[ChapterLifecycleEntry]>
    do {
      let report = try ReadFaults(novel: novel, reading: [table], in: transaction)
      entries = try report.section([table]) { () throws(StoreError) in
        try transaction.query { database in try ChapterLifecycleEntry.filter(Column("novel") == novel).fetchAll(database) }
      }
    } catch {
      throw .store(error)
    }
    guard let entries = entries.value else { throw .chaptersUnavailable }
    return ChapterSequence.nextWritable(draftChapters: entries.filter { $0.draft != nil }.map(\.chapter), finalizedChapters: entries.filter(\.isFinal).map(\.chapter))
  }

  /// plan-job.service.ts:30-33, read where the card is staged: a draft written while the plan was made moves the story past the chapter it planned.
  static func requireStillNext(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ChapterPlanError) {
    let next: Int
    do {
      next = try ChapterDrafts.nextWritableChapter(novel: novel, in: transaction)
    } catch {
      if case .store(let cause) = error { throw .store(cause) }
      throw .chaptersUnavailable
    }
    guard next == chapter else { throw .outOfDate(chapter: chapter, next: next) }
  }

  // apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:46-49
  static func planExists(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(ChapterPlanError) -> Bool {
    guard let ref = try? ChapterPlanRecord.ref(novel: novel, chapter: chapter) else { return false }
    let reading: RecordReading<ChapterPlanRecord>
    do {
      reading = try ChapterPlanRecord.readHead(ref, in: transaction)
    } catch {
      throw .store(error)
    }
    switch reading {
    case .absent: return false
    case .unreadable: return true
    case .readable(let entry): return !entry.isRemoved
    }
  }

  private static func highestRun(novel: UUID, input: PlanJobInput, in transaction: ReadTransaction) throws(ChapterPlanError) -> (key: JobKey, snapshot: JobSnapshot)? {
    var highest: (key: JobKey, snapshot: JobSnapshot)?
    var run = 1
    while true {
      let key: JobKey
      do {
        key = try JobKey(
          scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.plan.rawValue, target: NovelJobAddress.target(chapter: input.chapter), fingerprint: input.fingerprint,
          run: run)
      } catch {
        throw .engine(.key(error))
      }
      let snapshot: JobSnapshot?
      do {
        snapshot = try JobSnapshot.load(key.ref, in: transaction)
      } catch {
        throw .engine(.record(error))
      }
      guard let snapshot else { return highest }
      highest = (key, snapshot)
      run += 1
    }
  }

  // apps/novel-forge-server/src/modules/actions/plan-job.service.ts:106-114; a job of the same plan was answered before this as the one already running.
  private static func requireNoOtherPlan(novel: UUID, chapter: Int, at now: LeaseInstant, in transaction: ReadTransaction) throws(ChapterPlanError) {
    let activity: JobActivity
    do {
      activity = try JobActivity.load(JobActivityQuery(novel: novel, now: now), in: transaction)
    } catch {
      throw .store(error)
    }
    guard let entries = activity.entries.value else { throw .jobsUnavailable }
    guard let running = entries.first(where: { $0.kind == .known(.plan) }) else { return }
    throw .anotherPlanRunning(chapter: running.chapter ?? chapter)
  }

  /// The reference's authoring claim (job.service.ts:144, authoring-claim.ts:28) refuses a plan while any authoring job of the novel holds it; natively only a
  /// generate job open for the chapter being planned refuses it.
  static func requireNoGeneration(novel: UUID, chapter: Int, at now: LeaseInstant, in transaction: ReadTransaction) throws(ChapterPlanError) {
    let activity: JobActivity
    do {
      activity = try JobActivity.load(JobActivityQuery(novel: novel, now: now), in: transaction)
    } catch {
      throw .store(error)
    }
    guard let generating = activity.generating.value else { throw .jobsUnavailable }
    if generating.contains(chapter) { throw .chapterBeingWritten(chapter: chapter) }
  }

  // apps/novel-forge-server/src/modules/actions/action-job.service.ts:91
  private static func steering(_ steer: ChapterPlanSteer, in transaction: ReadTransaction) throws(ChapterPlanError) -> PlanSteer {
    guard let rule = QuoteRule.shared else { throw .steeringUnavailable }
    switch steer {
    case .none:
      return PlanSteer()
    case .author(let text):
      return rule.planSteer(intent: text, direction: nil, authorMessages: [text])
    case .card(let intent, let direction, let origin):
      let stated = (intent?.jsTrim() ?? "").isEmpty ? [] : try authorMessages(for: origin, in: transaction)
      return rule.planSteer(intent: intent, direction: direction, authorMessages: stated)
    }
  }

  /// plan-job.service.ts:43-72 over the chat of the message the card answered. Messages take their transcript position and cards the order they were staged in
  /// (the first-writer-wins card clock, then the id), the append order every replica agrees on, for the reference's serial ids.
  static func authorMessages(for origin: ChapterPlanOrigin, in transaction: ReadTransaction) throws(ChapterPlanError) -> [String] {
    guard let message = origin.message else { return [] }
    do {
      guard let answered = try ChatMessageRecord.read(id: message, in: transaction).entry?.record else { return [] }
      let session = answered.session
      let transcript = try ChatTranscript.messages(of: session, in: transaction)
      let positions = Dictionary(transcript.compactMap { entry in entry.record.map { ($0.id, entry.position) } }) { first, _ in first }
      guard let answeredPosition = positions[message] else { return [] }
      let messages = transcript.compactMap { entry -> PlanChatMessage? in
        guard let record = entry.record else { return nil }
        return PlanChatMessage(
          id: entry.position, sessionId: session.lowercasedString, isAuthor: record.role == .known(.user), content: record.content, contexts: record.passageContexts)
      }
      let states = try transaction.query { database in
        try ProposalState.filter(Column("session") == session || Column("proposal") == origin.proposal).fetchAll(database)
      }
      let ordered = states.sorted { $0.staged == $1.staged ? $0.ref < $1.ref : $0.staged < $1.staged }
      let ordinals = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.proposal, $0.offset + 1) })
      let originOrdinal = ordinals[origin.proposal] ?? ordered.count + 1
      var prior = [PriorProposal]()
      for state in ordered where state.session == session && state.proposal != origin.proposal {
        guard let ordinal = ordinals[state.proposal] else { continue }
        prior.append(
          PriorProposal(
            id: ordinal, sessionId: session.lowercasedString, messageId: state.message.flatMap { positions[$0] }, plansChapter: try plansChapter(state, in: transaction)))
      }
      return authorMessagesFor(
        PlanCardOrigin(sessionId: origin.session.lowercasedString, messageId: answeredPosition, proposalId: originOrdinal), messages: messages, proposals: prior)
    } catch {
      throw .store(error)
    }
  }

  private static func plansChapter(_ state: ProposalState, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    if state.kind == .known(.chapterPlan) { return true }
    guard case .readable(let entry) = try ProposalRecord.read(id: state.proposal, in: transaction) else { return false }
    return entry.record.card.ops.contains { $0?.type == .actionPlanChapter }
  }
}
