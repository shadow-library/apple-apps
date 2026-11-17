// apps/novel-forge-server/src/modules/refinement/planner-only-guard.ts:3
let plannerOnlyLookupTool = "get_bible_document"

// apps/novel-forge-server/src/modules/refinement/planner-only-guard.ts:4
let authorNotesLookupTool = "get_notes"

// apps/novel-forge-server/src/modules/refinement/planner-only-guard.ts:7
let plannerOnlyWarning = [
  "This turn drew on your notes, organised timeline or open questions, which only planning steps read, so its changes to what the chapter writer or your readers could see wait for you.",
  "Check none carries later-story material into the story, a brief or a page they read.",
].joined(separator: " ")

// apps/novel-forge-server/src/modules/refinement/planner-only-guard.ts:13
func readsPlannerOnlyPage(tool: String, args: OrderedJSON?) -> Bool {
  if tool.jsEquals(authorNotesLookupTool) { return true }
  guard tool.jsEquals(plannerOnlyLookupTool), let fields = args?.objectValue else { return false }
  guard let section = fields["section"]?.stringValue, let slug = fields["slug"]?.stringValue else { return false }
  return isPlannerOnlyBibleDoc(BibleDocAddress(section: section, slug: slug))
}

// apps/novel-forge-server/src/modules/refinement/planner-only-guard.ts:20
func chatTurnWarnings(_ warnings: [String], readPlannerOnly: Bool) -> [String] {
  readPlannerOnly && !warnings.contains(where: { $0.jsEquals(plannerOnlyWarning) }) ? warnings + [plannerOnlyWarning] : warnings
}
