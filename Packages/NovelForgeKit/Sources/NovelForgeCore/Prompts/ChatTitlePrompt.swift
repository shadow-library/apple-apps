import ShadowText

// apps/novel-forge-server/src/modules/ai/prompts/chat-title.prompt.ts:7
let chatTitleSystem =
  #"""
  You name a chat conversation from the author's opening message alone — there is no reply yet, so name only what this message asks for, never what the reply might say. Give it a short title: 2–6 words for what the author is trying to DO in this conversation — the task, the question, the decision — not what the novel is about. "Kaela's contradicted vow", "Volume 2 pacing", "Briefs for chapters 40-45" are titles; a title that would sit unchanged on any other conversation in this novel has failed, because it named the setting instead of the ask. Use only what the message says — never invent a character, place, or plot detail it does not mention. If the message is a bare instruction with no story content — "fix this", "regenerate chapter 12", "undo that" — name the action itself, not a guessed subject. If it is long, rambling, or raises several things at once, title it for the one ask that matters most; do not try to cover all of them. No quotation marks, no trailing punctuation, no "Chat about…" or "Request to…" preamble.

  Respond with ONLY one valid JSON object — nothing outside the JSON, no markdown fences — of exactly this shape: {"title": "..."}
  """#

let chatTitleVersion = "1.0.0"

// apps/novel-forge-server/src/modules/ai/schemas/chat-title.schema.ts:3
let chatTitleMaxLength = 60

func chatTitleMessages(message: String) -> [PromptMessage] {
  [PromptMessage(.system, chatTitleSystem), PromptMessage(.user, "The author's opening message:\n\(message)")]
}

let chatTitleSchemaName = "chat-title"

let chatTitleSchema: OrderedJSON = jsonObject([
  ("type", .string("object")),
  ("additionalProperties", .bool(false)),
  (
    "properties",
    jsonObject([
      (
        "title",
        jsonObject([
          ("type", .string("string")), ("minLength", .int(1)), ("maxLength", .int(Int64(chatTitleMaxLength))),
          ("description", .string("2–6 words naming what the author is trying to do in this conversation — not the story, no quotes, no trailing punctuation")),
        ])
      )
    ])
  ),
  ("required", .array([.string("title")])),
])
