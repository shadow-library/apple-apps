import Foundation
import ShadowCore
import ShadowStore

enum ProposalActionStep: Sendable, Equatable {
  case ran(summary: String)
  /// Settled before this run, by this device or a concurrent applier; the outcome is the change's `actionOutcome`, never its raw status.
  case settled(StoredEnum<ProposalChangeStatus>)
  /// This version has no executor for it; it stays pending for a device that has one.
  case unavailable
}

struct ProposalActionResult: Sendable, Equatable {
  let index: Int
  let outcome: StoredEnum<ProposalChangeStatus>
  var failure: ProposalChangeFailure?
  var summary: String?
}

extension ProposalApply {
  /// proposal-apply.service.ts:261-281 for one selected action, in a transaction of its own after the content committed, so its guards read the lifecycle
  /// the content left. A thrown `.action` abandons the transaction; the caller then settles the change as failed in another. The action's effect and its
  /// settled change commit together, so a change read as settled is an action that took effect and never runs again.
  static func runAction(
    proposal id: UUID, index: Int, novel: UUID, requester: ReplicaID, in transaction: inout WriteTransaction
  ) throws(ProposalApplyError) -> ProposalActionStep {
    let (proposal, op, ref, change) = try actionChange(id, index: index, novel: novel, in: transaction)
    guard change.actionOutcome == .known(.pending) else {
      try settlePending(id, index: index, in: transaction)
      return .settled(change.actionOutcome)
    }
    guard let executor = ProposalActionRegistry.executor(for: op.type) else { return .unavailable }
    let summary: String
    do throws(ApplyError) {
      summary = try executor.execute(ProposalAction(proposal: proposal, index: index, op: op, requester: requester), in: &transaction)
    } catch {
      throw .action(index: index, error)
    }
    let result = ProposalChangeResult(result: ["summary": .string(summary)])
    let settled = try stored { () throws(StoreError) in try ProposalChangeRecord.settleAction(ref, result: result, in: &transaction) }
    try settlePending(id, index: index, in: transaction)
    switch settled {
    case .settled: return .ran(summary: summary)
    case .alreadySettled(let outcome): return .settled(outcome)
    }
  }

  /// proposal-apply.service.ts:263-266, :276-279: settles a pending action as failed; returns the outcome the change holds afterwards.
  static func failAction(proposal id: UUID, index: Int, novel: UUID, failure: ProposalChangeFailure, in transaction: inout WriteTransaction) throws(ProposalApplyError)
    -> StoredEnum<ProposalChangeStatus>
  {
    let (_, _, ref, _) = try actionChange(id, index: index, novel: novel, in: transaction)
    let settled = try stored { () throws(StoreError) in try ProposalChangeRecord.settleAction(ref, result: failure.stored, in: &transaction) }
    try settlePending(id, index: index, in: transaction)
    switch settled {
    case .settled: return .known(.failed)
    case .alreadySettled(let outcome): return outcome
    }
  }

  private static func settlePending(_ id: UUID, index: Int, in transaction: borrowing WriteTransaction) throws(ProposalApplyError) {
    try stored { () throws(StoreError) in try PendingActions.settle(proposal: id, index: index, in: transaction.database) }
  }

  /// Whether a change of the card may still be a pending action: one recorded pending, or one this device cannot read.
  static func holdsPendingAction(proposal id: UUID, novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalApplyError) -> Bool {
    let pending = try pendingActions(proposal: id, novel: novel, in: transaction)
    return !pending.indexes.isEmpty || pending.unreadable
  }

  /// The indexes recorded as pending actions, ascending, and whether a change this device cannot read may be one too.
  static func pendingActions(proposal id: UUID, novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalApplyError)
    -> (indexes: [Int], unreadable: Bool)
  {
    let proposal = try readable(id, novel: novel, in: transaction)
    let entries = try stored { () throws(StoreError) in try ProposalChangeRecord.changes(of: proposal, in: transaction) }
    var indexes = [Int]()
    var unreadable = false
    for entry in entries {
      switch entry {
      case .recorded(let change) where change.actionOutcome == .known(.pending): indexes.append(change.index)
      case .unreadable: unreadable = true
      case .recorded, .awaiting, .declined, .notApplied: continue
      }
    }
    return (indexes.sorted(), unreadable)
  }

  /// The action indexes of an applied card that hold a change record, in index order, up to the first change this device cannot read or the first pending
  /// change of an op it cannot read: either may be an action that has to run before the ones after it.
  static func recordedActions<Transaction: StateReading & ~Copyable>(proposal id: UUID, novel: UUID, in transaction: borrowing Transaction) throws(ProposalApplyError)
    -> [Int]
  {
    let proposal = try readable(id, novel: novel, in: transaction)
    let entries = try stored { () throws(StoreError) in try ProposalChangeRecord.changes(of: proposal, in: transaction) }
    var actions = [Int]()
    for (index, entry) in entries.enumerated() {
      let op = proposal.card.changeSet[index].op
      switch entry {
      case .unreadable where op.map(isActionOp) != false: return actions
      case .recorded(let change) where op == nil && change.actionOutcome == .known(.pending): return actions
      case .recorded where op.map(isActionOp) == true: actions.append(index)
      default: continue
      }
    }
    return actions
  }

