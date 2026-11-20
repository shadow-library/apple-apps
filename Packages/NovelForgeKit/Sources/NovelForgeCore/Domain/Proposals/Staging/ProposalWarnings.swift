import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/ai/isolation-read-policy.ts:48
let isolatedSourceWarning = "Read from an unrestricted chapter: excerpts are withheld; review every entry before it becomes canon."

/// The text fields a text op would overwrite, as `loadBaselineTexts` reads them (proposal-warnings.ts:38), keyed like `changeSetRefs`.
typealias BaselineTexts = [JSString: [String: String?]]

// apps/novel-forge-server/src/modules/refinement/proposal-warnings.ts; every check is advisory: one that cannot run stages the card without its warnings
enum ProposalWarnings {
  private struct TextOp {
    let ref: String
    let subject: String
    let fields: [String]
    let proposed: [String: String]
  }

  // proposal-warnings.ts:12-36
  private static func textOp(_ op: ChangeOp) -> TextOp? {
    switch op.operation {
    case .briefUpdate(let brief):
      return TextOp(ref: "chapter:\(brief.chapter)", subject: "the chapter \(brief.chapter) brief", fields: ["title", "body"], proposed: proposed(op, ["title", "body"]))
    case .draftUpdate(let draft):
      return TextOp(
        ref: "draft:\(draft.chapter)", subject: "the chapter \(draft.chapter) prose", fields: ["title", "body", "summary"], proposed: proposed(op, ["title", "body", "summary"]))
    case .bibleDocumentUpsert(let page):
      let address = "\(page.section.rawValue)/\(page.slug)"
      return TextOp(ref: "doc:\(address)", subject: "the \(address) document", fields: ["body"], proposed: proposed(op, ["body"]))
    case .entityUpsert(let entity):
      let fields = ["status", "motivation", "notes", "body"]
      return TextOp(ref: "entity:\(entity.entityKey)", subject: "the \(entity.entityKey) entry", fields: fields, proposed: proposed(op, fields))
    default:
      return nil
    }
  }

  private static func proposed(_ op: ChangeOp, _ fields: [String]) -> [String: String] {
    let written = opFields(op)
    return Dictionary(fields.compactMap { field in written[field]?.stringValue.map { (field, $0) } }) { first, _ in first }
  }

  /// proposal-warnings.ts:82: one warning per clause where a text op removed something by writing its absence; nil when the detector is unavailable.
  static func negationEchoes(_ ops: [ChangeOp], baselines: BaselineTexts, options: NegationEchoOptions = NegationEchoOptions()) -> [String]? {
    var warnings = [String]()
    for op in ops {
      guard let text = textOp(op), let baseline = baselines[JSString(text.ref)] else { continue }
      let before = text.fields.map { (baseline[$0] ?? nil) ?? "" }.joined(separator: "\n")
      let after = text.fields.map { text.proposed[$0] ?? (baseline[$0] ?? nil) ?? "" }.joined(separator: "\n")
      guard case .echoes(let echoes) = NegationEchoDetector.scan(before: before, after: after, options: options) else { return nil }
      for echo in echoes {
        let terms = echo.terms.map { "\"\($0)\"" }.joined(separator: ", ")
        warnings.append("\(text.subject) drops \(terms) by stating its absence (\"\(echo.excerpt)\") — delete it instead of negating it")
      }
    }
    return warnings
  }

  /// proposal-warnings.ts:38: the stored text of each record a text op would overwrite, a draft as `drafts` reads it through this device's working copy; a
  /// record that is missing, removed or unreadable here has none.
  static func baselineTexts<Transaction: StateReading & ~Copyable>(
    _ ops: [ChangeOp], novel: UUID, drafts: [Int: DraftRecord] = [:], in transaction: borrowing Transaction
  ) throws(StoreError) -> BaselineTexts {
    var texts = BaselineTexts()
    for op in ops {
      guard let text = textOp(op), let ref = ArtifactRef(text.ref), case .present(var subject) = try ArtifactSubject.read(ref, novel: novel, in: transaction) else { continue }
      if case .draft(let chapter) = ref, let draft = drafts[chapter] { subject = .draft(draft) }
      switch subject {
      case .chapter(let plan): texts[JSString(text.ref)] = ["title": plan.content.title, "body": plan.content.body]
      case .draft(let draft): texts[JSString(text.ref)] = ["title": draft.content.title, "body": draft.content.body, "summary": draft.content.summary]
      case .doc(let page): texts[JSString(text.ref)] = ["body": page.content.body]
      case .entity(let entity): texts[JSString(text.ref)] = ["status": entity.status, "motivation": entity.motivation, "notes": entity.notes, "body": entity.body]
      default: continue
      }
    }
    return texts
  }

  private static func undatedFact(_ op: ChangeOp) -> String? {
    guard case .factUpsert(let fact) = op.operation, case .null = fact.revealChapter else { return nil }
    return fact.factKey
  }

  /// proposal-warnings.ts:109: one warning per `fact.upsert` that clears a reveal date the fact has now; omitting the field or undating an unscheduled fact is silent.
  static func revealClears(_ ops: [ChangeOp], datedFacts: [JSString: Int]) -> [String] {
    ops.compactMap { op in
      guard let key = undatedFact(op), let dated = datedFacts[JSString(key)] else { return nil }
      return "fact:\(key) is scheduled to reveal at chapter \(dated); this clears that date, so only an unlock condition can let a plan reveal it — check that's intended."
    }
  }

  /// proposal-warnings.ts:117: the reveal chapter of each fact an undating op names, as stored; one this device cannot read gives no warning, and its
  /// unreadable baseline conflicts at apply instead.
  static func datedFacts<Transaction: StateReading & ~Copyable>(_ ops: [ChangeOp], novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> [JSString: Int] {
    var dated = [JSString: Int]()
    for key in ops.compactMap(undatedFact) {
      guard case .readable(let entry) = try SecretRecord.read(novel: novel, secret: key, in: transaction), !entry.isRemoved, let chapter = entry.record.revealChapter else {
        continue
      }
      dated[JSString(key)] = chapter
    }
    return dated
  }

  /// apps/novel-forge-server/src/modules/refinement/plan-diagnostics.ts:227: the warnings no plan check typed, as `other`, then the plan card's own findings.
  static func diagnostics(others: [String], plan: [ProposalDiagnostic]) -> [ProposalDiagnostic] {
    others.map { ProposalDiagnostic(kind: .known(.other), message: $0) } + plan
  }
}
