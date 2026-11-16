import Foundation
import ShadowCore

/// A draft's review status as v1 records support it (apps/novel-forge-server/src/database/schemas/generation.ts:36). `generating` needs the job records of the
/// pipeline phase and `contradiction` the chapter reviews of the review phase.
public enum DraftReviewState: String, Codable, CaseIterable, Sendable {
  case needsReview = "needs_review"
  case approved
  case final
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
  let approval: ChapterApprovalEntry?
  let stale: StaleCause?
  let planStale: StaleCause?
  let differences: String?
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
        approval: nil, stale: nil, planStale: nil, differences: nil)
    }
    let planStale = inputs.reveals[chapter].map(StaleCause.reveal(violations:))
    let plan = inputs.plans[chapter] ?? .empty
    var planLearns: String?
    if case .terms(let learns, _) = plan { planLearns = learns }
    guard inputs.drafts[chapter] != nil else {
      return ChapterState(
        chapter: chapter, isFinal: false, draft: nil, resting: nil, canonDigest: nil, taught: nil, planLearns: planLearns, review: nil, approval: nil, stale: nil,
        planStale: planStale, differences: nil)
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
      approval = ofHead.last { $0.terms == terms }
      taught = ofHead.contains { $0.terms.flatMap(ChapterFingerprint.learnsPart(of:)).map(String.init) == learns } ? learns : nil
    }
    return ChapterState(
      chapter: chapter, isFinal: false, draft: head, resting: head, canonDigest: nil, taught: taught, planLearns: planLearns,
      review: approval == nil ? .needsReview : .approved,
      approval: approval, stale: stale, planStale: planStale, differences: digest)
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
