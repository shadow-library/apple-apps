import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

/// What a card action that asks for a job shares: the card as the job's origin (action-jobs.ts:27-30), the request written inside the action's own transaction
/// so it settles with the change, and the refusals of the request's gates carried as the failures the card shows.
enum JobActionRequest {
  static func origin(of action: ProposalAction) -> ChapterPlanOrigin? {
    action.proposal.card.session.map { ChapterPlanOrigin(session: $0, message: action.proposal.card.message, proposal: action.proposal.id, opIndex: action.index) }
  }

  static func requestTime() -> LeaseInstant {
    LeaseInstant(date: Date(), source: .device)
  }

  static func reading(_ transaction: borrowing WriteTransaction) -> ReadTransaction {
    ReadTransaction(database: transaction.database, registry: NovelForgeSchema.registry)
  }

  static func enqueue(_ request: NovelJobRequest, by action: ProposalAction, at now: LeaseInstant, in transaction: inout WriteTransaction) throws(ApplyError) {
    do {
      _ = try request.enqueue(replica: action.requester, now: now, in: &transaction)
    } catch let error as StoreError {
      throw .store(error)
    } catch JobRecordError.store(let error) {
      throw .store(error)
    } catch {
      throw refusal(error)
    }
  }

  static func refusal(_ error: any Error) -> ApplyError {
    let shadow = error as? any ShadowError
    return .refused(.jobRefused(code: shadow?.code ?? "jobs.request_failed", message: shadow?.errorDescription ?? error.localizedDescription))
  }

  static func refusal(_ error: JobEngineError) -> ApplyError {
    switch error {
    case .store(let store), .record(.store(let store)): .store(store)
    default: refusal(error as any Error)
    }
  }

  static func refusal(_ error: GenerationRequestError) -> ApplyError {
    switch error {
    case .domain(let domain): .domain(domain)
    case .engine(let engine): refusal(engine)
    default: refusal(error as any Error)
    }
  }

  static func refusal(_ error: ChapterPlanError) -> ApplyError {
    switch error {
    case .store(let store): .store(store)
    case .engine(let engine): refusal(engine)
    default: refusal(error as any Error)
    }
  }

  static func refusal(_ error: ReviewRequestError) -> ApplyError {
    switch error {
    case .review(.store(let store)): .store(store)
    case .review(.domain(let domain)): .domain(domain)
    case .engine(let engine): refusal(engine)
    default: refusal(error as any Error)
    }
  }
}
