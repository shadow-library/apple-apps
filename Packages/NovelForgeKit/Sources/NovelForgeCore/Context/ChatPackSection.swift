// apps/novel-forge-server/src/modules/ai/context/sections.ts:1
enum ChatPackTier: String, Codable, Sendable {
  case canonical
  case approvedIntent = "approved_intent"
  case working
}

// apps/novel-forge-server/src/modules/ai/context/sections.ts:7
enum ChatPackSegment: String, Codable, Sendable {
  case stable
  case volatile
}

// apps/novel-forge-server/src/modules/ai/context/sections.ts:9
struct ChatPackSection: BudgetedSection, Codable, Equatable {
  var key: String
  var tier: ChatPackTier
  var segment: ChatPackSegment
  var tokens: Int
  var truncated: Bool
  var sourceRefs: [String]
  var rendered: String
  var required: Bool
  var priority: Int?

  init(
    key: String, tier: ChatPackTier, segment: ChatPackSegment, tokens: Int, truncated: Bool, sourceRefs: [String], rendered: String, required: Bool = false, priority: Int? = nil
  ) {
    self.key = key
    self.tier = tier
    self.segment = segment
    self.tokens = tokens
    self.truncated = truncated
    self.sourceRefs = sourceRefs
    self.rendered = rendered
    self.required = required
    self.priority = priority
  }
}

/// Own reason type: the persisted omission records keep `unresolved`, which `BudgetOmissionReason` does not.
// apps/novel-forge-server/src/modules/ai/context/sections.ts:23
enum ChatPackOmissionReason: String, Codable, Sendable {
  case budget
  case unresolved
}

// apps/novel-forge-server/src/modules/ai/context/sections.ts:23
struct ChatPackOmission: Codable, Equatable, Sendable {
  var key: String
  var reason: ChatPackOmissionReason
  var tokens: Int?

  init(key: String, reason: ChatPackOmissionReason, tokens: Int? = nil) {
    self.key = key
    self.reason = reason
    self.tokens = tokens
  }

  init(_ omission: BudgetOmission) {
    self.init(key: omission.key, reason: .budget, tokens: omission.tokens)
  }
}

extension ChatPackSection {
  /// apps/novel-forge-server/src/modules/ai/context/pack-render.ts:316 (asStable)
  var asStable: ChatPackSection {
    var section = self
    section.segment = .stable
    return section
  }
}

private let sectionSeparator = "\n\n---\n\n"

// apps/novel-forge-server/src/modules/ai/context/sections.ts:46 (the prompt contract: never change a label's text)
private let sectionLabels: [JSString: String] = [
  "prev_ending": "## PREVIOUS CHAPTER ENDING",
  "continuation_state": "## CONTINUATION STATE",
  "brief": "## CHAPTER BRIEF",
  "volume_objective": "## VOLUME OBJECTIVE",
  "completed_volumes": "## EARLIER VOLUMES",
  "open_canon": "## BOOK RULES (OPEN CANON)",
  "character_state": "## CHARACTER STATE (CURRENT)",
  "relationships": "## CHARACTER RELATIONSHIPS (CURRENT)",
  "memory": "## RECENT SUMMARIES",
  "allowed_clues": "## ALLOWED CLUES",
  "writing_style": "## WRITING STYLE",
  "catalog": "## CANON CATALOG",
  "lore_retrieved": "## LORE REFERENCES",
  "prose_retrieved": "## PROSE REFERENCES",
  "premise": "## PREMISE",
  "doc_inventory": "## BIBLE DOCUMENT INVENTORY",
  "bible_documents": "## BIBLE DOCUMENTS",
  "document": "## DOCUMENT",
  "volume_plan": "## VOLUME PLAN",
  "briefs_list": "## CHAPTER BRIEFS",
  "changed_since": "## CHANGED SINCE THIS CONVERSATION STARTED",
  "world_facts": "## WORLD FACTS",
  "known_facts": "## KNOWN FACTS (POV CAST)",
  "chapter_reveals": "## REVEALED THIS CHAPTER",
  "reader_knows": "## THE READER KNOWS (THE POV CAST DOES NOT)",
  "hidden_constraints": "## BEHAVIORAL CONSTRAINTS",
  "art_style": "## ART STYLE BIBLE",
  "subject_card": "## SUBJECT",
  "subject_changes": "## HOW THE SUBJECT HAS CHANGED SO FAR",
  "cast_appearance": "## CAST APPEARANCE",
  "ledger": "## DECISION LEDGER",
  "later_plans": "## THE AUTHOR'S PLANS FOR LATER",
  "author_brief": "## THE AUTHOR'S OWN WORDS",
  "writer_lines": "## AUTHOR DECISIONS FOR THE WRITER",
  "story": "## THE STORY",
  "notebook": "## THE NOTEBOOK (THE AUTHOR'S DECISIONS)",
  "author_notes": "## THE AUTHOR'S NOTES",
  "promises": "## OPEN PROMISES",
  "inventory": "## STORY BIBLE INVENTORY",
  "chapter_index": "## CHAPTERS",
  "handoff": "## WHERE THE STORY STANDS",
]

// apps/novel-forge-server/src/modules/ai/context/sections.ts:92
private func sectionLabel(_ key: String) -> String {
  if let label = sectionLabels[JSString(key)] { return label }
  let spaced = String(String.UnicodeScalarView(key.uppercased().unicodeScalars.map { $0 == "_" ? " " : $0 }))
  return "## " + spaced
}

// apps/novel-forge-server/src/modules/ai/context/sections.ts:96
func renderSection(_ key: String, _ content: String) -> String {
  "\(sectionLabel(key))\n\n\(content)"
}

// apps/novel-forge-server/src/modules/ai/context/sections.ts:112
func joinSections(_ sections: [ChatPackSection]) -> String {
  sections.map(\.rendered).joined(separator: sectionSeparator)
}

// apps/novel-forge-server/src/modules/ai/context/sections.ts:117
func splitSegments(_ sections: [ChatPackSection]) -> (renderedStable: String, renderedVolatile: String) {
  (joinSections(sections.filter { $0.segment == .stable }), joinSections(sections.filter { $0.segment != .stable }))
}
