import ShadowCore
import ShadowText

private func string(_ extra: [(String, OrderedJSON)] = []) -> OrderedJSON { jsonObject([("type", .string("string"))] + extra) }

private func merged(_ base: OrderedJSON, over overrides: OrderedJSON) -> OrderedJSON {
  guard let base = base.objectValue, let overrides = overrides.objectValue else { return overrides }
  return .object(
    OrderedJSONObject(
      base.entries.map { (key: $0.key, value: overrides[$0.key] ?? $0.value) } + overrides.entries.filter { base[$0.key] == nil }.map { (key: $0.key, value: $0.value) }))
}

private let chatRefineProperties: [(String, OrderedJSON)] = [
  (
    "reply",
    string([
      ("minLength", .int(1)), ("description", .string("the conversational reply to the user — ideas, critique, rationale for any proposed changes")),
    ])
  ),
  (
    "changeSet",
    jsonObject([
      ("type", .string("array")), ("items", jsonObject([("type", .string("object"))])),
      ("description", .string("change-set ops from the scope allowlist; omit entirely when the turn is discussion only")),
    ])
  ),
  (
    "lookups",
    jsonObject([
      ("type", .string("array")),
      (
        "items",
        jsonObject([
          ("type", .string("object")), ("additionalProperties", .bool(true)),
          (
            "properties",
            jsonObject([
              ("tool", string([("description", .string("the lookup tool name, exactly as listed in the playbook"))])),
              (
                "args",
                jsonObject([("type", .string("object")), ("additionalProperties", .bool(true)), ("description", .string("the arguments for the tool"))])
              ),
            ])
          ),
          ("required", .array([.string("tool")])),
        ])
      ),
      ("description", .string("lookups to run before answering — hub scope only, never alongside a changeSet")),
    ])
  ),
  (
    "question",
    jsonObject([
      (
        "description",
        .string(
          "An identity decision the author has not made yet: 2-4 example answers with trade-offs and a recommendation, 'undecided for now' always accepted. Never alongside lookups. { question: string, why?: string, answers: [{ title: string, why?: string, tradeOff?: string, recommended?: boolean }], progressKey?: string } — any shape is accepted here, the server drops what doesn't fit."
        )
      )
    ])
  ),
]

private func chatRefineSchema(_ properties: [(String, OrderedJSON)]) -> OrderedJSON {
  jsonObject([
    ("type", .string("object")), ("additionalProperties", .bool(false)), ("properties", jsonObject(properties)), ("required", .array([.string("reply")])),
  ])
}

// apps/novel-forge-server/src/modules/ai/schemas/chat-refine.schema.ts:14
let chatRefineSchema: OrderedJSON = chatRefineSchema(chatRefineProperties)

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:86
let chatRefineConstrainedSchema: OrderedJSON = chatRefineSchema(
  chatRefineProperties.map { name, schema in
    switch name {
    case "changeSet": (name, merged(schema, over: jsonObject([("items", ChangeSetItemSchema(hubAllowedOps, options: OpVocabularyOptions(quotes: true)).json)])))
    case "question": (name, merged(schema, over: chatQuestionWireSchema))
    case "lookups": (name, merged(schema, over: jsonObject([("maxItems", .int(0))])))
    default: (name, schema)
    }
  })

extension JSONValue {
  init(schema: OrderedJSON) {
    switch schema {
    case .null: self = .null
    case .bool(let flag): self = .bool(flag)
    case .int(let number): self = .int(number)
    case .double(let number): self = Int64(exactly: number).map(JSONValue.int) ?? .null
    case .string(let text): self = .string(text)
    case .array(let items): self = .array(items.map(JSONValue.init(schema:)))
    case .object(let fields): self = .object(Dictionary(fields.entries.map { ($0.key, JSONValue(schema: $0.value)) }) { _, last in last })
    }
  }
}
