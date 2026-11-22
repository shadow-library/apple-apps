import ShadowText

// apps/novel-forge-server/src/modules/ai/prompts/chat-compact.prompt.ts:7
let chatCompactSystem =
  #"You compact a story-refinement conversation into a rolling summary the next turns can rely on. Fold the given transcript into the prior summary. Preserve, densely and factually: decisions the author accepted, directions explicitly rejected (and why), proposals still pending, and open questions. Drop pleasantries, restatements, and anything superseded by a later decision. The summary substitutes for the folded turns, so a wrong or missing fact here corrupts the whole conversation — be precise, never embellish. Respond with ONLY one valid JSON object of the shape {"summary": string}."#

let chatCompactVersion = "1.0.0"

func chatCompactMessages(priorSummary: String, transcript: String) -> [PromptMessage] {
  [
    PromptMessage(.system, chatCompactSystem),
    PromptMessage(.user, "Prior summary:\n\(priorSummary)\n\nTranscript to fold in:\n\(transcript)"),
  ]
}

let chatCompactSchemaName = "chat-compact"

let chatCompactSchema: OrderedJSON = jsonObject([
  ("type", .string("object")),
  ("additionalProperties", .bool(false)),
  (
    "properties",
    jsonObject([
      (
        "summary",
        jsonObject([
          ("type", .string("string")), ("minLength", .int(1)),
          ("description", .string("the folded summary: decisions made, directions rejected, open questions — dense, factual, no prose flourish")),
        ])
      )
    ])
  ),
  ("required", .array([.string("summary")])),
])
