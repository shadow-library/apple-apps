import Foundation

// apps/novel-forge-server/src/common/draft-staleness.ts:9
let revealStalePrefix = "a reveal in this plan no longer holds: "

/// How an ancestor's prose differs from what a draft rests on; `rewritten` carries the new head's stored source.
public enum AncestorChange: Sendable, Hashable {
  case drafted
  case rewritten(source: String?)
  case removed
  case finalized
}

/// Why a draft or plan is stale, ordered as `ChapterFingerprint` rule 5 lists the causes.
public enum StaleCause: Sendable, Hashable {
  case unrecorded
  case canonReplaced(chapter: Int)
  case ancestorDraft(chapter: Int, change: AncestorChange)
  case ancestorKnowledge(chapter: Int, lost: Bool)
  case reveal(violations: String)

  public var chapter: Int? {
    switch self {
    case .canonReplaced(let chapter), .ancestorDraft(let chapter, _), .ancestorKnowledge(let chapter, _): chapter
    case .unrecorded, .reveal: nil
    }
  }

  /// The reference's wording where it has one (draft-staleness.ts:46, plan-state.ts:94 and 142, draft-save.ts:16, generation.service.ts:441 and 758).
  public var reason: String {
    switch self {
    case .unrecorded: "the draft does not record what it was written against"
    case .canonReplaced(let chapter): "ancestor chapter \(chapter)'s final text was replaced"
    case .ancestorDraft(let chapter, let change): "ancestor chapter \(chapter) \(Self.phrase(change))"
    case .ancestorKnowledge(let chapter, true): "ancestor chapter \(chapter) lost its approval"
    case .ancestorKnowledge(let chapter, false): "ancestor chapter \(chapter)'s plan changed what its cast learns after approval"
    case .reveal(let violations): revealStalePrefix + violations
    }
  }

  private static func phrase(_ change: AncestorChange) -> String {
    switch change {
    case .drafted: return "was drafted"
    case .removed: return "was removed"
    case .finalized: return "was finalized from another revision"
    case .rewritten(let source):
      switch source.flatMap(DraftSource.init(rawValue:)) {
      case .generated?, .patched?, .rewritten?: return "was regenerated"
      case .revised?, .amended?: return "was revised"
      case .chatEdited?: return "was chat_edited"
      case .handEdited?: return "was hand_edited"
      case .imported?: return "was imported"
      case .restored?: return "was restored to an earlier version"
      case .passageRewritten?: return "had a passage rewritten"
      case nil: return "was changed"
      }
    }
  }
}

/// How a cause is stored: a code, the chapter it names and what else it carries.
extension StaleCause {
  var code: String {
    switch self {
    case .unrecorded: "unrecorded"
    case .canonReplaced: "canon"
    case .ancestorDraft: "draft"
    case .ancestorKnowledge: "knowledge"
    case .reveal: "reveal"
    }
  }

  var detail: String? {
    switch self {
    case .unrecorded, .canonReplaced: nil
    case .ancestorDraft(_, .drafted): "drafted"
    case .ancestorDraft(_, .removed): "removed"
    case .ancestorDraft(_, .finalized): "finalized"
    case .ancestorDraft(_, .rewritten(let source)): "rewritten:\(source ?? "")"
    case .ancestorKnowledge(_, let lost): lost ? "lost" : "changed"
    case .reveal(let violations): violations
    }
  }

  init?(code: String, chapter: Int?, detail: String?) {
    switch (code, chapter, detail) {
    case ("unrecorded", nil, nil): self = .unrecorded
    case ("canon", let chapter?, nil): self = .canonReplaced(chapter: chapter)
    case ("knowledge", let chapter?, "lost"?): self = .ancestorKnowledge(chapter: chapter, lost: true)
    case ("knowledge", let chapter?, "changed"?): self = .ancestorKnowledge(chapter: chapter, lost: false)
    case ("reveal", nil, let violations?): self = .reveal(violations: violations)
    case ("draft", let chapter?, let detail?):
      switch detail {
      case "drafted": self = .ancestorDraft(chapter: chapter, change: .drafted)
      case "removed": self = .ancestorDraft(chapter: chapter, change: .removed)
      case "finalized": self = .ancestorDraft(chapter: chapter, change: .finalized)
      default:
        guard detail.hasPrefix("rewritten:") else { return nil }
        let source = String(detail.dropFirst("rewritten:".count))
        self = .ancestorDraft(chapter: chapter, change: .rewritten(source: source.isEmpty ? nil : source))
      }
    default: return nil
    }
  }
}
