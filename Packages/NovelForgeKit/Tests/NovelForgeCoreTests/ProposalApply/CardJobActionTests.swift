import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private struct RequestedJob: Equatable {
  let kind: String
  let target: String
  let origin: JSONValue
}

private enum Cards {
  static let generate1 = #"{"op":"action.generate_chapter","chapter":1}"#
  static let judge3 = #"{"op":"action.judge_draft","chapter":3}"#
  static let plan = #"{"op":"action.plan_chapter","direction":"Kael returns"}"#

  static func origin(_ proposal: UUID, index: Int = 0) -> JSONValue {
    NovelJobOrigin.json(session: StagingWorld.session, message: nil, proposal: proposal, opIndex: index)
  }
}

extension ChapterBook {
  fileprivate func planned(_ chapter: Int) async throws {
    let novel = novel
    try await run { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, ChapterPlanContent(body: "Mara climbs the lighthouse."), in: &$0) }
  }

  fileprivate func jobRecords() async throws -> [JobRecord] {
    let scope = NovelJobAddress.scope(of: novel)
    return try await store.read { transaction in
      try transaction.states(ofKind: JobSchema.jobKind).compactMap { entry in
        guard case .readable(let job) = JobRecords.reading(entry.state, of: entry.ref), job.request.key.scope == scope,
          ![NovelJobKind.finalizeReview, .canonRefresh].map(\.rawValue).contains(job.request.key.kind)
        else { return nil }
        return job
      }
    }
  }

  fileprivate func requestedJobs() async throws -> [RequestedJob] {
    try await jobRecords().map { RequestedJob(kind: $0.request.key.kind, target: $0.request.key.target, origin: $0.request.origin) }
  }

  fileprivate func failure(of id: UUID, _ index: Int = 0) async throws -> ProposalChangeFailure? {
    try #require(try await applied(id, .indexes([index])).first { $0.index == index }).failure
  }

  fileprivate func card(_ op: String) async throws -> UUID {
    try await stage(op).proposal.id
  }
}

// hub-action.registrar.ts:39-61, action-job.service.ts:57-61: the job actions only request their job, with the card as its origin
@Suite("Card job actions", TestTimeLimit.standard)
struct CardJobActionTests {
  @Test func shouldRequestTheGenerateJobWithTheCardAsItsOrigin() async throws {
    let book = try await StagingWorld.book()
    try await book.planned(1)
    let id = try await book.card(Cards.generate1)
    let outcome = try #require(try await book.applied(id, .indexes([0])).first)
    #expect(outcome.status == .applied && outcome.summary == "enqueued generation of chapter 1")
    #expect(try await book.requestedJobs() == [RequestedJob(kind: "generate", target: NovelJobAddress.target(chapter: 1), origin: Cards.origin(id))])
  }

