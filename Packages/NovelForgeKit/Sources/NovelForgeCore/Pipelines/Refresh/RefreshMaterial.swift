import ShadowCore
import ShadowText

// apps/novel-forge-server/src/modules/audit/bible-audit-material.ts:7-9
struct RefreshDocumentRow: Sendable, Equatable {
  let section: String
  let slug: String
  let body: String?

  var label: String { "doc:\(section)/\(slug)" }
}

struct RefreshEntityRow: Sendable, Equatable {
  let entityKey: String
  let type: String
  let name: String
  let status: String?
  let motivation: String?
  let notes: String?
  let body: String?

  var label: String { "entity:\(entityKey)" }
}

struct RefreshFactRow: Sendable, Equatable {
  let factKey: String
  let text: String
  let writerNote: String?
  let terms: [String]?
  let allowedClues: [String]?
  let revealChapter: Int?
  let disclosedInChapter: Int?
  let source: FactSource?

  /// bible-audit-material.ts:62: not disclosed by a finalized chapter, not open from the start, not a seed promise.
  var isSecret: Bool { disclosedInChapter == nil && !isOpenCanon(revealChapter) && source != .seed }
}

// bible-audit-material.ts:236-252
struct RefreshChapterRow: Sendable, Equatable {
  let number: Int
  let title: String?
  let summary: String?
  let content: String
}

struct RefreshReviewItem: Sendable, Equatable {
  let claim: String
  let decision: FinalizeDecision
}

struct RefreshRows: Sendable, Equatable {
  /// Ordered by section, then slug; entities by type, then key; facts by key, each in code-unit order where the reference sorts in the database's collation.
  let documents: [RefreshDocumentRow]
  let entities: [RefreshEntityRow]
  let facts: [RefreshFactRow]
  let chapter: RefreshChapterRow
  /// What the author answered in the chapter's finalize review, its summary left out.
  let reviewItems: [RefreshReviewItem]
}

struct RefreshMaterial: Sendable, Equatable {
  let bible: String
  let chapter: String
  /// Each label the refresh read, with the text it read under it.
  let sources: [JSString: String]
  /// Labels read only in part.
  let partial: Set<JSString>
  let checked: RefreshChecked
}

// apps/novel-forge-server/src/database/schemas/jobs.ts:33-47, as a chapter's refresh fills it
struct RefreshChecked: Sendable, Equatable {
  struct Documents: Sendable, Equatable {
    let count: Int
    let sections: [String]
    let clipped: Int
    let omitted: Int
  }

  struct Entities: Sendable, Equatable {
    let count: Int
    let byType: [String: Int]
    let omitted: Int
  }

  struct Facts: Sendable, Equatable {
    let count: Int
    let omitted: Int
  }

  let documents: Documents
  let entities: Entities
  let facts: Facts
  let chapter: Int
  let copy: String

  var json: [String: JSONValue] {
    let chapter = JSONValue.int(Int64(chapter))
    return [
      "passes": ["chapter": "ran"],
      "documents": [
        "count": .int(Int64(documents.count)), "sections": .array(documents.sections.map(JSONValue.string)), "clipped": .int(Int64(documents.clipped)),
        "omitted": .int(Int64(documents.omitted)),
      ],
      "entities": [
        "count": .int(Int64(entities.count)), "byType": .object(entities.byType.mapValues { .int(Int64($0)) }), "omitted": .int(Int64(entities.omitted)),
      ],
      "facts": ["count": .int(Int64(facts.count)), "omitted": .int(Int64(facts.omitted))],
      "chapters": ["from": chapter, "to": chapter, "count": 1],
      "chaptersWithoutSummary": [], "chaptersIsolated": [], "chaptersOmitted": 0,
      "copy": .string(copy),
    ]
  }
}

enum RefreshMaterialRender {
  private struct Budget {
    let total: Int
    let item: Int
  }

  private struct Entry {
    let label: String
    let text: String
  }

