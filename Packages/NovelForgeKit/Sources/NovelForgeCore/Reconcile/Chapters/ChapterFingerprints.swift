import Foundation
import ShadowCore

/// The fingerprints a chapter's revisions and approvals record, and how the chapter lifecycle compares them with the current state. Every digest is the lowercase
/// sha256 hex of the UTF-8 of an RFC 8785 canonical JSON value; keys are NFC; a set is deduplicated and sorted by UTF-16 code units, as JavaScript's `sort` does.
///
/// 1. Plan terms (`approval.plan_terms_digest`, apps/novel-forge-server/src/common/draft-staleness.ts:19-38). The learns digest hashes `[[entity, fact], …]`, the
///    pairs sorted by entity then fact and counted only when the contract names a POV (knowledge-contract.ts:16); the milestones digest hashes `[key, …]` of the
///    claimed milestones. The terms digest is `<learns digest>:<milestones digest>`. A chapter without a plan, or whose plan is removed, has empty terms; an
///    unreadable plan head has none.
/// 2. Draft upstream (the `upstream` member of every draft revision body). For chapter N, with F the latest final chapter below N (0 when none), one entry per
///    chapter M from max(F, 1) to N - 1: a final M records `{"chapter", "canon"}` with its canon digest (`FinalChapterRecord.digest` of the stored canon);
///    any other M records `{"chapter", "draft", "taught"}`: the revision M rests on (its draft head, null without a live draft) and what M teaches (below).
///    A final chapter's resting revision is its canon's `draft_revision`; what it teaches is the learns digest of its canon's contract. What an unfinalized
///    chapter teaches is the learns digest of its plan head while its draft has no stale mark and an approval of its draft head carries the same learns
///    digest; otherwise nothing (null). Chapters before F are history and are not recorded.
/// 3. Comparison. A canon entry differs when M's canon digest is no longer the recorded one. A draft entry's prose differs when M rests on another revision
///    than recorded; its knowledge differs when it recorded what M taught and M now teaches something else or nothing, so a chapter approved after the draft
///    was written never makes it stale; it names a lost approval only while M's plan still teaches what was recorded (plan-state.ts:142), else a change of
///    what M's cast learns (draft-staleness.ts:46). A head whose upstream is missing, unreadable or not of rule 2's exact shape has the single difference `unrecorded`,
///    which carries the upstream rule 2 would record now from the lifecycle, so accepting it binds to the ancestors as they stand. The differences, in cause
///    order, are digested as `[{"chapter", "canon" | "draft" | "taught": current value}, …]` or `[{"unrecorded": true, "upstream": <rule 2 document>}]`.
/// 4. Acceptance (`approval.upstream_digest`, written only on an `as_written` approval): the digest of the differences the author accepted. While the head's
///    differences digest to the value some `as_written` approval of that head recorded, they are accepted.
/// 5. Stale marks. A draft of an unfinalized chapter shows the lowest of its causes in this fixed order: `unrecorded`; then for each ancestor M ascending, its
///    canon or prose before its knowledge; then the chapter's own plan failing the reveal rule (D20's verdict, never accepted, DRF_017). Accepted differences
///    are no cause. A plan's only cause is the reveal rule (plan-state.ts:111), so plans record no fingerprint.
/// 6. Approval in force: of an unfinalized chapter whose draft has no stale mark, the latest approval (clock, then id) of a known kind whose draft revision is the
///    draft head and whose plan terms digest is the plan head's.
/// 7. Review status: `final` when the canon exists, `approved` with an approval in force, `needs_review` for any other live draft.
public enum ChapterFingerprint {
  public static let separator: Character = ":"

  /// The `plan_terms_digest` an approval of this plan head records; pass nil for no plan or a removed one.
  public static func planTerms(_ contract: ChapterContract?) -> String {
    guard let contract else { return terms(pov: [], learns: [], claims: []) }
    return terms(pov: contract.pov, learns: contract.reveals.map { ($0.entityKey, $0.factKey) }, claims: contract.claimedMilestones)
  }

  public static func learns(_ contract: ChapterContract) -> String {
    learns(pov: contract.pov, learns: contract.reveals.map { ($0.entityKey, $0.factKey) })
  }

  static func terms(pov: [String], learns pairs: [(String, String)], claims: [String]) -> String {
    "\(learns(pov: pov, learns: pairs))\(separator)\(digest(.array(sortedSet(claims.map(nfc)).map(JSONValue.string))))"
  }

