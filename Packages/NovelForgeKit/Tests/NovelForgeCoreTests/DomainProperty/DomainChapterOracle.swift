import Foundation
import ShadowCore
import ShadowStore
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
  }

  static func states(_ records: NovelRecords, violated: Set<Int>) -> [Int: State] {
    var states = [Int: State]()
    let chapters = Set(records.finals.keys).union(records.heads.keys).union(records.plans.keys).sorted()
    for chapter in chapters {
      if let final = records.finals[chapter] {
        states[chapter] = State(
          isFinal: true, resting: final.canon.draftRevision, canonDigest: final.canonDigest, teaches: ChapterFingerprint.learns(final.canon.contract), planLearns: nil,
          differences: [], digest: nil, stale: nil, inForce: nil)
        continue
      }
      let plan = records.plans[chapter]
      let (learns, terms) = (ChapterFingerprint.learns(plan ?? ChapterContract()), ChapterFingerprint.planTerms(plan))
      guard let head = records.heads[chapter] else {
        states[chapter] = State(
          isFinal: false, resting: nil, canonDigest: nil, teaches: nil, planLearns: learns, differences: [], digest: nil, stale: nil, inForce: nil)
        continue
      }
      let differences = differences(of: chapter, upstream: records.upstreams[chapter] ?? nil, records, states)
      let digest = differences.isEmpty ? nil : ChapterFingerprint.digest(.array(differences.map(\.json)))
      let ofHead = records.approvals.map(\.record).filter { $0.chapter == chapter && $0.approvalKind.known != nil && $0.draftRevision == head }
      let accepted = digest.map { digest in ofHead.contains { $0.approvalKind == .known(.asWritten) && $0.upstreamDigest == digest } } ?? false
      let stale = (accepted ? nil : differences.first?.cause) ?? (violated.contains(chapter) ? Cause(code: "reveal") : nil)
      let teaches = stale == nil && ofHead.contains { $0.planTermsDigest.flatMap(ChapterFingerprint.learnsPart(of:)).map(String.init) == learns }
      states[chapter] = State(
        isFinal: false, resting: head, canonDigest: nil, teaches: teaches ? learns : nil, planLearns: learns, differences: differences, digest: digest, stale: stale,
        inForce: stale == nil ? ofHead.last { $0.planTermsDigest == terms }?.id : nil)
    }
    return states
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
