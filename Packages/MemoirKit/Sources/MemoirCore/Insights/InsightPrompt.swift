import ShadowAI
import ShadowCore
import ShadowText

/// The prompt half of the response contract, word for word; every rule in it also has a filter behind it in `InsightGuardrails`.
// apps/memoir-server/src/modules/ai-worker/prompt-contract.ts:8-30
public enum InsightPrompt {
  /// The reference's `ai.prompt-version`, stored with every result (bootstrap.ts:147).
  public static let version = "v1"
  public static let schemaName = "memoir_insight"

  public static let system = [
    "You analyse one person's own life and habit-tracking data and answer the question they asked about it.",
    "The data is theirs; it was assembled under their explicit consent, and you are given only what the question needs.",
    "",
    "Rules, all mandatory:",
    "1. Never quote their journal entries, reflections, or reason notes. Paraphrase, always.",
    "2. Never assert an identity or a diagnosis. No \"you are ...\", no clinical labels. Report what they DID, and when.",
    "3. If the question or the data suggests acute self-harm risk, do not coach. Say so plainly and stop.",
    "4. You cannot change anything. Never claim to have edited a quest, awarded XP, or altered any game state.",
    "5. No shame, no blame, no streak-loss framing. Neutral and factual.",
    "6. Correlate across domains — quest adherence against spending, HP against schedule, mood against completion.",
    "7. If there is under a week of data, answer anyway and say plainly what the thin dataset does not support.",
    "",
    "Reply with JSON only: { \"answer\": string, \"patterns\": string[], \"suggestions\": [{ \"kind\": one of "
      + InsightGuardrails.allowedSuggestionKinds.map { "\"\($0)\"" }.joined(separator: " | ")
      + ", \"questId\": string, \"text\": string }], \"limitationNote\": string | null }.",
    "Give one or two suggestions, each naming a quest id present in the data — they become one-tap offers the person confirms themselves.",
  ].joined(separator: "\n")

  /// The reply checked about as far as `parseDraft` reads it, so its tolerance and the guardrails' filtering decide the rest: only `answer` is required,
  /// `patterns` may hold any values, a suggestion requires nothing, and a numeric quest id is let through for the guardrails to compare. Objects stay
  /// closed and members typed because native output needs that; in the prompt form a reply with another member, or a mistyped one, costs one repair
  /// re-ask where the reference would drop it.
  public static let schema: JSONValue = [
    "type": "object",
    "properties": [
      "answer": ["type": "string"],
      "patterns": ["type": "array"],
      "suggestions": [
        "type": "array",
        "items": [
          "type": "object",
          "properties": ["kind": ["type": "string"], "questId": ["type": ["string", "number"]], "text": ["type": "string"]],
          "additionalProperties": false,
        ],
      ],
      "limitationNote": ["type": ["string", "null"]],
    ],
    "required": ["answer"],
    "additionalProperties": false,
  ]

  /// `buildPrompt`: the question, then the assembled data as `JSON.stringify` writes it.
  public static func user(question: String, context: OrderedJSON) -> String {
    ["Question: \(question)", "", "Data:", context.jsonText].joined(separator: "\n")
  }
}
