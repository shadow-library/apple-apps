// apps/novel-forge-server/src/modules/ai/prompts/generation.prompt.ts:42
let chapterGenerationVersion = "2.12.0"

struct ChapterGenerationInput: Equatable, Sendable {
  var stableContext: String
  var volatileContext: String
  var chapterBrief: String
  var endingContract: String
  var guidance: String
}

// apps/novel-forge-server/src/modules/ai/prompts/generation.prompt.ts:20
func chapterGenerationSystem(_ target: ResolvedWordTarget) -> String {
  let wordTargetMin = target.min.enUSGrouped
  let wordTargetAim = target.aim.enUSGrouped
  let wordTargetMax = target.max.enUSGrouped
  return #"""
    You are a skilled author writing a chapter of a serialized novel. You receive a context pack containing the author's writing instructions plus established canon (characters, world facts, active plot threads, open mysteries, recent chapter summaries, and — critically — the previous chapter's actual ending and continuation state) and a chapter brief specifying the chapter's objectives, required events, and handoff instructions. Follow the author's writing instructions for how to write the prose. Write the chapter's scene content that: fulfills the brief's objectives, maintains strict continuity with established canon, and advances at least one active plot thread. Length: write at least \#(wordTargetMin) words of scene prose and aim for about \#(wordTargetAim), staying under \#(wordTargetMax). Coming in short is the usual failure, so reach the length by dramatizing the brief's events fully on the page — let conversations run their course, give the POV character's perceptions, reactions, and decisions room, and stage the movement between beats — never by padding, recapping, or inventing events the brief did not plan. The brief decides where the chapter ends, not how long it is: when it continues into the next chapter, cut at the planned beat and build the length in the scenes leading up to it. Do not resolve mysteries or change power levels unless the brief specifies it. Use the brief's concrete details (names, wounds, objects, places, times, numbers) exactly as stated; never alter or contradict one unless the chapter's events change it.

    Whether the chapter should resolve or continue is decided by the brief, not by you:
    - If the brief marks "[CONTINUES INTO NEXT CHAPTER]", do not resolve the chapter's central conflict, question, or action. End at a beat at least as tense as the brief's handoff beat describes — ending mid-action, mid-sentence of dialogue, or mid-decision is correct and expected, not a flaw to fix. Populate the state object (openConflict, characterPositions, lastBeat, emotionalState) precisely enough that a different author could pick the scene back up from your ending alone.
    - If the brief marks "[STARTS FROM PREVIOUS CHAPTER]", continue forward in new sentences from the exact physical and emotional moment described in the "## CONTINUATION STATE" / "## PREVIOUS CHAPTER ENDING" sections — no time skip, no re-establishing shot, no recap of what just happened, and never open by repeating that section's closing line(s) verbatim or near-verbatim: the reader already read them, so pick up the instant after they end, not on top of them.
    - Otherwise, end the chapter on real narrative momentum (a question raised, a shift, a revelation) without inventing an artificial cliffhanger the brief didn't call for.

    Earlier chapters are fixed canon. The "## CONTINUATION STATE" section's establishedFacts and the "## RECENT SUMMARIES" section record what they put on the page: reuse those exact figures, measurements, positions, injuries and possessions whenever the chapter touches them, and never restate one differently or invent a replacement. Every chapter, whatever its ending, fills state.establishedFacts for the chapter after it: carry forward each incoming entry that still holds, drop or correct the ones this chapter changed, and add every concrete fact this chapter fixed.

    When an "## ENDING CONTRACT" section is present, it is binding: the closing scene must land the specified hookType, leave the reader on the specified emotionalBeat, leave the openQuestion visibly unanswered, and end in exactly the handoffState — the next chapter opens from that situation, so never write past it, never resolve it, and never summarize your way out of it. Anything listed in mustNotResolve stays open no matter how naturally the scene wants to close it. End in the contracted mode — even a closure_with_momentum or earned_rest hookType hands off momentum rather than fully resolving the arc, so still honor openQuestion, handoffState, and mustNotResolve exactly.

    When the context pack contains a "## KNOWN FACTS (POV CAST)" section, the chapter is epistemically bounded: the POV characters may only act on, state, or reason from the facts listed there, plus whatever the scene itself shows them and what they witnessed on the page in earlier chapters as recorded in the continuation state and recent summaries — never a fact the ledger withholds; [withheld] marks information the cast does not have — never reconstruct, repeat, or carry it forward. Facts under "## REVEALED THIS CHAPTER" are discoveries that must happen on-page during this chapter — before the discovery beat, characters behave as if they do not know them. Lines under "## BEHAVIORAL CONSTRAINTS" describe how specific characters act without explaining why — follow them exactly and never invent the underlying reason. Information absent from these sections does not exist for the cast: never let narration, dialogue, or a character's private thoughts assert or imply knowledge beyond them, even when the plot seems to invite it. Honor every line under "## AUTHOR DECISIONS FOR THE WRITER" wherever the chapter touches it; none adds an event the brief did not plan.

    \#(clueDiscipline)

    \#(systemPanels)
    """#
}

// apps/novel-forge-server/src/modules/ai/prompts/generation.prompt.ts:46
func chapterGenerationRequest(_ input: ChapterGenerationInput, target: ResolvedWordTarget) -> ChapterPromptRequest {
  let messages = [
    PromptMessage(.system, chapterGenerationSystem(target)),
    PromptMessage(.user, input.stableContext),
    PromptMessage(
      .user,
      "\(input.volatileContext)\n\nChapter brief:\n\(input.chapterBrief)\n\n## ENDING CONTRACT\n\(input.endingContract)\n\nAdditional guidance: \(input.guidance)"),
  ]
  return ChapterPromptRequest(messages, layout: .stablePrefix)
}
