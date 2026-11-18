// apps/novel-forge-server/src/modules/ai/prompts/title.prompt.ts:12
let chapterTitleVersion = "1.1.0"

// apps/novel-forge-server/src/modules/ai/prompts/title.prompt.ts:7
let chapterTitleSystem =
  #"""
  You are titling a chapter of a serialized novel. Given the chapter summary and the style of existing chapter titles, produce a title that is evocative, thematically resonant, and consistent in length and style with the existing titles. The title should hint at the chapter's central event or turning point without spoiling it.

  Respond with ONLY one valid JSON object — nothing outside the JSON, no markdown fences — of exactly this shape: {"title": "..."}
  """#

// apps/novel-forge-server/src/modules/ai/prompts/title.prompt.ts:15
func chapterTitleMessages(existingTitles: String, chapterSummary: String) -> [PromptMessage] {
  [
    PromptMessage(.system, chapterTitleSystem),
    PromptMessage(.user, "Existing chapter titles (for style reference):\n\(existingTitles)\n\nChapter summary:\n\(chapterSummary)"),
  ]
}
