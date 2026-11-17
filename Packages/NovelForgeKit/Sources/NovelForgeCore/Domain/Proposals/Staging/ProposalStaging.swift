import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:48-69 (CreateProposalInput). Deviations: the card stores no scope, so a plugin's
// supersession by scope (proposal.service.ts:86-87) is not ported; a plan pass card's diagnostics (plan-diagnostics.ts:216) come from the caller.
struct ProposalStagingInput: Sendable {
  var novel: UUID
  var session: UUID?
  var message: UUID?
  var kind: ProposalKind
  var summary: String?
  var changeSet: ValidatedChangeSet
  var run: String?
  /// Precomputed by a caller that already ran the checks with more context; they replace only the negation-echo review.
  var warnings: [String]?
  var sourceIsolated = false
  /// States read before the change set was written, so an edit made meanwhile conflicts at apply; read now otherwise.
  var baseline: ArtifactStates?
  /// A plan pass card's typed findings (plan-diagnostics.ts:216), computed by the pipeline that stages it; ignored for every other kind.
  var planDiagnostics: [ProposalDiagnostic] = []

  init(
    novel: UUID, session: UUID? = nil, message: UUID? = nil, kind: ProposalKind, summary: String? = nil, changeSet: ValidatedChangeSet, run: String? = nil,
    warnings: [String]? = nil
  ) {
    self.novel = novel
    self.session = session
    self.message = message
    self.kind = kind
    self.summary = summary
    self.changeSet = changeSet
    self.run = run
    self.warnings = warnings
  }
}

struct StagedProposal: Sendable, Equatable {
  let proposal: ProposalRecord
  /// The pending cards of the session this one replaced, raised to superseded in the same transaction; the card lists them as provenance only.
  let superseded: [UUID]
}

enum ProposalStager {
  /// proposal.service.ts:138: a pending card with a freshly captured baseline that supersedes the session's pending cards touching the same records or action
  /// decisions, in one transaction. The baseline, the anchors and the warnings read each draft through this device's working copy, as the apply's settle
  /// will commit it, without writing it; only a chapter an approval binds to has its copy committed first, so the approval names a real revision.
  static func stage(_ input: ProposalStagingInput, id: UUID = UUID(), in transaction: inout WriteTransaction) throws(ProposalStagingError) -> StagedProposal {
    let original = input.changeSet.ops
    if input.kind == .plugin {
      let problems = validatePluginChangeSet(.array(original.map { .object($0.fields) })).errors
      guard problems.isEmpty else { throw .notAllowed(problems: problems) }
    }
    do throws(DomainError) {
      try transaction.requireNovel(input.novel)
    } catch {
      throw .domain(error)
    }
    guard let ideas = IdeaIdentity.shared else { throw .ideaIdsUnavailable }
    let novel = input.novel
    try ProposalStamps.requireCopiesOverHeads(ProposalStamps.approvalChapters(original), novel: novel, in: transaction)
    do throws(ApplyError) {
      try DraftHandlers.settleWorkingCopies(chapters: ProposalStamps.approvalChapters(original), novel: novel, in: &transaction)
    } catch {
      throw .draft(error)
    }

    let trusted = input.kind == .chapterPlan ? original : ProposalStamps.withoutStartedEmpty(original)
    let drafts = try ProposalStamps.rewriteDrafts(PassageAnchoring.rewriteChapters(trusted), novel: novel, in: transaction)
    let anchored = try PassageAnchoring.stamp(trusted, drafts: drafts)
    let approvals = try ProposalStamps.approvalStamps(ProposalStamps.approvalChapters(anchored), novel: novel, in: transaction)
    let changeSet = ProposalStamps.approvalRevisions(ideas.stampIdeaIds(anchored), stamps: approvals)
    let refs = changeSetRefs(changeSet)
    let readThrough: [Int: DraftRecord]
    do throws(ApplyError) {
      readThrough = try DraftReadThrough.records(DraftReadThrough.draftChapters(of: refs), novel: novel, in: transaction)
    } catch {
      throw .draft(error)
    }
    let baseline = try baseline(of: refs, supplied: input.baseline, novel: novel, drafts: readThrough, in: transaction)
    let review = input.warnings ?? reviewWarnings(original, novel: novel, drafts: readThrough, in: transaction)
    let others = review + revealClearWarnings(original, novel: novel, in: transaction)
    let diagnostics = ProposalWarnings.diagnostics(
      others: others + (input.sourceIsolated ? [isolatedSourceWarning] : []), plan: input.kind == .chapterPlan ? input.planDiagnostics : [])

    var replaced = [ProposalRecord]()
    if let session = input.session {
      do throws(StoreError) {
        replaced = try ProposalSupersession.pendingCards(novel: novel, session: session, in: transaction).filter {
          ProposalSupersession.overlaps(older: $0.card.ops.compactMap { $0 }, newer: changeSet, drafts: drafts)
        }
      } catch {
        throw .store(error)
      }
    }
    let card: ProposalCard
    do throws(ProposalRecordError) {
      card = try ProposalCard(
        novel: novel, session: input.session, message: input.message, kind: .known(input.kind), summary: input.summary, changeSet: changeSet, baseline: baseline,
        warnings: diagnostics.map(\.message), diagnostics: diagnostics, supersedes: replaced.map(\.id), run: input.run)
    } catch {
      throw .unstorable(error)
    }
    let proposal = ProposalRecord(id: id, card: card)
    do throws(StoreError) {
      _ = try proposal.create(in: &transaction)
      for older in replaced { _ = try ProposalRecord.dismiss(older.ref, as: .superseded, in: &transaction) }
    } catch {
      throw .store(error)
    }
    return StagedProposal(proposal: proposal, superseded: replaced.map(\.id))
  }

  // proposal.service.ts:74 (pickBaseline) and :146
  private static func baseline(
    of refs: [String], supplied: ArtifactStates?, novel: UUID, drafts: [Int: DraftRecord], in transaction: borrowing WriteTransaction
  ) throws(ProposalStagingError) -> ArtifactStates {
    if let supplied { return ArtifactStates(Dictionary(refs.map { (JSString($0), supplied[$0] ?? .missing) }) { first, _ in first }) }
    do throws(StoreError) {
      return ArtifactStates(try DraftReadThrough.states(refs: refs, novel: novel, drafts: drafts, in: transaction))
    } catch {
      throw .store(error)
    }
  }

  // proposal.service.ts:185: advisory, so a check that cannot run costs the author no proposal
  private static func reviewWarnings(_ ops: [ChangeOp], novel: UUID, drafts: [Int: DraftRecord], in transaction: borrowing WriteTransaction) -> [String] {
    do throws(StoreError) {
      return ProposalWarnings.negationEchoes(ops, baselines: try ProposalWarnings.baselineTexts(ops, novel: novel, drafts: drafts, in: transaction)) ?? []
    } catch {
      return []
    }
  }

  // proposal.service.ts:205
  private static func revealClearWarnings(_ ops: [ChangeOp], novel: UUID, in transaction: borrowing WriteTransaction) -> [String] {
    do throws(StoreError) {
      return ProposalWarnings.revealClears(ops, datedFacts: try ProposalWarnings.datedFacts(ops, novel: novel, in: transaction))
    } catch {
      return []
    }
  }
}