  private static func actionChange(_ id: UUID, index: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalApplyError)
    -> (ProposalRecord, ChangeOp, EntityRef, ProposalChangeRecord)
  {
    let proposal = try readable(id, novel: novel, in: transaction)
    guard proposal.card.changeSet.indices.contains(index), let op = proposal.card.changeSet[index].op, isActionOp(op) else { throw .apply(.invalidSelection) }
    let ref: EntityRef
    do throws(NovelForgeKeyError) {
      ref = try ProposalChangeRecord.ref(novel: novel, proposal: id, index: index)
    } catch {
      throw .store(.invalidChange(error.errorDescription ?? error.code))
    }
    guard case .readable(let entry) = try stored({ () throws(StoreError) in try ProposalChangeRecord.read(ref, in: transaction) }) else {
      throw .store(.invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is not a readable proposal change"))
    }
    return (proposal, op, ref, entry.record)
  }
}

extension VaultStore {
  /// proposal-apply.service.ts:109-230: the content of the selection, its change records and the decision commit together; the selected actions then run
  /// in index order, each in its own transaction, and once one fails the rest are settled as skipped while the content stays applied.
  public func applyProposal(_ id: UUID, selection: ApplySelection, context: ProposalApplyContext) async throws(ProposalApplyError) -> ProposalApplyOutcome {
    let outcome = try await writeProposal { transaction throws(ProposalApplyError) in
      try ProposalApply.apply(proposal: id, selection: selection, context: context, in: &transaction)
    }
    guard case .applied(var changes) = outcome else { return outcome }
    let results = await runProposalActions(id, novel: context.novel, indexes: changes.filter { $0.status == .pending }.map(\.index))
    for result in results {
      guard let position = changes.firstIndex(where: { $0.index == result.index }) else { continue }
      changes[position].status = result.outcome.known ?? .pending
      changes[position].failure = result.failure
      changes[position].summary = result.summary
    }
    return .applied(changes)
  }

  /// Runs what is still pending of an applied card's actions, after an apply was interrupted between its content commit and its actions; an action settled
  /// as failed skips the ones after it, as in the apply that recorded them.
  func resumeProposalActions(_ id: UUID, novel: UUID) async throws(ProposalApplyError) -> [ProposalActionResult] {
    let indexes: [Int]
    do {
      indexes = try await read { transaction in try ProposalApply.recordedActions(proposal: id, novel: novel, in: transaction) }
    } catch {
      if case .aborted(let cause) = error, let apply = cause as? ProposalApplyError { throw apply }
      throw .store(error)
    }
    return await runProposalActions(id, novel: novel, indexes: indexes)
  }

  /// At launch, once per row of `PendingActions`, oldest first: resumes the actions of every apply this device stopped between its content and its actions.
  /// Never throws and never loops: a row whose card is gone or holds no pending action is removed, one the sweep leaves pending is kept with its fault, and
  /// a row `PendingActions.attemptLimit` sweeps started on is skipped.
  func resumePendingActions() async -> [PendingActionResume] {
    let rows: [PendingActionRow]
    do {
      rows = try await read { transaction in try PendingActions.rows(in: transaction.database) }
    } catch {
      return [.unreadable(code: error.code)]
    }
    var resumes = [PendingActionResume]()
    for row in rows {
      resumes.append(await resumePendingActions(row))
    }
    return resumes
  }

  private func resumePendingActions(_ row: PendingActionRow) async -> PendingActionResume {
    let proposal = row.proposal
    guard row.attempts < PendingActions.attemptLimit else { return .skipped(proposal: proposal, fault: row.fault) }
    do {
      try await write { transaction in try PendingActions.attempt(proposal: proposal, in: transaction.database) }
    } catch {
      return .faulted(proposal: proposal, code: error.code)
    }
    let novel = row.novel
    let results: [ProposalActionResult]
    do throws(ProposalApplyError) {
      results = try await resumeProposalActions(proposal, novel: novel)
    } catch {
      guard case .notFound = error else { return await faultPendingActions(proposal, code: error.code) }
      return await forgetPendingActions(proposal, code: error.code)
    }
    let left: [Int]?
    do throws(ProposalApplyError) {
      left = try await settleSweptRow(proposal, novel: novel)
    } catch {
      return .faulted(proposal: proposal, code: error.code)
    }
    guard left != nil else { return .resumed(proposal: proposal, results) }
    return await faultPendingActions(proposal, code: Self.stall(of: results))
  }

