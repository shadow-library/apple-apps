import Foundation
import ShadowCore

/// A draft's review status (apps/novel-forge-server/src/database/schemas/generation.ts:36), which the reference stores and this derives in the order its writes
/// override one another: final (chapter-finalization.graph.ts:183; persistDraft never writes over it, chapter-generation.graph.ts:190), then generating (an
/// open generate job; persistDraft sets it over any other status, :171-184, and the review gate skips it, chapter-review.service.ts:535), then contradiction
/// (the gate holds an approved draft too, :515-518), then approved, then needs review.
public enum DraftReviewState: String, Codable, CaseIterable, Sendable {
  case generating
  case needsReview = "needs_review"
  case contradiction
  case approved
  case final
}

/// The latest judge review of an unfinalized chapter that read the head as it stands (apps/novel-forge-server/src/modules/review/review-records.ts:151).
struct HeadJudgement: Equatable {
  let review: UUID
  let clock: HLCTimestamp
  /// The blocking findings no remedy settled.
  let openBlocking: Int
  /// For a generation pass none of whose findings has a remedy, whether its own route held the draft (chapter-generation.graph.ts:711, 890-902): recording it
  /// runs no gate (review-records.ts:47-72). Nil for any other review, which the gate decides on open blocking findings (chapter-review.service.ts:196, 208,
  /// 273).
  let outcome: Bool?
}

enum PlanTermsReading: Equatable {
  case terms(learns: String, terms: String)
  case unreadable

  static let empty = PlanTermsReading.terms(learns: ChapterFingerprint.learns(pov: [], learns: []), terms: ChapterFingerprint.planTerms(nil))
}

/// One novel's chapters as the lifecycle reads them from the layers before it.
struct LifecycleInputs {
  var finals: [Int: FinalChapterEntry] = [:]
  var drafts: [Int: ChapterDraftEntry] = [:]
  /// The recorded upstream of each unfinalized draft that records one this version can read.
  var upstreams: [Int: DraftUpstream] = [:]
  /// Chronological per chapter.
  var approvals: [Int: [ChapterApprovalEntry]] = [:]
  /// Unfinalized chapters whose plan is not removed; any other unfinalized chapter has empty terms.
  var plans: [Int: PlanTermsReading] = [:]
  /// The learns digest of each final chapter with a readable canon contract that some draft recorded before it was final.
  var canonLearns: [Int: String] = [:]
  /// The rendered violations of each plan that fails the reveal rule.
  var reveals: [Int: String] = [:]
  /// Chapters with an open generate job, queued or running (generation.service.ts:242-243 counts `pending` and `in_progress` alike); generating lasts the whole
  /// open job, from its request, where the reference starts it at persistDraft's first write.
  var generating: Set<Int> = []
  var judgements: [Int: HeadJudgement] = [:]
  /// The clock of the latest judge review of the head that held the draft when it was recorded, after an approval of the head: the gate lifts a hold to needs
  /// review and never gives an approval back (chapter-review.service.ts:508-513), so only a later approval is in force. Known gap: answering a carried remedy
  /// again moves its clock past the review's and can revoke the approval, where the reference only lifts a contradiction; keeping a remedy's first-set clock
  /// closes it (follow-up with G24).
  var resets: [Int: HLCTimestamp] = [:]
}

/// What one chapter is, after the rules of `ChapterFingerprint`.
struct ChapterState: Equatable {
  let chapter: Int
  let isFinal: Bool
  let draft: String?
  let resting: String?
  let canonDigest: String?
  let taught: String?
  /// The learns digest of an unfinalized chapter's plan head, approved or not; nil for a final chapter or an unreadable plan.
  let planLearns: String?
  let review: DraftReviewState?
  /// Nil while the chapter is generating or held as a contradiction, both of which revoke what the approval ledgered (chapter-generation.graph.ts:197,
  /// chapter-review.service.ts:519); a job that ends without moving the head gives it back.
  let approval: ChapterApprovalEntry?
  let stale: StaleCause?
  let planStale: StaleCause?
  let differences: String?
  let judgement: HeadJudgement?
}

private struct UpstreamDifference {
  let cause: StaleCause
  let json: JSONValue
}

enum ChapterLifecycle {
  static func states(_ inputs: LifecycleInputs) -> [ChapterState] {
    var states = [Int: ChapterState]()
    let chapters = Set(inputs.finals.keys).union(inputs.drafts.keys).union(inputs.plans.keys).sorted()
    for chapter in chapters { states[chapter] = state(of: chapter, inputs, earlier: states) }
    return chapters.compactMap { states[$0] }
  }