  private struct Fitted {
    let entries: [Entry]
    let clipped: Int
    let omitted: Int
  }

  // bible-audit-material.ts:45-50
  private static let documentBudget = Budget(total: 120_000, item: 8_000)
  private static let entityBudget = Budget(total: 40_000, item: 1_500)
  private static let factBudget = Budget(total: 30_000, item: 1_500)

  // bible-audit-material.ts:263
  static let chapterProseBudget = 60_000

  // bible-audit-material.ts:52-59
  private static let entityLabels: [(type: String, one: String, many: String)] = [
    ("character", "character", "characters"), ("faction", "faction", "factions"), ("location", "place", "places"), ("power_rule", "power rule", "power rules"),
    ("item", "item", "items"), ("concept", "concept", "concepts"),
  ]

  /// bible-audit-material.ts:269-337: the pages the chapter writer reads (plan pages stay out), the records and facts within the audit's budgets, then the chapter
  /// itself and the author's answers from its finalize review. Evidence may cite only what made it in.
  static func render(_ rows: RefreshRows) -> RefreshMaterial {
    let pages = rows.documents.filter { !($0.body?.jsTrim().isEmpty ?? true) && !isWriterExcludedBibleDoc(BibleDocAddress(section: $0.section, slug: $0.slug)) }
    let documents = fitted(pages, documentBudget) { Entry(label: $0.label, text: $0.body?.jsTrim() ?? "") }
    let entities = fitted(rows.entities, entityBudget) { Entry(label: $0.label, text: entityText($0)) }
    let facts = fitted(rows.facts, factBudget) { Entry(label: "fact:\($0.factKey)", text: factText($0)) }

    let chapter = rows.chapter
    let chapterRef = "chapter:\(chapter.number)"
    let prose = chapter.content.jsTrim()
    let proseRead = prose.jsLength > chapterProseBudget ? clipAtBoundary(prose, maxChars: chapterProseBudget) : prose
    let chapterText = [chapter.title?.jsTrim(), chapter.summary?.jsTrim(), proseRead].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    let kept = rows.reviewItems.filter { $0.decision != .skipped }.map(\.claim)
    let declined = rows.reviewItems.filter { $0.decision == .skipped }.map(\.claim)

    let bible = [block("Story Bible pages", documents.entries), block("Entity records", entities.entries), block("Canon facts", facts.entries)].joined(separator: "\n\n")
    let chapterBlock = [
      "## The finalized chapter\n\n[\(chapterRef)]\n\(chapterText)", bulleted("Updates the author kept from its review", kept),
      bulleted("Updates the author declined", declined),
    ].joined(separator: "\n\n")

    let pageBodies = pages.jsLastByKey(\.label).mapValues { $0.body?.jsTrim() ?? "" }
    let entityBodies = rows.entities.jsLastByKey(\.label).mapValues(entityText)
    let partial = Set(clippedLabels(documents.entries, pageBodies) + clippedLabels(entities.entries, entityBodies))

    let types = rows.entities.jsLastByKey(\.label)
    var byType = [String: Int]()
    for entry in entities.entries { byType[types[JSString(entry.label)]?.type ?? "concept", default: 0] += 1 }
    var caveats = [String]()
    if !proseRead.jsEquals(prose) { caveats.append("Chapter \(chapter.number) was too long and only partly read.") }
    if documents.clipped > 0 { caveats.append("\(plural(documents.clipped, one: "page was", many: "pages were")) too long and only partly read.") }
    let skipped = documents.omitted + entities.omitted + facts.omitted
    if skipped > 0 { caveats.append("\(plural(skipped, one: "entry", many: "entries")) did not fit and were not compared.") }
    let parts = [plural(documents.entries.count, one: "page", many: "pages"), entityCounts(byType), plural(facts.entries.count, one: "fact", many: "facts")]

    var sources = [JSString: String]()
    for entry in documents.entries + entities.entries + facts.entries + [Entry(label: chapterRef, text: chapterText)] { sources[JSString(entry.label)] = entry.text }
    let sections = documents.entries.map { entry -> String in
      let path = entry.label.jsSlice("doc:".jsLength)
      return path.jsSplit("/").first ?? ""
    }
    return RefreshMaterial(
      bible: bible, chapter: chapterBlock, sources: sources, partial: partial,
      checked: RefreshChecked(
        documents: RefreshChecked.Documents(count: documents.entries.count, sections: sections.jsUnique(), clipped: documents.clipped, omitted: documents.omitted),
        entities: RefreshChecked.Entities(count: entities.entries.count, byType: byType, omitted: entities.omitted),
        facts: RefreshChecked.Facts(count: facts.entries.count, omitted: facts.omitted), chapter: chapter.number,
        copy: (["Checked against chapter \(chapter.number): \(parts.joined(separator: ", "))."] + caveats).joined(separator: " ")))
  }

