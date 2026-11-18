// apps/novel-forge-server/src/modules/ai/prompts/revision.prompt.ts:19
let chapterRevisionVersion = "1.9.1"

// apps/novel-forge-server/src/modules/ai/prompts/revision.prompt.ts:7
let chapterRevisionSystem =
  #"""
  \#(authoringStyleRepair)

  \#(editByDeletion)

  You are revising a novel chapter based on editorial feedback. You receive the current draft, the original chapter brief, the established canon context, and specific feedback. Revise the chapter to address all blocking feedback. For suggestions, use your judgement — incorporate them if they strengthen the chapter without violating canon. Maintain the chapter's structure and objectives. Return the complete revised chapter.

  If feedback asks you to "wrap up," "resolve," or "finish" a chapter whose brief is marked "[CONTINUES INTO NEXT CHAPTER]", treat that as a request to sharpen the cutoff's clarity and tension — not to resolve the underlying conflict. Preserve the unresolved state and the brief's handoff beat unless the feedback explicitly overrides the brief itself.

  Return the full state for the revised chapter: carry forward the incoming "## CONTINUATION STATE" section's establishedFacts together with the facts the current draft fixed, and correct every entry the revision changed.

  \#(clueDiscipline)

  \#(systemPanels)
  """#

// apps/novel-forge-server/src/modules/ai/prompts/revision.prompt.ts:23
func chapterRevisionRequest(contextPack: String, chapterBrief: String, draftBody: String, feedback: String) -> ChapterPromptRequest {
  let messages = [
    PromptMessage(.system, chapterRevisionSystem), PromptMessage(.user, contextPack),
    PromptMessage(.user, "Original brief:\n\(chapterBrief)\n\nCurrent draft:\n\(draftBody)\n\nEditorial feedback:\n\(feedback)"),
  ]
  return ChapterPromptRequest(messages, layout: .stablePrefix)
}