  private static func state(of chapter: Int, _ inputs: LifecycleInputs, earlier: [Int: ChapterState]) -> ChapterState {
    let head = inputs.drafts[chapter]?.head
    if let final = inputs.finals[chapter] {
      return ChapterState(
        chapter: chapter, isFinal: true, draft: head, resting: final.draftRevision, canonDigest: final.canonDigest, taught: nil, planLearns: nil, review: .final,
        approval: nil, stale: nil, planStale: nil, differences: nil, judgement: nil)
    }
    let generating = inputs.generating.contains(chapter)
    let planStale = inputs.reveals[chapter].map(StaleCause.reveal(violations:))
    let plan = inputs.plans[chapter] ?? .empty
    var planLearns: String?
    if case .terms(let learns, _) = plan { planLearns = learns }
    guard inputs.drafts[chapter] != nil else {
      return ChapterState(
        chapter: chapter, isFinal: false, draft: nil, resting: nil, canonDigest: nil, taught: nil, planLearns: planLearns, review: generating ? .generating : nil,
        approval: nil, stale: nil, planStale: planStale, differences: nil, judgement: nil)
    }
    let unrecorded = UpstreamDifference(cause: .unrecorded, json: ["unrecorded": true, "upstream": snapshot(of: chapter, earlier).json])
    let differences = inputs.upstreams[chapter].flatMap { $0.fits(chapter: chapter) ? $0 : nil }.map { differencesOf($0, inputs, earlier) } ?? [unrecorded]
    let digest = differences.isEmpty ? nil : ChapterFingerprint.digest(.array(differences.map(\.json)))
    let ofHead = (inputs.approvals[chapter] ?? []).filter { $0.approvalKind != nil && head != nil && $0.draft == head }
    let accepted = digest.map { digest in ofHead.contains { $0.approvalKind == .asWritten && $0.upstream == digest } } ?? false
    let stale = (accepted ? nil : differences.first?.cause) ?? planStale
    var approval: ChapterApprovalEntry?
    var taught: String?
    if stale == nil, case .terms(let learns, let terms) = plan {
      let reset = inputs.resets[chapter]
      approval = ofHead.last { approval in approval.terms == terms && reset.map { approval.clock > $0 } ?? true }
      taught = ofHead.contains { $0.terms.flatMap(ChapterFingerprint.learnsPart(of:)).map(String.init) == learns } ? learns : nil
    }
    let judgement = inputs.judgements[chapter]
    let held =
      judgement.map { judgement in
        guard let outcome = judgement.outcome else { return judgement.openBlocking > 0 }
        return outcome && !ofHead.contains { $0.clock > judgement.clock }
      } ?? false
    let inForce = generating || held ? nil : approval
    let review: DraftReviewState = generating ? .generating : held ? .contradiction : inForce == nil ? .needsReview : .approved
    return ChapterState(
      chapter: chapter, isFinal: false, draft: head, resting: head, canonDigest: nil, taught: taught, planLearns: planLearns, review: review, approval: inForce,
      stale: stale, planStale: planStale, differences: digest, judgement: judgement)
  }

  private static let acceptedCategories: Set<ReviewFindingCategory> = [.continuity, .readability]

  /// Whether a generation pass ended held: routeAfterJudge (chapter-generation.graph.ts:259-266) accepts only a consistent verdict with no ending, brief,
  /// knowledge or hard mechanical finding, so any other run ends in awaitReview or acceptAsIs. Exact on the pass as the generation pipeline stores it: findings
  /// categorised by their source, the judge's own always continuity, and an issue line for a non-compliant block that names none. review-findings.ts:226
  /// categorises by text prefix and drops such a block, which loses the route. Readability, soft mechanics and continuity never hold; a finding this version
  /// cannot read does.
  static func outcomeHolds(verdict: String?, findings: [ReviewFinding]) -> Bool {
    guard let verdict, verdict.jsEquals("consistent") else { return true }
    return findings.contains { finding in
      guard let category = finding.category.known, let severity = finding.severity.known else { return true }
      if category == .mechanics { return severity == .warning }
      return !acceptedCategories.contains(category)
    }
  }

  private static func differencesOf(_ upstream: DraftUpstream, _ inputs: LifecycleInputs, _ earlier: [Int: ChapterState]) -> [UpstreamDifference] {
    upstream.entries.flatMap { entry -> [UpstreamDifference] in
      let now = earlier[entry.chapter]
      switch entry {
      case .canon(let chapter, let digest):
        let current = now?.isFinal == true ? now?.canonDigest : nil
        guard current != digest else { return [] }
        return [UpstreamDifference(cause: .canonReplaced(chapter: chapter), json: ["chapter": chapter.json, "canon": current.json])]
      case .draft(let chapter, let revision, let taught):
        var found = [UpstreamDifference]()
        let resting = now?.resting
        if resting != revision {
          let change: AncestorChange =
            if now?.isFinal == true { .finalized } else if resting == nil { .removed } else if revision == nil { .drafted } else {
              .rewritten(source: inputs.drafts[chapter]?.source)
            }
          found.append(UpstreamDifference(cause: .ancestorDraft(chapter: chapter, change: change), json: ["chapter": chapter.json, "draft": resting.json]))
        }
        let teaches = now?.isFinal == true ? inputs.canonLearns[chapter] : now?.taught
        if let taught, teaches != taught {
          // draft-staleness.ts:46 names a change of what the cast learns; plan-state.ts:142 an approval lost while the plan still teaches the same.
          let lost = teaches == nil && now?.isFinal != true && now?.planLearns == taught
          found.append(UpstreamDifference(cause: .ancestorKnowledge(chapter: chapter, lost: lost), json: ["chapter": chapter.json, "taught": teaches.json]))
        }
        return found
      }
    }
  }

  /// What rule 2 would record now for a draft of `chapter`, from the lifecycle of the chapters before it.
  static func snapshot(of chapter: Int, _ earlier: [Int: ChapterState]) -> DraftUpstream {
    guard chapter > 1 else { return DraftUpstream(entries: []) }
    let frontier = earlier.values.filter { $0.isFinal && $0.chapter < chapter }.map(\.chapter).max() ?? 0
    return DraftUpstream(
      entries: (max(frontier, 1)..<chapter).map { ancestor in
        guard let state = earlier[ancestor] else { return .draft(chapter: ancestor, revision: nil, taught: nil) }
        return state.isFinal ? .canon(chapter: ancestor, digest: state.canonDigest) : .draft(chapter: ancestor, revision: state.resting, taught: state.taught)
      })
  }
}