  // bible-audit-material.ts:102-112
  static func entityText(_ entity: RefreshEntityRow) -> String {
    let fields: [(String, String?)] = [
      ("name", entity.name), ("type", entity.type), ("status", entity.status), ("motivation", entity.motivation), ("notes", entity.notes), ("body", entity.body),
    ]
    return fields.compactMap { field, value in
      guard let trimmed = value?.jsTrim(), !trimmed.isEmpty else { return nil }
      return "\(field): \(trimmed)"
    }.joined(separator: "\n")
  }

  // bible-audit-material.ts:114-119
  private static func factText(_ fact: RefreshFactRow) -> String {
    var lines = ["\(fact.isSecret ? "SECRET — the reader has not been told. " : "")\(fact.text)"]
    if let note = fact.writerNote?.jsTrim(), !note.isEmpty { lines.append("writerNote: \(note)") }
    if let clues = fact.allowedClues, !clues.isEmpty { lines.append("allowedClues: \(clues.joined(separator: "; "))") }
    return lines.joined(separator: "\n")
  }

  // bible-audit-material.ts:83-100
  private static func fitted<Item>(_ items: [Item], _ budget: Budget, _ render: (Item) -> Entry) -> Fitted {
    var entries = [Entry]()
    var used = 0
    var clipped = 0
    for item in items {
      let entry = render(item)
      let text = entry.text.jsLength > budget.item ? clipAtBoundary(entry.text, maxChars: budget.item) : entry.text
      if used + text.jsLength > budget.total { break }
      if !text.jsEquals(entry.text) { clipped += 1 }
      used += text.jsLength
      entries.append(Entry(label: entry.label, text: text))
    }
    return Fitted(entries: entries, clipped: clipped, omitted: items.count - entries.count)
  }

  private static func clippedLabels(_ entries: [Entry], _ sources: [JSString: String]) -> [JSString] {
    entries.filter { !$0.text.jsEquals(sources[JSString($0.label)] ?? "") }.map { JSString($0.label) }
  }

  // bible-audit-material.ts:287-288
  private static func block(_ heading: String, _ entries: [Entry]) -> String {
    "## \(heading)\n\n\(entries.isEmpty ? "(none)" : entries.map { "[\($0.label)]\n\($0.text)" }.joined(separator: "\n\n"))"
  }

  // bible-audit-material.ts:265-267
  private static func bulleted(_ heading: String, _ lines: [String]) -> String {
    "## \(heading)\n\n\(lines.isEmpty ? "(none)" : lines.map { "- \($0)" }.joined(separator: "\n"))"
  }

  // bible-audit-material.ts:79-81
  private static func plural(_ count: Int, one: String, many: String) -> String {
    "\(count) \(count == 1 ? one : many)"
  }

  // bible-audit-material.ts:179-182
  private static func entityCounts(_ byType: [String: Int]) -> String {
    let parts = entityLabels.compactMap { label in byType[label.type].flatMap { $0 > 0 ? plural($0, one: label.one, many: label.many) : nil } }
    return parts.isEmpty ? "no entity records" : parts.joined(separator: ", ")
  }
}