  /// Try Again for actions the sweep gave up on: runs them as it does, without counting an attempt, and returns the indexes still pending.
  public func retryPendingActions(_ proposal: UUID, novel: UUID) async throws(ProposalApplyError) -> [Int] {
    let results = try await resumeProposalActions(proposal, novel: novel)
    guard let left = try await settleSweptRow(proposal, novel: novel) else { return [] }
    _ = await faultPendingActions(proposal, code: Self.stall(of: results))
    return left
  }

  /// Forgets the card's row once no action of it may be pending; otherwise the indexes still recorded pending.
  private func settleSweptRow(_ proposal: UUID, novel: UUID) async throws(ProposalApplyError) -> [Int]? {
    try await writeProposal { transaction throws(ProposalApplyError) in
      let pending = try ProposalApply.pendingActions(proposal: proposal, novel: novel, in: transaction)
      guard pending.indexes.isEmpty && !pending.unreadable else { return pending.indexes }
      try ProposalApply.stored { () throws(StoreError) in try PendingActions.forget(proposal: proposal, in: transaction.database) }
      return nil
    }
  }

  private static func stall(of results: [ProposalActionResult]) -> String {
    results.last { $0.outcome == .known(.pending) }?.failure?.code ?? PendingActions.unsettledFault
  }

  private func forgetPendingActions(_ proposal: UUID, code: String) async -> PendingActionResume {
    _ = try? await write { transaction in try PendingActions.forget(proposal: proposal, in: transaction.database) }
    return .forgotten(proposal: proposal, code: code)
  }

  private func faultPendingActions(_ proposal: UUID, code: String) async -> PendingActionResume {
    _ = try? await write { transaction in try PendingActions.fault(proposal: proposal, code: code, in: transaction.database) }
    return .faulted(proposal: proposal, code: code)
  }

  /// Never throws: the content has committed, so an action this run could not settle (the store failed under it) stays pending, reported with why, and the
  /// actions after it are left for a resume.
  private func runProposalActions(_ id: UUID, novel: UUID, indexes: [Int]) async -> [ProposalActionResult] {
    var results = [ProposalActionResult]()
    var failed = false
    for index in indexes.sorted() {
      do throws(ProposalApplyError) {
        guard let result = try await runProposalAction(id, index: index, novel: novel, afterFailure: failed) else { return results }
        results.append(result)
        failed = failed || result.outcome == .known(.failed)
      } catch {
        let failure = ProposalChangeFailure(code: error.code, message: error.errorDescription ?? error.code)
        results.append(ProposalActionResult(index: index, outcome: .known(.pending), failure: failure))
        return results
      }
    }
    return results
  }

  /// nil when this version cannot run the action, which stays pending for a device that can.
  private func runProposalAction(_ id: UUID, index: Int, novel: UUID, afterFailure: Bool) async throws(ProposalApplyError) -> ProposalActionResult? {
    if afterFailure { return try await failProposalAction(id, index: index, novel: novel, failure: .previousActionFailed) }
    let step: ProposalActionStep
    do throws(ProposalApplyError) {
      let requester = replica
      step = try await writeProposal { transaction throws(ProposalApplyError) in
        try ProposalApply.runAction(proposal: id, index: index, novel: novel, requester: requester, in: &transaction)
      }
    } catch {
      guard case .action(_, let cause) = error, !cause.isStoreFailure else { throw error }
      if case .domain(let refusal) = cause { try? await requestFinalizeReview(after: refusal, novel: novel) }
      return try await failProposalAction(id, index: index, novel: novel, failure: ProposalChangeFailure(cause))
    }
    switch step {
    case .ran(let summary): return ProposalActionResult(index: index, outcome: .known(.applied), summary: summary)
    case .settled(let outcome): return ProposalActionResult(index: index, outcome: outcome)
    case .unavailable: return nil
    }
  }

  private func failProposalAction(_ id: UUID, index: Int, novel: UUID, failure: ProposalChangeFailure) async throws(ProposalApplyError) -> ProposalActionResult {
    let outcome = try await writeProposal { transaction throws(ProposalApplyError) in
      try ProposalApply.failAction(proposal: id, index: index, novel: novel, failure: failure, in: &transaction)
    }
    return ProposalActionResult(index: index, outcome: outcome, failure: outcome == .known(.failed) ? failure : nil)
  }

  private func writeProposal<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(ProposalApplyError) -> T) async throws(ProposalApplyError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let apply = cause as? ProposalApplyError { throw apply }
      throw .store(error)
    }
  }
}

extension ApplyError {
  /// A failure of the store rather than a refusal: the action stays pending, to run again.
  fileprivate var isStoreFailure: Bool {
    switch self {
    case .store, .domain(.store): true
    default: false
    }
  }
}
