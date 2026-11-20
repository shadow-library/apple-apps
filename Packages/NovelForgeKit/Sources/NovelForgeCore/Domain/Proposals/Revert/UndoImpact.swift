import Foundation
import ShadowCore
import ShadowText

// apps/novel-forge-server/src/modules/refinement/undo-impact.ts:8
public enum UndoDependentKind: String, CaseIterable, Sendable {
  case plan
  case draft
  case knowledge
  case suggestion
}

// undo-impact.ts:10-19
public struct UndoDependent: Sendable, Equatable {
  public let kind: UndoDependentKind
  /// `chapter:<n>`, `draft:<n>`, `knowledge:<entityKey>/<factKey>` or `proposal:<id>`.
  public let ref: String
  public let chapter: Int?
  /// The undone record this one relies on.
  let because: String
  /// Finalized history, which undo never rewrites: the author sees it, the revert leaves it as it is.
  public let final: Bool
}

// undo-impact.ts:21-25
public struct UndoImpact: Sendable, Equatable {
  public let dependents: [UndoDependent]
  /// Finalized plans and drafts that only relied on an updated record: counted, not listed, since the undo leaves them exactly as they are.
  public let finalUnaffected: Int
  /// Plans, drafts, finals and pending suggestions of the novel this device cannot read, so the list may lack what relies on them.
  public internal(set) var unreadable = 0
}

// undo-impact.ts:28-31
struct UndoneChange: Sendable, Equatable {
  let created: [String]
  let updated: [String]
}

struct ImpactPlan: Sendable, Equatable {
  let chapter: Int
  /// undo-impact.ts:80-92: the records the plan names, as a `brief.update` carrying its fields would.
  let references: [String]
}

struct ImpactDraft: Sendable, Equatable {
  let chapter: Int
  let isFinal: Bool
}

struct ImpactKnowledge: Sendable, Equatable {
  let fact: String
  let entity: String
  let learnedInChapter: Int
  let isCommitted: Bool
}

struct ImpactSuggestion: Sendable, Equatable {
  let id: UUID
  /// undo-impact.ts:94-97: the refs of its baseline, then the records its ops name.
  let references: [String]
}

// undo-impact.ts:61-66
struct ImpactRows: Sendable, Equatable {
  var plans: [ImpactPlan] = []
  var drafts: [ImpactDraft] = []
  var knowledge: [ImpactKnowledge] = []
  var suggestions: [ImpactSuggestion] = []
}

enum UndoImpacts {
  private static let kindOrder = UndoDependentKind.allCases

  /// undo-impact.ts:75: a record whose change inverts to its removal was created; every other ref the change touched was updated.
  static func undoneChange(_ refs: [String], removed: [String]) -> UndoneChange {
    let created = Set(removed.map { JSString($0) })
    return UndoneChange(created: refs.filter { created.contains(JSString($0)) }, updated: refs.filter { !created.contains(JSString($0)) })
  }

  /// undo-impact.ts:138-159: a created record vanishes, so everything naming it is listed; an updated one only reverts, so finalized plans and drafts are
  /// counted, not listed.
  static func impact(_ change: UndoneChange, rows: ImpactRows) -> UndoImpact {
    let created = Set(change.created.map { JSString($0) })
    var kept = [UndoDependent]()
    var keys = Set<String>()
    var finalUnaffected = Set<String>()
    for candidate in candidates(change.created + change.updated, rows: rows) {
      let dependent = candidate.dependent
      let key = "\(dependent.kind.rawValue)|\(dependent.ref)"
      let updatedOnly = !created.contains(JSString(candidate.root))
      if updatedOnly, dependent.kind == .knowledge, candidate.root.jsStartsWith("entity:") { continue }
      if updatedOnly, dependent.final, dependent.kind == .plan || dependent.kind == .draft {
        finalUnaffected.insert(key)
        continue
      }
      if keys.insert(key).inserted { kept.append(dependent) }
    }
    let dependents = kept.sorted { left, right in
      let (leftKind, rightKind) = (kindOrder.firstIndex(of: left.kind) ?? 0, kindOrder.firstIndex(of: right.kind) ?? 0)
      if leftKind != rightKind { return leftKind < rightKind }
      if (left.chapter ?? 0) != (right.chapter ?? 0) { return (left.chapter ?? 0) < (right.chapter ?? 0) }
      return JSText.codeUnitPrecedes(left.ref, right.ref)
    }
    return UndoImpact(dependents: dependents, finalUnaffected: finalUnaffected.subtracting(keys).count)
  }

  // undo-impact.ts:99-132; `changed` keeps the reference's Set order, created refs first
  private static func candidates(_ refs: [String], rows: ImpactRows) -> [(dependent: UndoDependent, root: String)] {
    let changed = refs.jsUnique()
    let isChanged = Set(changed.map { JSString($0) })
    let drafts = Dictionary(rows.drafts.map { ($0.chapter, $0) }) { first, _ in first }
    var found = [(dependent: UndoDependent, root: String)]()
    func draftOf(_ chapter: Int, because: String, root: String) {
      guard let draft = drafts[chapter] else { return }
      found.append((UndoDependent(kind: .draft, ref: "draft:\(chapter)", chapter: chapter, because: because, final: draft.isFinal), root))
    }

    for plan in rows.plans {
      let own = "chapter:\(plan.chapter)"
      guard let root = plan.references.first(where: { isChanged.contains(JSString($0)) }), !isChanged.contains(JSString(own)) else { continue }
      found.append((UndoDependent(kind: .plan, ref: own, chapter: plan.chapter, because: root, final: drafts[plan.chapter]?.isFinal == true), root))
      draftOf(plan.chapter, because: own, root: root)
    }

    for ref in changed {
      if ref.jsStartsWith("chapter:"), let chapter = Int(ref.jsSlice(8)) { draftOf(chapter, because: ref, root: ref) }
      guard ref.jsStartsWith("draft:"), let chapter = Int(ref.jsSlice(6)) else { continue }
      for draft in rows.drafts where draft.chapter > chapter { draftOf(draft.chapter, because: ref, root: ref) }
    }

    for row in rows.knowledge {
      guard let root = ["fact:\(row.fact)", "entity:\(row.entity)"].first(where: { isChanged.contains(JSString($0)) }) else { continue }
      let dependent = UndoDependent(
        kind: .knowledge, ref: "knowledge:\(row.entity)/\(row.fact)", chapter: row.learnedInChapter, because: root, final: row.isCommitted)
      found.append((dependent, root))
    }

    for row in rows.suggestions {
      guard let root = row.references.first(where: { isChanged.contains(JSString($0)) }) else { continue }
      found.append((UndoDependent(kind: .suggestion, ref: "proposal:\(row.id.uuidString.lowercased())", chapter: nil, because: root, final: false), root))
    }
    return found
  }
}
