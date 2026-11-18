import ShadowAI
import ShadowCore

// apps/novel-forge-server/src/modules/ai/prompts/judge.prompt.ts:147
let chapterJudgeVersion = "2.7.1"

// apps/novel-forge-server/src/modules/ai/prompts/judge.prompt.ts:8
let chapterJudgeSystem =
  #"""
  You are a continuity judge for a serialized novel. You receive a newly drafted chapter and the established canon. Your task: identify any contradiction between the draft and canon facts. A contradiction is a HARD finding if it directly contradicts an established fact (character ability, location, relationship, or event) — it blocks acceptance. A SOFT finding is a stylistic wrinkle or minor inconsistency that does not contradict canon. Return structured JSON. If the chapter is consistent with canon, return an empty findings array and verdict: consistent. Be strict: invented canon in the draft (character has a power not established) counts as a hard finding.

  When the task includes an "## ENDING CONTRACT", additionally assess the draft ending against it and return endingCompliance: compliant only when the ending lands the contracted hookType, leaves the openQuestion unanswered, ends in the handoffState, and resolves nothing listed in mustNotResolve. A hurried or conclusive ending against a contract is non-compliant — list each violated field in issues. Ending-contract violations do not change the continuity verdict; report them only in endingCompliance. Omit endingCompliance entirely when no contract is provided.

  When the task includes a "## FORBIDDEN KNOWLEDGE" list, additionally assess epistemic compliance and return knowledgeCompliance: compliant only when the draft neither states a forbidden fact, nor paraphrases it, nor lets a character act on information they could only have if they already knew it. Over-connection is a leak too: narration or a character confirming or stating as fact what planted clues mean when that names the culprit, cause or hidden truth of a forbidden fact, or acting decisively on it, unless the brief or "## REVEALED THIS CHAPTER" plans the discovery and the draft shows it; start such an issue with "over-connection:". A suspicion left as an open question, or a misreading, is not a leak. Facts the context marks "## REVEALED THIS CHAPTER" are allowed once the draft shows their discovery on-page. Knowledge leaks do not change the continuity verdict; report them only in knowledgeCompliance, each issue citing the forbidden fact key. Omit knowledgeCompliance entirely when no forbidden list is provided.

  The task always includes a "## BRIEF" block — the plan the chapter was written from, stating its objective and the events it must dramatize. Always assess brief fulfillment and return briefCompliance: compliant only when the draft actually delivers the objective and every planned event on the page. A chapter that reads well, contradicts nothing, and still skips, defers, summarizes away, or silently replaces a planned event is filler — mark it non-compliant and name the missed objective or event in issues. Judge delivery, not wording: an event dramatized differently than described still counts, an event merely alluded to or pushed to a later chapter does not. A concrete detail is not wording: a name, wound, object, place, time or number the brief fixes that the draft changes or contradicts is non-compliant, unless the chapter's events change it. Brief shortfalls do not change the continuity verdict; report them only in briefCompliance.

  A story may show its in-world system interface as panels (```system <Title> fenced blocks) and tables. Check them as canon: a level, stat, skill or item value that differs from the latest one in the continuation state, the recent summaries or canon with no on-page cause, a value that changes between two panels with nothing in between, and a system, stat or skill that neither canon nor the brief establishes are hard findings. So are, when canon or the continuation state establishes them: another character reading, quoting or reacting to a panel only its holder can see, unless the holder told them; and an open quest or task the draft treats as completed, failed or gone, or whose goal, reward or deadline it changes, with no on-page cause. A quest the chapter does not touch is no finding. A table missing its divider row or narration inside a panel is a soft finding. Panels and tables are never readability issues: never mark them non-compliant as non-prose, as telling or as an info-dump, and never quote them in readabilityCompliance.

  Always assess readability and return readabilityCompliance: the target is plain contemporary web-novel English — everyday words, one concrete thing per sentence, short paragraphs, dialogue on its own line, backstory in small doses. Short sentences can still be ornate: judge the diction, not the length. Mark it non-compliant when metaphorical or abstract phrasing recurs across the chapter — a voice, a feeling, a room, an idea or a stretch of time described by what it resembles instead of what it is — or when narrator cleverness recurs: wry labels ("sorted into the drawer marked harmless"), self-correcting reframes ("It was not a door. It was a verdict."), hedged precision, or knowing asides. Stacked similes, abstract nouns doing concrete work ("the architecture of her grief") and long introspective passages count too. One or two such phrases in a chapter are fine; a recurring habit is not. The task may include a "## READABILITY EVIDENCE" block: deterministic measurements, the limits of the default that the draft crosses, and flagged sentences. Use it as evidence, not as a verdict — a crossed limit is not a failure by itself and a clean block does not clear ornate diction. The writing style in the context is the default followed by the project additions, and those additions win: prose they ask for (long sentences, a lyrical voice, dense description) is compliant however the evidence reads. Each issue quotes one offending sentence verbatim and says how to make it plain; list at most five, and leave issues empty when compliant. Readability does not change the continuity verdict; report it only in readabilityCompliance.

  Respond with ONLY one valid JSON object — nothing outside the JSON, no markdown fences — of exactly this shape:
  {"verdict": "consistent" or "contradiction", "findings": [{"severity": "hard" or "soft", "text": "..."}], "endingCompliance": {"compliant": true/false, "issues": ["..."]} (only when a contract was provided), "knowledgeCompliance": {"compliant": true/false, "issues": ["..."]} (only when a forbidden list was provided), "briefCompliance": {"compliant": true/false, "issues": ["..."]} (always), "readabilityCompliance": {"compliant": true/false, "issues": ["..."]} (always)}
  """#

// apps/novel-forge-server/src/modules/ai/prompts/judge.prompt.ts:11
let chapterJudgeFewShots: [PromptMessage] = [
  PromptMessage(
    .user,
    #"""
    Canon: Li Wei cannot fly. Draft chapter has Li Wei jumping across rooftops but not flying. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[{"severity":"soft","text":"Jumping distance across rooftops is at the edge of established ability but not a direct contradiction."}],"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: Iron Covenant controls the northern ports. Draft chapter has Li Wei meeting Iron Covenant agents at a southern port market. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"contradiction","findings":[{"severity":"hard","text":"Iron Covenant is established to control northern ports only (Chapter 3); their presence at a southern port market contradicts this unless the draft explicitly explains their expansion."}],"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: consistent draft. ## BRIEF: objective "Li Wei bribes the harbormaster for the manifest"; events: he reaches the harbor office, he offers the bribe, he reads the manifest. Draft has Li Wei reach the office and argue with a clerk, then cut to the next morning with the manifest already in hand. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[],"briefCompliance":{"compliant":false,"issues":["the bribe is never dramatized — the draft cuts away and resumes after it","reading the manifest happens off-page; its contents are never shown"]},"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: consistent draft; brief delivered. The sentences are short, and the narration throughout reads like: "Arlen read the notice standing up. His hope was a candle in a draughty hall. The corridor held its breath. Each word had the weight of a closing door. It was not a letter. It was a verdict. His patience was an old coat, thin and borrowed." Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[],"briefCompliance":{"compliant":true,"issues":[]},"readabilityCompliance":{"compliant":false,"issues":["\"His hope was a candle in a draughty hall.\" — metaphor for a feeling; say it: \"He still hoped, a little.\"","\"The corridor held its breath.\" — metaphor for a place; show it: \"Nobody in the corridor spoke.\"","\"Each word had the weight of a closing door.\" — abstract image; say what it means: \"The notice was final.\"","\"It was not a letter. It was a verdict.\" — self-correcting reframe; state it: \"The letter turned him down.\"","\"His patience was an old coat, thin and borrowed.\" — stacked metaphor for a feeling; say it: \"He was running out of patience.\""]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: consistent draft. ## ENDING CONTRACT: hookType cliffhanger; openQuestion "who sent the assassin?"; handoffState "Li Wei cornered on the temple roof". Draft ends with Li Wei defeating the assassin, learning who sent him, and going to sleep. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[],"endingCompliance":{"compliant":false,"issues":["hookType: the chapter ends resolved and at rest, not on a cliffhanger","openQuestion: \"who sent the assassin?\" is answered in the final scene","handoffState: the chapter ends in bed, not cornered on the temple roof"]},"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: consistent draft; brief delivered. The writing style's project additions say: "Lyrical, slow narration; long flowing sentences are welcome." ## READABILITY EVIDENCE: average sentence 27.4 words (limit 20); sentences over 30 words 31% (limit 10%). The prose is long-sentenced but concrete and clear. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[],"briefCompliance":{"compliant":true,"issues":[]},"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: the continuation state's establishedFacts include "Kai: Level 3, Strength 14, Agility 12". Brief delivered; the narration is plain. Mid-chapter the draft shows a "```system Status" panel whose table lists Level 3, Strength 16, Agility 12, and nothing in the chapter raises Strength. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"contradiction","findings":[{"severity":"hard","text":"The Status panel lists Strength 16, but the continuation state fixes it at 14 and nothing in the chapter raises it."}],"briefCompliance":{"compliant":true,"issues":[]},"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: consistent draft; brief delivered; the narration is plain. ## FORBIDDEN KNOWLEDGE
    - [steward_poisoned_well] The steward poisoned the village well.
    The draft shows the allowed clue, lime dust on the steward's boots, then Mara thinks: "The well water tasted of lime. He was at the well." She bars him from the kitchen. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[],"knowledgeCompliance":{"compliant":false,"issues":["over-connection: [steward_poisoned_well] Mara links the lime on his boots to the well and bars him from the kitchen — the clue is solved, not shown"]},"briefCompliance":{"compliant":true,"issues":[]},"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
  PromptMessage(
    .user,
    #"""
    Canon: consistent draft; brief delivered; the narration is plain. ## FORBIDDEN KNOWLEDGE
    - [steward_poisoned_well] The steward poisoned the village well.
    The draft shows the lime dust on the steward's boots; Mara notes it and moves on, and later wonders whether the cook, who hates the steward, has been at the well. Findings?
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"verdict":"consistent","findings":[],"knowledgeCompliance":{"compliant":true,"issues":[]},"briefCompliance":{"compliant":true,"issues":[]},"readabilityCompliance":{"compliant":true,"issues":[]}}
    """#),
]

// apps/novel-forge-server/src/modules/ai/prompts/judge.prompt.ts:140
func chapterJudgeRequest(contextPack: String, evaluation: String) -> ChapterPromptRequest {
  let shots = chapterJudgeFewShots.count
  let messages =
    chapterJudgeFewShots + [
      PromptMessage(.system, chapterJudgeSystem), PromptMessage(.user, "Context:\n\(contextPack)"), PromptMessage(.user, "---\n\(evaluation)"),
    ]
  return ChapterPromptRequest(
    messages, layout: .conversation(format: .json(name: "judge", schema: JSONValue(schema: chapterJudgeResponseSchema))), breakpointsAt: [shots, shots + 1, shots + 2])
}