  static func learns(pov: [String], learns pairs: [(String, String)]) -> String {
    let counted = pov.contains { !$0.isEmpty } ? pairs : []
    var seen = Set<[UInt16]>()
    let unique = counted.map { (nfc($0.0), nfc($0.1)) }.filter { seen.insert(Array("\($0.0)\u{0}\($0.1)".utf16)).inserted }
    let sorted = unique.sorted { left, right in
      left.0 == right.0 ? JSText.codeUnitPrecedes(left.1, right.1) : JSText.codeUnitPrecedes(left.0, right.0)
    }
    return digest(.array(sorted.map { .array([.string($0.0), .string($0.1)]) }))
  }

  /// The learns half of a recorded terms digest.
  static func learnsPart(of terms: String) -> Substring? {
    let parts = terms.split(separator: separator, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return parts[0]
  }

  static func digest(_ value: JSONValue) -> String {
    sha256Hex(String(decoding: CanonicalJSON.encode(value), as: UTF8.self))
  }

  private static func nfc(_ text: String) -> String { text.jsNormalize(.nfc) }

  private static func sortedSet(_ keys: [String]) -> [String] {
    keys.jsUnique().jsSorted()
  }
}

/// What a draft revision was written against (rule 2 of `ChapterFingerprint`).
public struct DraftUpstream: Sendable, Equatable {
  public enum Entry: Sendable, Equatable {
    case canon(chapter: Int, digest: String?)
    case draft(chapter: Int, revision: String?, taught: String?)

    public var chapter: Int {
      switch self {
      case .canon(let chapter, _), .draft(let chapter, _, _): chapter
      }
    }
  }

  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  /// Whether the entries have rule 2's shape for a draft of `chapter`: none for chapter 1; otherwise every chapter up to `chapter - 1` once, ascending, from chapter
  /// 1 or from a canon entry, the rest draft entries.
  func fits(chapter: Int) -> Bool {
    guard chapter > 1 else { return entries.isEmpty }
    guard let first = entries.first, first.chapter >= 1, entries.last?.chapter == chapter - 1 else { return false }
    guard zip(entries, entries.dropFirst()).allSatisfy({ $1.chapter == $0.chapter + 1 }) else { return false }
    guard entries.dropFirst().allSatisfy({ if case .draft = $0 { true } else { false } }) else { return false }
    if case .canon = first { return true }
    return first.chapter == 1
  }
}

private enum UpstreamMember: String, CaseIterable, FieldName {
  case chapters
}

private enum UpstreamEntryMember: String, CaseIterable, FieldName {
  case chapter
  case canon
  case draft
  case taught
}

extension DraftUpstream: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let items = json.objectValue?[UpstreamMember.chapters.rawValue]?.arrayValue else { return nil }
    var entries = [Entry]()
    for item in items {
      guard let members = item.objectValue, let chapter = members[UpstreamEntryMember.chapter.rawValue].flatMap(Int.init(json:)) else { return nil }
      let text = { (member: UpstreamEntryMember) -> String?? in
        guard let value = members[member.rawValue] else { return .none }
        if value.isNull { return .some(nil) }
        return value.stringValue.map { .some($0) }
      }
      switch (text(.canon), text(.draft)) {
      case (.some(let digest), .none) where members[UpstreamEntryMember.taught.rawValue] == nil:
        entries.append(.canon(chapter: chapter, digest: digest))
      case (.none, .some(let revision)):
        guard let taught = members[UpstreamEntryMember.taught.rawValue] == nil ? .some(nil) : text(.taught) else { return nil }
        entries.append(.draft(chapter: chapter, revision: revision, taught: taught))
      default:
        return nil
      }
    }
    self.init(entries: entries)
  }

  public var json: JSONValue {
    let items = entries.map { entry -> JSONValue in
      switch entry {
      case .canon(let chapter, let digest):
        [UpstreamEntryMember.chapter.rawValue: chapter.json, UpstreamEntryMember.canon.rawValue: digest.json]
      case .draft(let chapter, let revision, let taught):
        [UpstreamEntryMember.chapter.rawValue: chapter.json, UpstreamEntryMember.draft.rawValue: revision.json, UpstreamEntryMember.taught.rawValue: taught.json]
      }
    }
    return [UpstreamMember.chapters.rawValue: .array(items)]
  }
}
