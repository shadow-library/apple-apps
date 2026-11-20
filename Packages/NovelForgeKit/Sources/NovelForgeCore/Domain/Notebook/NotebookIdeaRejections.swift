import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/classes/app-error-code.ts:166, :225-230
public enum IdeaRejectionError: ShadowError, Equatable {
  case proposalNotFound(UUID)
  case proposalUnreadable(UUID)
  case noChange(opIndex: Int)
  case changeUnreadable(opIndex: Int)
  case notAnIdea
  case touchesNoRecord
  case recordUnreadable(String)
  case volumesUnreadable
  case ideaIdsUnavailable
  case unstorableAnchor
  case notebook(NotebookError)
  case domain(DomainError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .proposalNotFound: "RFN_001"
    case .proposalUnreadable: "idea_rejection.proposal_unreadable"
    case .noChange: "LDG_006"
    case .changeUnreadable: "idea_rejection.change_unreadable"
    case .notAnIdea: "LDG_007"
    case .touchesNoRecord: "LDG_008"
    case .recordUnreadable: "idea_rejection.record_unreadable"
    case .volumesUnreadable: "idea_rejection.volumes_unreadable"
    case .ideaIdsUnavailable: "idea_rejection.idea_ids_unavailable"
    case .unstorableAnchor: "idea_rejection.unstorable_anchor"
    case .notebook(let error): error.code
    case .domain(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .proposalNotFound: "Refinement proposal not found"
    case .proposalUnreadable: "This suggestion was written by a newer version of the app, so its changes cannot be turned down here"
    case .noChange(let index): "This suggestion has no change \(index) to turn down"
    case .changeUnreadable(let index): "Change \(index) of this suggestion cannot be read on this device, so it cannot be turned down here"
    case .notAnIdea: "Only a suggested change can be turned down — a step that runs the pipeline is declined, not remembered"
    case .touchesNoRecord: "This change touches no Story Bible record, so it cannot be turned down for this version only — choose \"never\" or \"not now\""
    case .recordUnreadable(let ref): "\(ref) cannot be read on this device, so the change cannot be turned down for this version only"
    case .volumesUnreadable: "Some volumes cannot be read on this device, so the change cannot be turned down for now only"
    case .ideaIdsUnavailable: "This device cannot tell the ideas of a change apart, so it cannot turn one down"
    case .unstorableAnchor: "The records this change touches cannot be recorded as they stand"
    case .notebook(let error): error.errorDescription
    case .domain(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: IdeaRejectionError, right: IdeaRejectionError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-rejection.service.ts; the unique active-idea index (ledger.ts:73) holds only on one device, so two devices can
// each leave an active rejection of one idea: the next rejection or withdrawal on its topic settles every one of them.
enum NotebookIdeaRejections {
  static let replacedReason = "Replaced by a later rejection of the same idea."

  /// idea-rejection.service.ts:36: records a declined op as the Notebook rejection of its idea; rejecting it again replaces the earlier scope rather than
  /// stacking a second entry. A `not_this_version` anchor binds the version the author sees, so this device's working copy of a draft it names is committed first, as an approval's is; the anchor then holds against the committed state the chat context compares.
  @discardableResult
  static func reject(
    proposal: UUID, opIndex: Int, scope: LedgerRejectionScope, why: String? = nil, novel: UUID, in transaction: inout WriteTransaction
  ) throws(IdeaRejectionError) -> NotebookEntryRecord {
    let op = try change(opIndex, of: proposal, novel: novel, in: transaction)
    if isActionOp(op) { throw .notAnIdea }
    let refs = changeSetRefs([op])
    if scope == .notThisVersion, refs.isEmpty { throw .touchesNoRecord }
    if let why, why.jsLength > NotebookLimits.why { throw .notebook(.tooLong(field: "why", limit: NotebookLimits.why)) }
    guard let ideas = IdeaIdentity.shared else { throw .ideaIdsUnavailable }
    let ideaId = ideas.ideaId(of: op)
    let anchor = try anchor(scope, refs: refs, novel: novel, in: &transaction)
    let idea = NotebookIdeaRejection(ideaId: ideaId, scope: scope, anchor: anchor)
    let statement = ideaLabel(op) ?? ""
    let active = try activeRejections(of: ideaId, novel: novel, in: transaction)
    do throws(NotebookError) {
      guard let latest = active.last else {
        let entry = NewNotebookEntry(kind: .rejected, topic: NotebookTopics.idea(ideaId), statement: statement, why: why, decidedBy: .author, idea: idea)
        return try Notebook.record(entry, novel: novel, in: &transaction)
      }
      for duplicate in active.dropLast() { try Notebook.withdraw(duplicate.id, reason: replacedReason, novel: novel, in: &transaction) }
      return try Notebook.supersede(
        latest.id, with: NotebookSuccessor(kind: .rejected, decidedBy: .author, statement: statement, why: why, idea: idea), novel: novel, in: &transaction)
    } catch {
      throw .notebook(error)
    }
  }

  /// idea-rejection.service.ts:68: takes back the author's rejection of an idea they have since adopted; nothing when none is active.
  @discardableResult
  static func withdrawRejection(of op: ChangeOp, reason: String, novel: UUID, in transaction: inout WriteTransaction) throws(IdeaRejectionError)
    -> [NotebookWithdrawalRecord]
  {
    guard let ideas = IdeaIdentity.shared else { throw .ideaIdsUnavailable }
    var withdrawn = [NotebookWithdrawalRecord]()
    for entry in try activeRejections(of: ideas.ideaId(of: op), novel: novel, in: transaction) {
      do throws(NotebookError) {
        withdrawn.append(try Notebook.withdraw(entry.id, reason: reason, novel: novel, in: &transaction))
      } catch {
        throw .notebook(error)
      }
    }
    return withdrawn
  }

  // idea-rejection.service.ts:37-40
  private static func change(_ index: Int, of proposal: UUID, novel: UUID, in transaction: borrowing WriteTransaction) throws(IdeaRejectionError) -> ChangeOp {
    let reading: RecordReading<ProposalRecord>
    do throws(StoreError) {
      reading = try ProposalRecord.read(id: proposal, in: transaction)
    } catch {
      throw .store(error)
    }
    switch reading {
    case .absent:
      throw .proposalNotFound(proposal)
    case .unreadable:
      throw .proposalUnreadable(proposal)
    case .readable(let entry):
      guard entry.record.novel == novel else { throw .proposalNotFound(proposal) }
      let ops = entry.record.card.changeSet
      guard ops.indices.contains(index) else { throw .noChange(opIndex: index) }
      guard let op = ops[index].op else { throw .changeUnreadable(opIndex: index) }
      return op
    }
  }

  // idea-rejections.ts:42 over loadRejectionContext (idea-rejections.ts:56)
  private static func anchor(_ scope: LedgerRejectionScope, refs: [String], novel: UUID, in transaction: inout WriteTransaction) throws(IdeaRejectionError) -> JSONValue? {
    let context: RejectionContext
    switch scope {
    case .never:
      return nil
    case .notNow:
      let volumes: RecordListing<VolumeRecord>
      do throws(StoreError) {
        volumes = try VolumeRecord.listing(novel: novel, in: transaction)
      } catch {
        throw .store(error)
      }
      guard volumes.unreadable == 0 else { throw .volumesUnreadable }
      context = RejectionContext(activeVolumeKey: activeVolume(of: volumes.live))
    case .notThisVersion:
      do throws(ApplyError) {
        try DraftHandlers.settleWorkingCopies(chapters: DraftReadThrough.draftChapters(of: refs), novel: novel, in: &transaction)
      } catch {
        switch error {
        case .domain(let error): throw .domain(error)
        case .store(let error): throw .store(error)
        default: throw .recordUnreadable(refs.first ?? "")
        }
      }
      let states: [JSString: ArtifactState]
      do throws(StoreError) {
        states = try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction)
      } catch {
        throw .store(error)
      }
      if let unreadable = refs.first(where: { states[JSString($0)]?.isUnreadable == true }) { throw .recordUnreadable(unreadable) }
      context = RejectionContext(activeVolumeKey: nil, states: states)
    }
    guard let anchor = rejectionAnchor(scope, context, refs: refs), let stored = anchor.json.storable else { throw .unstorableAnchor }
    return stored
  }

  private static func activeRejections(of ideaId: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(IdeaRejectionError) -> [NotebookEntry] {
    do throws(StoreError) {
      return try NotebookLedger.load(novel: novel, in: transaction).active(matching: NotebookFilter(topics: [NotebookTopics.idea(ideaId)]))
    } catch {
      throw .store(error)
    }
  }
}

extension VaultStore {
  /// Turns down change `opIndex` of a card in the Notebook (idea-rejection.service.ts:36), replacing an earlier rejection of the same idea.
  @discardableResult
  public func rejectIdea(proposal: UUID, opIndex: Int, scope: LedgerRejectionScope, why: String? = nil, novel: UUID) async throws(IdeaRejectionError)
    -> NotebookEntryRecord
  {
    do {
      return try await write { transaction in
        try NotebookIdeaRejections.reject(proposal: proposal, opIndex: opIndex, scope: scope, why: why, novel: novel, in: &transaction)
      }
    } catch {
      if case .aborted(let cause) = error, let rejection = cause as? IdeaRejectionError { throw rejection }
      throw .store(error)
    }
  }
}
