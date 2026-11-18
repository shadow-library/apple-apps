import ShadowAI

// apps/novel-forge-server/src/modules/ai/prompts/fix.prompt.ts:33
let chapterFixVersion = "1.7.1"

// apps/novel-forge-server/src/modules/ai/prompts/fix.prompt.ts:8
let chapterFixSystem =
  #"""
  \#(authoringStyleRepair)

  \#(editByDeletion)

  You are a surgical editor tasked with repairing continuity contradictions in a chapter draft. You receive the draft, the judge's findings (with [HARD] severity markers), and the established canon. Choose: PATCH if the contradiction can be fixed with targeted find/replace operations (preferred — minimize disruption). REWRITE if the contradiction is structural and patches cannot fix it. For patches: find strings must be unique and verbatim; replace text must preserve prose style. Minimal intervention only — do not rewrite sections that are not contradicted. Findings marked "readability:" quote the draft's own sentences: patch each quoted sentence into plain contemporary prose — split long sentences, replace ornate phrases and metaphors with plain words, break long paragraphs — keeping every fact, action, and line of dialogue.

  \#(clueDiscipline)

  System panels (```system <Title> fenced blocks) and tables are the story's in-world interface, not prose: never turn one into narration or narration into one, and never rewrite one for readability. Change a panel only where a finding names a wrong value or broken format in it, and then fix just that line or close its fence, keeping the table rows intact.

  Respond with ONLY one valid JSON object — nothing outside the JSON, no markdown fences — of exactly this shape:
  {"action": "patch" or "rewrite", "patches": [{"find": "...", "replace": "..."}] (patch only), "body": "..." (rewrite only)}
  """#

// apps/novel-forge-server/src/modules/ai/prompts/fix.prompt.ts:17
let chapterFixFewShots: [PromptMessage] = [
  PromptMessage(
    .user,
    #"""
    Hard finding: Li Wei uses the Void Step technique in paragraph 3, but Void Step was not unlocked until Chapter 15 (this is Chapter 12). Draft paragraph: "With practiced ease, Li Wei executed the Void Step, vanishing from sight."
    """#),
  PromptMessage(
    .assistant,
    #"""
    {"action":"patch","patches":[{"find":"Li Wei executed the Void Step, vanishing from sight","replace":"Li Wei launched into a burst of footwork, weaving between the guards with trained precision"}]}
    """#),
]

// apps/novel-forge-server/src/modules/ai/prompts/fix.prompt.ts:38
func chapterFixRequest(contextPack: String, prose: String, findings: String) -> ChapterPromptRequest {
  let messages =
    [PromptMessage(.system, chapterFixSystem)] + chapterFixFewShots + [
      PromptMessage(.user, contextPack), PromptMessage(.user, "Draft to repair:\n\(prose)\n\nFindings:\n\(findings)"),
    ]
  return ChapterPromptRequest(messages, layout: .conversation(format: .text), skippingUsers: chapterFixFewShots.filter { $0.role == .user }.count)
}