  @Test func shouldWriteTheOriginUnderTheSchemasMembers() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(Cards.judge3)
    _ = try await book.applied(id, .indexes([0]))
    let origin = try #require(try await book.requestedJobs().first?.origin.objectValue)
    #expect(Set(origin.keys) == Set(NovelJobOriginMember.allCases.map(\.rawValue)))
    #expect(origin[NovelJobOriginMember.session.rawValue]?.stringValue == StagingWorld.session.lowercasedString)
    #expect(origin[NovelJobOriginMember.message.rawValue] == .null)
    #expect(origin[NovelJobOriginMember.proposal.rawValue]?.stringValue == id.lowercasedString)
    #expect(origin[NovelJobOriginMember.opIndex.rawValue] == .int(0))
  }

  @Test func shouldRequestTheNextChaptersPlanJobAndAnswerTheOpenOneOnAnotherAsk() async throws {
    let book = try await StagingWorld.workspace()
    let first = try await book.card(Cards.plan)
    let outcome = try #require(try await book.applied(first, .indexes([0])).first)
    #expect(outcome.status == .applied && outcome.summary == "planning chapter 4 — the plan arrives as a card")
    #expect(try await book.requestedJobs() == [RequestedJob(kind: "plan", target: NovelJobAddress.target(chapter: 4), origin: Cards.origin(first))])
    let again = try await book.card(Cards.plan)
    #expect(try await book.applied(again, .indexes([0])).first?.summary == "chapter 4 is already being planned")
    #expect(try await book.requestedJobs().count == 1)
  }

  @Test func shouldRequestTheJudgeReviewOfTheChapterAsItStands() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(Cards.judge3)
    let outcome = try #require(try await book.applied(id, .indexes([0])).first)
    #expect(outcome.status == .applied && outcome.summary == "requested a judge review of chapter 3")
    #expect(try await book.requestedJobs() == [RequestedJob(kind: "review", target: NovelJobAddress.target(chapter: 3), origin: Cards.origin(id))])
  }

  @Test func shouldSurfaceTheGenerationRefusalsOnTheCard() async throws {
    let book = try await StagingWorld.workspace()
    #expect(try await book.failure(of: try await book.card(#"{"op":"action.generate_chapter","chapter":4}"#))?.code == "BRF_001")
    #expect(try await book.failure(of: try await book.card(#"{"op":"action.generate_chapter","chapter":3}"#))?.code == "DRF_015")
    #expect(try await book.requestedJobs().isEmpty)
  }

  @Test func shouldRefuseASecondGenerationWhileOneIsOpen() async throws {
    let book = try await StagingWorld.book()
    try await book.planned(1)
    #expect(try await book.applied(try await book.card(Cards.generate1), .indexes([0])).first?.status == .applied)
    #expect(try await book.failure(of: try await book.card(Cards.generate1))?.code == "DRF_010")
    #expect(try await book.requestedJobs().count == 1)
  }

  @Test func shouldSurfaceThePlanRefusalsOnTheCard() async throws {
    let book = try await StagingWorld.workspace()
    #expect(try await book.failure(of: try await book.card(#"{"op":"action.plan_chapter","chapter":9}"#))?.code == "PLN_006")
    #expect(try await book.applied(try await book.card(Cards.plan), .indexes([0])).first?.status == .applied)
    #expect(try await book.failure(of: try await book.card(#"{"op":"action.plan_chapter","direction":"Mara leaves"}"#))?.code == "PLN_009")
    #expect(try await book.requestedJobs().count == 1)
  }

  @Test func shouldRefuseAPlanFromACardThatBelongsToNoChat() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(Cards.plan, session: nil).proposal.id
    #expect(try await book.failure(of: id)?.code == "refinement.card_without_chat")
    #expect(try await book.requestedJobs().isEmpty)
  }

  @Test func shouldSurfaceTheReviewRefusalsOnTheCard() async throws {
    let book = try await StagingWorld.workspace()
    #expect(try await book.failure(of: try await book.card(#"{"op":"action.judge_draft","chapter":9}"#))?.code == "REV_006")
    let novel = book.novel
    try await book.draft(4)
    try await book.run {
      _ = try NovelJobRequest(kind: .generate, novel: novel, chapter: 4, fingerprint: "open").enqueue(
        replica: SchemaFixture.requester, now: JobActionRequest.requestTime(), in: &$0)
    }
    #expect(try await book.failure(of: try await book.card(#"{"op":"action.judge_draft","chapter":4}"#))?.code == "REV_007")
    #expect(try await book.requestedJobs().map(\.kind) == ["generate"])
  }

  @Test func shouldRequestOnceWhenTheActionRunsAgainAfterItSettled() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(Cards.judge3)
    let (novel, context) = (book.novel, book.context())
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0]), context: context, in: &$0) }
    let run = { try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) } }
    #expect(try await run() == .ran(summary: "requested a judge review of chapter 3"))
    #expect(try await run() == .settled(.known(.applied)))
    #expect(await book.store.resumePendingActions().isEmpty)
    #expect(try await book.store.retryPendingActions(id, novel: novel).isEmpty)
    #expect(try await book.requestedJobs().count == 1)
  }

  @Test func shouldResumeAnInterruptedApplyToOneRequest() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(Cards.plan)
    let context = book.context()
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0]), context: context, in: &$0) }
    #expect(try await book.requestedJobs().isEmpty)
    #expect(
      await book.store.resumePendingActions() == [
        .resumed(proposal: id, [ProposalActionResult(index: 0, outcome: .known(.applied), summary: "planning chapter 4 — the plan arrives as a card")])
      ])
    #expect(await book.store.resumePendingActions().isEmpty)
    #expect(try await book.requestedJobs() == [RequestedJob(kind: "plan", target: NovelJobAddress.target(chapter: 4), origin: Cards.origin(id))])
  }

  @Test func shouldRunOnlyTheActionsAnExecutorPerforms() {
    let runnable = OpType.allCases.filter(ProposalActionRegistry.isRunnable)
    #expect(Set(runnable) == [.actionApproveDraft, .actionFinalize, .actionAdvanceVolume, .actionGenerateChapter, .actionPlanChapter, .actionJudgeDraft])
    let unavailable = OpType.allCases.filter { isActionOp($0) && !ProposalActionRegistry.isRunnable($0) }
    #expect(unavailable.count == 6)
    for type in unavailable { #expect(ApplyError.notYetAvailable(type).errorDescription == "Applying \(type.rawValue) is not yet available") }
  }

  @Test func shouldRefuseAnActionNoExecutorPerformsAsNotYetAvailable() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(#"{"op":"action.validate","scope":"novel"}"#)
    #expect(await book.applyError(id, .indexes([0])) == .apply(.notYetAvailable(.actionValidate)))
    #expect(try await book.requestedJobs().isEmpty)
  }

  @Test func shouldRequestAJudgeReviewOfKindJudge() async throws {
    let book = try await StagingWorld.workspace()
    _ = try await book.applied(try await book.card(Cards.judge3), .indexes([0]))
    #expect(try await book.jobRecords().map { $0.request.payload["kind"] } == [.string("judge")])
  }

  @Test func shouldCarryTheMessageAndIndexOfTheOpInTheOrigin() async throws {
    let book = try await StagingWorld.workspace()
    let message = SchemaFixture.uuid("00000000-0000-4000-8000-0000000000a7")
    let changeSet = try StagingWorld.changeSet(ApplyWorld.premise, Cards.judge3)
    let id = try await book.stage(ProposalStagingInput(novel: book.novel, session: StagingWorld.session, message: message, kind: .hub, changeSet: changeSet)).proposal.id
    _ = try await book.applied(id, .indexes([1]))
    #expect(try await book.requestedJobs().map(\.origin) == [NovelJobOrigin.json(session: StagingWorld.session, message: message, proposal: id, opIndex: 1)])
  }

  @Test func shouldNotRequestARunTwoWhenTheFirstJobEndedBeforeTheActionRanAgain() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(Cards.judge3)
    let (novel, context) = (book.novel, book.context())
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0]), context: context, in: &$0) }
    let run = { try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) } }
    #expect(try await run() == .ran(summary: "requested a judge review of chapter 3"))
    let job = try #require(try await book.jobRecords().first)
    try await book.run { _ = try JobRecords.cancel(job.ref, in: &$0) }
    #expect(try await run() == .settled(.known(.applied)))
    #expect(await book.store.resumePendingActions().isEmpty)
    #expect(try await book.jobRecords().count == 1)
  }

  @Test func shouldLeaveTheActionPendingWhenTheStoreFailsWritingTheJob() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.card(Cards.judge3)
    try await book.run { transaction in
      try transaction.database.execute(sql: "CREATE TRIGGER fail_job BEFORE INSERT ON field_state WHEN NEW.kind = 'jobs_job' BEGIN SELECT RAISE(ABORT, 'disk full'); END")
    }
    #expect(try await book.applied(id, .indexes([0])).map(\.status) == [.pending])
    #expect(try await book.change(id, 0).actionOutcome == .known(.pending))
    #expect(try await book.requestedJobs().isEmpty)
    try await book.run { transaction in try transaction.database.execute(sql: "DROP TRIGGER fail_job") }
    #expect(try await book.store.resumeProposalActions(id, novel: book.novel).map(\.outcome) == [.known(.applied)])
    #expect(try await book.requestedJobs().count == 1)
  }
}
