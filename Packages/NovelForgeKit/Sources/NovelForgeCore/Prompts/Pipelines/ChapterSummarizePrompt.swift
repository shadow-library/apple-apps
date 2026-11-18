// apps/novel-forge-server/src/modules/ai/prompts/chapter-summarize.prompt.ts:13
let chapterSummarizeVersion = "1.2.0"

// apps/novel-forge-server/src/modules/ai/prompts/chapter-summarize.prompt.ts:6
let chapterSummarizeSystem =
  #"""
  You are summarizing a chapter written outside the standard generation pipeline (a paste-your-own-prose import, or prose from a permissive/unrestricted writer) so its content can reach the rest of the novel without exposing the prose itself to later chapters. You receive only the chapter prose.

  Write a 2-3 sentence past-tense summary of what happened — the same kind of summary the standard pipeline produces for every other chapter.

  Then populate the continuation state precisely enough that a different author could pick up the story from your state alone, with no access to this prose: the unresolved conflict or tension active at the chapter's end (if any), where each on-scene character physically ends up, the exact last action, line, or decision the story must resume from, and the POV character's emotional state at the cutoff. List in establishedFacts every concrete fact the chapter fixes that a later chapter must not contradict: exact figures and measurements, injuries, possessions and where objects are, and who knows what. Leave a field out only when the chapter genuinely gives you nothing to report for it — do not invent detail the prose does not support.
  """#

// apps/novel-forge-server/src/modules/generation/generation.service.ts:789
func chapterSummarizeRequest(chapterProse: String) -> ChapterPromptRequest {
  ChapterPromptRequest(
    [PromptMessage(.system, chapterSummarizeSystem), PromptMessage(.user, "Chapter prose:\n\n\(chapterProse)")], layout: .plain, breakpointsAt: [])
}
