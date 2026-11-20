import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

/// The chapter lifecycle recomputed from the records alone, in ascending chapter order, after `ChapterFingerprint`'s rules 2 to 7: what each chapter rests on and
/// teaches, its first stale cause with the kind of change it names, the digest of what differs from what its head recorded, and the approval in force. The
/// JSON documents that digest covers are written out here rather than taken from the lifecycle.
enum ChapterOracle {
  struct Cause: Equatable, CustomStringConvertible {
    let code: String
    let chapter: Int?
    let detail: String?

    init(code: String, chapter: Int? = nil, detail: String? = nil) {
      self.code = code
      self.chapter = chapter
      self.detail = detail
    }

    init(_ cause: StaleCause) {
      self.init(code: cause.code, chapter: cause.chapter, detail: cause.code == "reveal" ? nil : cause.detail)
    }

    var description: String { code + (chapter.map { "@\($0)" } ?? "") + (detail.map { " (\($0))" } ?? "") }
  }

  struct Difference {
    let cause: Cause
    let json: JSONValue
  }

  struct State {
    let isFinal: Bool
    let resting: String?
    let canonDigest: String?
    let teaches: String?
    let planLearns: String?
    let differences: [Difference]
    let digest: String?
    let stale: Cause?
    let inForce: UUID?
    let review: DraftReviewState?
  }

  static func states(_ records: NovelRecords, violated: Set<Int>) -> [Int: State] {
    var states = [Int: State]()
    let chapters = Set(records.finals.keys).union(records.heads.keys).union(records.plans.keys).sorted()
    for chapter in chapters {
      if let final = records.finals[chapter] {
        states[chapter] = State(
          isFinal: true, resting: final.canon.draftRevision, canonDigest: final.canonDigest, teaches: ChapterFingerprint.learns(final.canon.contract), planLearns: nil,
          differences: [], digest: nil, stale: nil, inForce: nil, review: .final)
        continue
      }
      let generating = records.generating.contains(chapter)
      let plan = records.plans[chapter]
      let (learns, terms) = (ChapterFingerprint.learns(plan ?? ChapterContract()), ChapterFingerprint.planTerms(plan))
      guard let head = records.heads[chapter] else {
        states[chapter] = State(
          isFinal: false, resting: nil, canonDigest: nil, teaches: nil, planLearns: learns, differences: [], digest: nil, stale: nil, inForce: nil,
          review: generating ? .generating : nil)
        continue
      }
      let differences = differences(of: chapter, upstream: records.upstreams[chapter] ?? nil, records, states)
      let digest = differences.isEmpty ? nil : ChapterFingerprint.digest(.array(differences.map(\.json)))
      let ofHead = records.approvals.map(\.record).filter { $0.chapter == chapter && $0.approvalKind.known != nil && $0.draftRevision == head }
      let accepted = digest.map { digest in ofHead.contains { $0.approvalKind == .known(.asWritten) && $0.upstreamDigest == digest } } ?? false
      let stale = (accepted ? nil : differences.first?.cause) ?? (violated.contains(chapter) ? Cause(code: "reveal") : nil)
      let teaches = stale == nil && ofHead.contains { $0.planTermsDigest.flatMap(ChapterFingerprint.learnsPart(of:)).map(String.init) == learns }
      let approvals = records.approvals.filter { $0.record.chapter == chapter && $0.record.approvalKind.known != nil && $0.record.draftRevision == head }
      let held = holds(records.judges[chapter], head: head, body: records.bodies[chapter], approvals: approvals)
      let reset = resetClock(records, chapter: chapter, head: head, approvals: approvals)
      let standing = approvals.filter { approval in reset.map { approval.clock > $0 } ?? true }.map(\.record)
      let inForce = stale == nil && !held && !generating ? standing.last { $0.planTermsDigest == terms }?.id : nil
      states[chapter] = State(
        isFinal: false, resting: head, canonDigest: nil, teaches: teaches ? learns : nil, planLearns: learns, differences: differences, digest: digest, stale: stale,
        inForce: inForce, review: generating ? .generating : held ? .contradiction : inForce == nil ? .needsReview : .approved)
    }
    return states
  }

