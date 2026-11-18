// apps/novel-forge-server/src/modules/ai/prompts/continuity.prompt.ts:17
let continuityVersion = "1.4.0"

// apps/novel-forge-server/src/modules/ai/prompts/continuity.prompt.ts:6
let continuitySystem =
  #"""
  You are analyzing a chapter written outside the standard generation pipeline (written by a human author or imported from a source novel) to extract continuity data for the bible. You receive the chapter prose and the current knowledge base. Extract: which entities appeared, any new entities introduced, plot thread updates, mystery updates, timeline events, relationship updates, power progression changes, character states, and knowledge changes. Also write a chapter summary. This data will be staged for human review before applying to the bible.

  Character states: for any character whose state materially changed in this chapter, report their current location, physical/emotional conditions, immediate goal, and a one-line status note. Each state you report replaces the prior recorded state for that character — it is not merged or appended, so state only what is now true.

  Knowledge changes: for anything a character newly came to know in this chapter, report which character learned which canon fact and how they learned it (e.g. read it in a letter, overheard it, was told directly).

  Existing keys: the context pack lists the threads and mysteries already tracked for this project. When an update concerns one of them, reuse its exact existing key — do not coin a variant. Only invent a new key for something genuinely new that is not already in those lists.

  Milestones: when the context pack lists MILESTONES, report every one marked "claimed by this chapter" with `reached` true only if the prose actually shows it happening, and report any other listed milestone the prose clearly shows happening. Never mark a milestone reached because the plan expects it.

  Confidence: mark an entry `confidence: "low"` when you are inferring or interpreting rather than reading an explicit, unambiguous statement in the prose. Leave it out (or mark `"high"`) for clear, directly-stated facts. Low-confidence entries are held back for a human to review instead of being applied.

  Extract only what the prose establishes, with an evidence excerpt; empty arrays are correct. Do not speculate or infer state beyond what's textually supported — every characterStates and relationships entry must include the evidence excerpt that justifies it.
  """#

// apps/novel-forge-server/src/modules/ai/isolation-read-policy.ts:44
let continuityIsolatedNote =
  #"""
  ## HOW TO DESCRIBE THIS CHAPTER
  This chapter is walled off from the rest of the book. Describe every entry plainly and non-graphically: record what happened, who knows what and where things stand, never how an intimate or violent scene read. Quote nothing from the prose.
  """#

// apps/novel-forge-server/src/modules/ai/isolation-read-policy.ts:51
func continuityIsolatedContext(_ contextPack: String) -> String {
  "\(continuityIsolatedNote)\n\n\(contextPack)"
}

struct ContinuityRosterEntity: Equatable, Sendable {
  var entityKey: String
  var name: String
  var type: String
}

struct ContinuityRosterThread: Equatable, Sendable {
  var threadKey: String
  var status: String
  var summary: String?
}

struct ContinuityRosterMystery: Equatable, Sendable {
  var mysteryKey: String
  var status: String
  var question: String?
}

struct ContinuityMilestoneRow: Equatable, Sendable {
  var milestoneKey: String
  var label: String
  var state: String
}

// apps/novel-forge-server/src/modules/ai/graphs/chapter-finalization.graph.ts:209; a mystery stored without a question reads "null", as the reference interpolates it.
func continuityRoster(entities: [ContinuityRosterEntity], threads: [ContinuityRosterThread], mysteries: [ContinuityRosterMystery]) -> String {
  let entityRoster = entities.map { "\($0.entityKey) (\($0.type)): \($0.name)" }.joined(separator: "\n")
  let threadRoster = threads.map { "\($0.threadKey) (\($0.status)): \($0.summary ?? "")" }.joined(separator: "\n")
  let mysteryRoster = mysteries.map { "\($0.mysteryKey) (\($0.status)): \($0.question ?? "null")" }.joined(separator: "\n")
  return [
    "## ENTITY ROSTER\n\(entityRoster.isEmpty ? "none" : entityRoster)", "## EXISTING THREADS\n\(threadRoster.isEmpty ? "none" : threadRoster)",
    "## EXISTING MYSTERIES\n\(mysteryRoster.isEmpty ? "none" : mysteryRoster)",
  ]
  .joined(separator: "\n\n")
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:480
func continuityContextPack(roster: String, milestones: [ContinuityMilestoneRow], claimed: [String]) -> String {
  let lines = milestones.map { row in
    let marker = claimed.contains { $0.jsEquals(row.milestoneKey) } ? ", claimed by this chapter" : ""
    return "\(row.milestoneKey) (\(row.state)\(marker)): \(row.label)"
  }.joined(separator: "\n")
  return "\(roster)\n\n## MILESTONES\n\(lines.isEmpty ? "none" : lines)"
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:489
func continuityRequest(contextPack: String, chapter: Int, prose: String, isolated: Bool = false) -> ChapterPromptRequest {
  ChapterPromptRequest(
    [
      PromptMessage(.system, continuitySystem),
      PromptMessage(.user, "\(isolated ? continuityIsolatedContext(contextPack) : contextPack)\n\nChapter \(chapter) prose:\n\n\(prose)"),
    ], layout: .plain, breakpointsAt: [])
}
