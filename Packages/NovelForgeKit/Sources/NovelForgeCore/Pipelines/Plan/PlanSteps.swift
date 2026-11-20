import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

/// The plan job (plan-job.service.ts:141-168): one structured call whose vetted plan is checkpointed, then the card staged in the commit that ends the attempt.
enum PlanPipeline {
  static let version = 1

  enum Step: String {
    case plan
    case stage
  }

  static let definition = NovelPipelineDefinition.ready(
    NovelPipeline(version: version, first: Step.plan.rawValue, steps: [Step.plan.rawValue: PlanStep(), Step.stage.rawValue: PlanStageStep()]))
}

/// The card a plan job stages has an id derived from the job (orchestrator decision 11), so every attempt and every replica stages the same card at most once;
/// the reference finds an earlier attempt's card by its run instead (action-jobs.ts:40-72).
enum PlanCards {
  static func id(of job: EntityRef) -> UUID {
    derivedID("com.shadow.library.novelforgekit.plan-card", job.key.rawValue)
  }

  /// A card already there, unreadable or decided ones included: the job staged it, so it is never staged again.
  static func isStaged<Transaction: StateReading & ~Copyable>(_ card: UUID, in transaction: borrowing Transaction) throws(StoreError) -> Bool {
    if case .absent = try ProposalRecord.read(id: card, in: transaction) { return false }
    return true
  }

  // plan-job.service.ts:163-167; proposal.service.ts:138
  static func stage(_ op: JSONValue, card: UUID, job: EntityRef, novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws {
    guard try !isStaged(card, in: transaction) else { return }
    try PlanRequests.requireStillNext(novel: novel, chapter: chapter, in: transaction)
    let changeSet: ValidatedChangeSet
    do {
      changeSet = try ValidatedChangeSet(.array([OrderedJSON(op)]), allowedOps: [.briefUpdate])
    } catch {
      throw PlanPipelineError.changeSet(error)
    }
    let input = ProposalStagingInput(novel: novel, kind: .chapterPlan, summary: "Plan for chapter \(chapter)", changeSet: changeSet, run: job.key.rawValue)
    do {
      _ = try ProposalStager.stage(input, id: card, in: &transaction)
    } catch {
      throw PlanPipelineError.staging(error)
    }
  }
}

extension PlanCardOp {
  /// The card's one `brief.update`, in the form the change-set stores it.
  var stored: JSONValue? {
    let metadata = OpFields(
      record: OrderedJSONObject(
        [rationale.map { (key: "rationale", value: OrderedJSON.string($0)) }, startedEmpty ? (key: "startedEmpty", value: OrderedJSON.bool(true)) : nil].compactMap { $0 }))
    return OrderedJSON.object(ChangeOp(operation: .briefUpdate(update), metadata: OpMetadata(metadata)).fields).storable
  }
}

struct PlanStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let card = PlanCards.id(of: context.attempt.job.ref)
    if try await context.store.read({ transaction in try PlanCards.isStaged(card, in: transaction) }) { return AttemptStepOutput(state: .null, next: nil) }
    let op = try await PlanCall.plan(PlanJobInput(payload: context.payload, chapter: context.target.chapter), in: context)
    guard let stored = op.stored else { throw PlanPipelineError.checkpointUnreadable }
    return AttemptStepOutput(state: ["op": stored], next: PlanPipeline.Step.stage.rawValue)
  }
}

struct PlanStageStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    guard let op = state["op"], op.objectValue != nil else { throw PlanPipelineError.checkpointUnreadable }
    let (job, target) = (context.attempt.job.ref, context.target)
    let card = PlanCards.id(of: job)
    return AttemptStepOutput(state: .null, next: nil) { transaction in
      try PlanCards.stage(op, card: card, job: job, novel: target.novel, chapter: target.chapter, in: &transaction)
    }
  }
}