  /// chapter-review.service.ts:498-520 and chapter-generation.graph.ts:259-266, 890-902, restated: the latest judge review of the head as it stands holds it
  /// while a blocking finding is open, unless it is a generation pass nobody answered, which holds when its route did and no approval of the head came after.
  private static func holds(_ judge: JudgeRecord?, head: String, body: String?, approvals: [AppendedEntry<ApprovalRecord>]) -> Bool {
    guard let judge, let body, judge.entry.record.draftRevision == head, judge.entry.record.bodyHash == hashReviewedBody(body) else { return false }
    let review = judge.entry.record
    guard review.generationPass, !judge.answered else {
      return review.findings.contains { finding in
        guard finding.severity == .known(.blocking) else { return false }
        guard let action = judge.remedies[finding.id]?.action else { return true }
        return action == .known(.fixingMyself)
      }
    }
    let accepted =
      review.verdict == "consistent"
      && review.findings.allSatisfy { finding in
        switch (finding.category.known, finding.severity.known) {
        case (.continuity?, _?), (.readability?, _?), (.mechanics?, .note?): true
        default: false
        }
      }
    return !accepted && !approvals.contains { $0.clock > judge.entry.clock }
  }

  /// chapter-review.service.ts:508-513: a manual judge review of the head that held the draft when recorded, on the remedies written up to its clock, leaves
  /// every earlier approval out of force for good.
  private static func resetClock(_ records: NovelRecords, chapter: Int, head: String, approvals: [AppendedEntry<ApprovalRecord>]) -> HLCTimestamp? {
    guard let body = records.bodies[chapter], let earliest = approvals.map(\.clock).min() else { return nil }
    let held = (records.judgeReviews[chapter] ?? []).filter { review in
      let record = review.record
      guard !record.generationPass, record.draftRevision == head, record.bodyHash == hashReviewedBody(body), review.clock > earliest else { return false }
      return record.findings.contains { finding in
        guard finding.severity == .known(.blocking) else { return false }
        guard let register = records.remedyRegisters[record.id]?[finding.id], register.clock <= review.clock, let action = register.remedy?.action else { return true }
        return action == .known(.fixingMyself)
      }
    }
    return held.map(\.clock).max()
  }

  private static func differences(of chapter: Int, upstream: DraftUpstream?, _ records: NovelRecords, _ earlier: [Int: State]) -> [Difference] {
    guard let upstream, upstream.fits(chapter: chapter) else {
      Issue.record("a draft of chapter \(chapter) records no readable upstream, which no domain operation writes; Chapters/LifecycleScenarioTests covers it")
      return [Difference(cause: Cause(code: "unrecorded"), json: .null)]
    }
    return upstream.entries.flatMap { entry -> [Difference] in
      let ancestor = earlier[entry.chapter]
      switch entry {
      case .canon(let chapter, let digest):
        let current = ancestor?.isFinal == true ? ancestor?.canonDigest : nil
        guard current != digest else { return [] }
        return [Difference(cause: Cause(code: "canon", chapter: chapter), json: .object(["chapter": number(chapter), "canon": text(current)]))]
      case .draft(let chapter, let revision, let taught):
        var found = [Difference]()
        if ancestor?.resting != revision {
          let change =
            ancestor?.isFinal == true ? "finalized" : ancestor?.resting == nil ? "removed" : revision == nil ? "drafted" : "rewritten:\(records.sources[chapter] ?? "")"
          found.append(Difference(cause: Cause(code: "draft", chapter: chapter, detail: change), json: .object(["chapter": number(chapter), "draft": text(ancestor?.resting)])))
        }
        if let taught, ancestor?.teaches != taught {
          let lost = ancestor.map { !$0.isFinal && $0.teaches == nil && $0.planLearns == taught } ?? false
          found.append(
            Difference(
              cause: Cause(code: "knowledge", chapter: chapter, detail: lost ? "lost" : "changed"), json: .object(["chapter": number(chapter), "taught": text(ancestor?.teaches)])))
        }
        return found
      }
    }
  }

  private static func number(_ value: Int) -> JSONValue { .int(Int64(value)) }

  private static func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}
