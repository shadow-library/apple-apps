import ShadowText

// apps/novel-forge-server/src/modules/ai/prompts/chapter-expand.prompt.ts:21
let chapterExpandVersion = "1.3.0"

// apps/novel-forge-server/src/modules/ai/prompts/chapter-expand.prompt.ts:7
let chapterExpandSystem =
  #"""
  You are expanding a chapter draft that came in under its length target. You receive the context pack (the author's writing instructions plus established canon), the chapter brief, its ending contract, and the current draft with its word count, plus any guidance the draft was written under. Return the complete chapter, lengthened to the requested size by deepening what is already there: dramatize moments the draft summarizes as on-page scene, let conversations run their full course, give the POV character's perceptions, reactions, and decisions room, and stage the physical movement between beats. Follow the author's writing instructions for how the prose reads, and keep the draft's point of view and tense.

  Hard constraints:
  - Keep every event, its order, and the outcome of each scene exactly as drafted. Add no new plot events, characters, reveals, or resolutions, and resolve nothing the draft leaves open.
  - Keep the opening beat and the final beat. The chapter ends on the same moment, line, or decision as the draft and never continues past it — when the brief marks "[CONTINUES INTO NEXT CHAPTER]" or an ending contract is present, the cut stays exactly where it is.
  - Stay inside the context pack's canon and knowledge boundaries ("## KNOWN FACTS (POV CAST)", "## REVEALED THIS CHAPTER", "## BEHAVIORAL CONSTRAINTS"): expansion never lets a character know more than the draft allowed.
  - \#(clueDiscipline)
  - Canon always wins over dramatic convenience.
  - Keep the draft's strongest lines; rewrite a sentence only where the added material needs a seam.
  - Word counts are prose only: system panels (```system blocks) and tables do not count. Keep every panel and table exactly as drafted, and never add or lengthen one to reach the length.
  - No padding: no recaps, repeated information, re-explained emotions, inventory description, or stock reactions. Every added paragraph must show something the reader did not already have.
  """#

struct ChapterExpandInput: Equatable, Sendable {
  var stableContext: String
  var volatileContext: String
  var chapterBrief: String
  var endingContract: String
  var guidance: String
  var draftBody: String
  var draftWords: Double
  var minWords: Double
  var aimWords: Double
  var missingWords: Double
}

// apps/novel-forge-server/src/modules/ai/prompts/chapter-expand.prompt.ts:26
func chapterExpandRequest(_ input: ChapterExpandInput) -> ChapterPromptRequest {
  let messages = [
    PromptMessage(.system, chapterExpandSystem),
    PromptMessage(.user, input.stableContext),
    PromptMessage(
      .user,
      "\(input.volatileContext)\n\nChapter brief:\n\(input.chapterBrief)\n\n## ENDING CONTRACT\n\(input.endingContract)\n\nCurrent draft (\(input.draftWords.jsString) words):\n\(input.draftBody)\n\nAdditional guidance: \(input.guidance)\n\nExpand this draft to at least \(input.minWords.jsString) words — aim for about \(input.aimWords.jsString), roughly \(input.missingWords.jsString) more than it has now — and return the complete chapter."
    ),
  ]
  return ChapterPromptRequest(messages, layout: .stablePrefix)
}
