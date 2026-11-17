import Foundation
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

/// The chapter lifecycle recomputed from the records alone, in ascending chapter order, after `ChapterFingerprint`'s rules 2 to 7: what each chapter rests on and
/// teaches, its first stale cause, and the approval in force. Only the digest an as-written approval accepts is taken from the lifecycle, since computing it
/// would repeat the derivation's JSON byte for byte.
enum ChapterOracle {
  struct Cause: Equatable, CustomStringConvertible {
    let code: String
    let chapter: Int?

    init(code: String, chapter: Int? = nil) {
      self.code = code
      self.chapter = chapter
    }

    init(_ cause: StaleCause) {
      self.init(code: cause.code, chapter: cause.chapter)
    }

    var description: String { chapter.map { "\(code)@\($0)" } ?? code }
  }

  struct State {
    let isFinal: Bool
    let resting: String?
    let canonDigest: String?
    let teaches: String?
    /// The differences from what the head recorded, in cause order; accepted or not.
    let differences: [Cause]
    let stale: Cause?
    let inForce: UUID?
  }

  static func states(_ records: NovelRecords, violated: Set<Int>, acceptedDigests: [Int: String]) -> [Int: State] {
    var states = [Int: State]()
    let chapters = Set(records.finals.keys).union(records.heads.keys).union(records.plans.keys).sorted()
    for chapter in chapters {
      if let final = records.finals[chapter] {
        states[chapter] = State(
          isFinal: true, resting: final.canon.draftRevision, canonDigest: final.canonDigest, teaches: ChapterFingerprint.learns(final.canon.contract), differences: [],
          stale: nil, inForce: nil)
        continue
      }
      guard let head = records.heads[chapter] else {
        states[chapter] = State(isFinal: false, resting: nil, canonDigest: nil, teaches: nil, differences: [], stale: nil, inForce: nil)
        continue
      }
      let plan = records.plans[chapter]
      let (learns, terms) = (ChapterFingerprint.learns(plan ?? ChapterContract()), ChapterFingerprint.planTerms(plan))
      let differences = differences(of: chapter, upstream: records.upstreams[chapter] ?? nil, states)
      let ofHead = records.approvals.map(\.record).filter { $0.chapter == chapter && $0.approvalKind.known != nil && $0.draftRevision == head }
      let accepted = !differences.isEmpty && ofHead.contains { $0.approvalKind == .known(.asWritten) && $0.upstreamDigest == acceptedDigests[chapter] }
      let stale = (accepted ? nil : differences.first) ?? (violated.contains(chapter) ? Cause(code: "reveal") : nil)
      let teaches = stale == nil && ofHead.contains { $0.planTermsDigest.flatMap(ChapterFingerprint.learnsPart(of:)).map(String.init) == learns }
      states[chapter] = State(
        isFinal: false, resting: head, canonDigest: nil, teaches: teaches ? learns : nil, differences: differences, stale: stale,
        inForce: stale == nil ? ofHead.last { $0.planTermsDigest == terms }?.id : nil)
    }
    return states
  }

  private static func differences(of chapter: Int, upstream: DraftUpstream?, _ earlier: [Int: State]) -> [Cause] {
    guard let upstream, upstream.fits(chapter: chapter) else { return [Cause(code: "unrecorded")] }
    return upstream.entries.flatMap { entry -> [Cause] in
      let ancestor = earlier[entry.chapter]
      switch entry {
      case .canon(let chapter, let digest):
        return (ancestor?.isFinal == true ? ancestor?.canonDigest : nil) == digest ? [] : [Cause(code: "canon", chapter: chapter)]
      case .draft(let chapter, let revision, let taught):
        var found = [Cause]()
        if ancestor?.resting != revision { found.append(Cause(code: "draft", chapter: chapter)) }
        if let taught, ancestor?.teaches != taught { found.append(Cause(code: "knowledge", chapter: chapter)) }
        return found
      }
    }
  }
}
