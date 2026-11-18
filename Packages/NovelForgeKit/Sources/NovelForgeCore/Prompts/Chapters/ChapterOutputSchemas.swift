import ShadowCore

// apps/novel-forge-server/src/modules/ai/schemas/generation.schema.ts:13
let chapterContinuationStateSchema: OrderedJSON = shapeSchema(
  [
    ("openConflict", textSchema(description: #"the unresolved conflict/tension active at chapter end, if any"#)),
    (
      "characterPositions",
      listSchema(
        shapeSchema(
          [
            ("entityKey", textSchema(minLength: 1, description: #"the character's entity key, exactly as the story context's roster lists it"#)),
            (
              "location",
              textSchema(minLength: 1, maxLength: 60, description: #"where the character is at the cutoff, as a place only — "the lamp room", "on the north pier""#)
            ),
          ], required: ["entityKey", "location"]), #"where each on-scene character is, physically, at the cutoff — one entry per character"#)
    ),
    ("lastBeat", textSchema(description: #"the exact last action, line, or decision — what the next chapter must resume from"#)),
    ("emotionalState", textSchema(description: #"POV character emotional state at cutoff"#)),
    (
      "establishedFacts",
      listSchema(
        textSchema(),
        #"concrete facts fixed on the page that later chapters must not contradict, one short entry each: exact figures and measurements, times, distances, injuries, possessions and where objects are, who knows or has been told what, promises made and questions left open. Carry forward every entry of the incoming CONTINUATION STATE that still holds, drop what this chapter changed, add what it newly fixed; at most 15 entries"#
      )
    ),
  ], required: [])

// apps/novel-forge-server/src/modules/ai/schemas/generation.schema.ts:37
let chapterGenerationSchema: OrderedJSON = shapeSchema(
  [
    ("title", textSchema(minLength: 1, maxLength: 200, description: #"chapter title"#)),
    ("body", textSchema(minLength: 100, description: #"full chapter prose — scene content at the length the system prompt specifies"#)),
    ("summary", textSchema(minLength: 1, description: #"2-3 sentence summary of what happened, past tense"#)),
    ("state", chapterContinuationStateSchema),
  ], required: ["title", "body", "summary"])

// apps/novel-forge-server/src/modules/ai/schemas/chapter-expand.schema.ts:4
let chapterExpandSchema: OrderedJSON = shapeSchema(
  [
    (
      "body",
      textSchema(minLength: 100, description: #"the complete expanded chapter prose — every scene of the draft, same events and same final beat, lengthened to the requested size"#)
    )
  ], required: ["body"])

// apps/novel-forge-server/src/modules/ai/schemas/title.schema.ts:4
let chapterTitleSchema: OrderedJSON = shapeSchema(
  [
    ("title", textSchema(minLength: 1, maxLength: 200, description: #"chapter title, evocative and consistent with established chapter title style"#)),
    ("alternatives", listSchema(textSchema(), #"2-3 alternatives if uncertain"#)),
  ], required: ["title"])

// apps/novel-forge-server/src/modules/ai/schemas/fix.schema.ts:20
let chapterFixSchema: OrderedJSON = withConditional(
  shapeSchema(
    [
      ("action", choiceSchema(["patch", "rewrite"])),
      (
        "patches",
        listSchema(
          shapeSchema(
            [
              ("find", textSchema(minLength: 1, description: #"exact verbatim text to find in the draft — must be unique within the chapter"#)),
              ("replace", textSchema(minLength: 1, description: #"replacement text; preserves surrounding prose style"#)),
            ], required: ["find", "replace"]))
      ),
      ("body", textSchema(description: #"for rewrite only: complete replacement chapter prose"#)),
    ], required: ["action"]), if: jsonObject([("properties", jsonObject([("action", jsonObject([("const", .string(#"patch"#))]))])), ("required", .array([.string(#"action"#)]))]),
  then: jsonObject([("properties", jsonObject([("patches", jsonObject([("type", .string(#"array"#)), ("minItems", .int(1))]))])), ("required", .array([.string(#"patches"#)]))]),
  else: jsonObject([("properties", jsonObject([("body", jsonObject([("type", .string(#"string"#)), ("minLength", .int(1))]))])), ("required", .array([.string(#"body"#)]))]))

// apps/novel-forge-server/src/modules/ai/schemas/judge.schema.ts:61, as sent for response_format (model-router.service.ts:140, schemas/validate.ts toConstrainedSchema)
let chapterJudgeResponseSchema: OrderedJSON =
  shapeSchema(
    [
      ("verdict", choiceSchema(["consistent", "contradiction", "evaluation_failed"])),
      (
        "findings",
        listSchema(
          shapeSchema(
            [
              ("severity", choiceSchema(["hard", "soft"])),
              ("text", textSchema(description: #"one finding, citing the canon it conflicts with (chapter or tracker)"#)),
            ], required: ["severity", "text"]))
      ),
      (
        "endingCompliance",
        shapeSchema(
          [
            ("compliant", flagSchema(description: #"true when the draft ending satisfies every field of the brief ending contract"#)),
            ("issues", listSchema(textSchema(), #"each contract violation, citing the field it breaks (hookType, emotionalBeat, openQuestion, handoffState, mustNotResolve)"#)),
          ], required: ["compliant", "issues"])
      ),
      (
        "knowledgeCompliance",
        shapeSchema(
          [
            (
              "compliant",
              flagSchema(description: #"true when the draft neither states a forbidden fact nor lets a character act on information they could only have if they knew it"#)
            ),
            ("issues", listSchema(textSchema(), #"each leak, citing the forbidden fact key and where the draft exposes it"#)),
          ], required: ["compliant", "issues"])
      ),
      (
        "briefCompliance",
        shapeSchema(
          [
            ("compliant", flagSchema(description: #"true when the draft delivers the objective and every planned event of the chapter brief"#)),
            ("issues", listSchema(textSchema(), #"each unfulfilled part of the brief, naming the objective or event the draft skips, defers, or replaces"#)),
          ], required: ["compliant", "issues"])
      ),
      (
        "readabilityCompliance",
        shapeSchema(
          [
            ("compliant", flagSchema(description: #"true unless the draft reads as ornate or literary rather than plain contemporary web-novel English"#)),
            ("issues", listSchema(textSchema(), #"each problem, quoting the offending sentence verbatim and saying how to make it plain"#)),
          ], required: ["compliant", "issues"])
      ),
    ], required: ["verdict", "findings"])

let chapterJudgeSchema: OrderedJSON = withConditional(
  chapterJudgeResponseSchema,
  if: jsonObject([("properties", jsonObject([("verdict", jsonObject([("const", .string(#"contradiction"#))]))])), ("required", .array([.string(#"verdict"#)]))]),
  then: jsonObject([
    (
      "properties",
      jsonObject([
        (
          "findings",
          jsonObject([
            ("type", .string(#"array"#)),
            (
              "contains",
              jsonObject([
                ("type", .string(#"object"#)), ("properties", jsonObject([("severity", jsonObject([("const", .string(#"hard"#))]))])),
                ("required", .array([.string(#"severity"#)])),
              ])
            ),
          ])
        )
      ])
    ), ("required", .array([.string(#"findings"#)])),
  ]))

// apps/novel-forge-server/src/modules/ai/schemas/ending-contract.schema.ts:6
let chapterEndingContractSchema: OrderedJSON = shapeSchema(
  [
    ("hookType", choiceSchema(["cliffhanger", "revelation", "quiet_dread", "promise", "turn", "closure_with_momentum", "earned_rest"])),
    ("emotionalBeat", textSchema(minLength: 1, description: #"what the reader should feel on the last line"#)),
    ("openQuestion", textSchema(minLength: 1, description: #"the question the ending must leave open"#)),
    ("handoffState", textSchema(minLength: 1, description: #"the situation the next chapter picks up from — specific enough for a different author to continue"#)),
    ("mustNotResolve", listSchema(textSchema(), #"refs (e.g. "thread:heir_mystery") the ending must NOT resolve"#)),
  ], required: ["hookType", "emotionalBeat", "openQuestion", "handoffState"])

private func textSchema(minLength: Int? = nil, maxLength: Int? = nil, description: String? = nil) -> OrderedJSON {
  var fields: [(String, OrderedJSON)] = [("type", .string("string"))]
  if let minLength { fields.append(("minLength", .int(Int64(minLength)))) }
  if let maxLength { fields.append(("maxLength", .int(Int64(maxLength)))) }
  if let description { fields.append(("description", .string(description))) }
  return jsonObject(fields)
}

private func choiceSchema(_ values: [String]) -> OrderedJSON {
  jsonObject([("type", .string("string")), ("enum", .array(values.map { .string($0) }))])
}

private func flagSchema(description: String) -> OrderedJSON {
  jsonObject([("type", .string("boolean")), ("description", .string(description))])
}

private func listSchema(_ items: OrderedJSON, _ description: String? = nil) -> OrderedJSON {
  jsonObject([("type", .string("array")), ("items", items)] + (description.map { [("description", OrderedJSON.string($0))] } ?? []))
}

private func shapeSchema(_ properties: [(String, OrderedJSON)], required: [String]) -> OrderedJSON {
  jsonObject([
    ("type", .string("object")), ("additionalProperties", .bool(false)), ("properties", jsonObject(properties)), ("required", .array(required.map { .string($0) })),
  ])
}

private func withConditional(_ schema: OrderedJSON, if condition: OrderedJSON, then: OrderedJSON, else otherwise: OrderedJSON? = nil) -> OrderedJSON {
  guard let fields = schema.objectValue else { return schema }
  return jsonObject([("if", condition), ("then", then)] + (otherwise.map { [("else", $0)] } ?? []) + fields.entries.map { ($0.key, $0.value) })
}
