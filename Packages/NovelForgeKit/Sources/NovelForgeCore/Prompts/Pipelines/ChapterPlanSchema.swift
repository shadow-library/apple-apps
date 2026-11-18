import ShadowCore

private let readerValueChanges = ["new_information", "relationship_change", "power_or_stakes_change", "goal_or_plan_change", "world_state_change", "emotional_turn"]
private let readerValueDescription = "at least one concrete thing that changes this chapter, each drawn from: \(readerValueChanges.joined(separator: ", "))"
private let hookTypes = ["cliffhanger", "revelation", "quiet_dread", "promise", "turn", "closure_with_momentum", "earned_rest"]
private let keyPattern = "^[a-z0-9_]+$"

private func keyText(_ description: String) -> OrderedJSON {
  jsonObject([("type", .string("string")), ("pattern", .string(keyPattern)), ("description", .string(description))])
}

private let planScene = pipelineShape(
  [
    ("summary", pipelineText(minLength: 1, description: "one sentence the author reads on the plan card: what happens in this scene")),
    ("pov", pipelineText(description: "entity key of the character whose point of view this scene is told from")),
    ("goal", pipelineText(minLength: 1, description: "what the POV character wants in this scene")),
    ("obstacle", pipelineText(minLength: 1, description: "who or what stands in the way")),
    ("turn", pipelineText(minLength: 1, description: "how the situation has changed when the scene ends")),
    ("beats", pipelineList(pipelineText(), minItems: 1, description: "the on-page beats of the scene, in order")),
    ("estimatedWords", pipelineWhole(minimum: 1, description: "the share of the chapter length this scene will fill when dramatized")),
  ], required: ["summary", "goal", "obstacle", "turn", "beats", "estimatedWords"])

private let planEndingContract = pipelineShape(
  [
    ("hookType", pipelineChoice(hookTypes)),
    ("emotionalBeat", pipelineText(minLength: 1, description: "what the reader should feel on the last line")),
    ("openQuestion", pipelineText(minLength: 1, description: "the question the ending must leave open")),
    ("handoffState", pipelineText(minLength: 1, description: "the situation the next chapter picks up from — specific enough for a different author to continue")),
    ("mustNotResolve", pipelineList(pipelineText(), description: #"refs (e.g. "thread:heir_mystery") the ending must NOT resolve"#)),
  ], required: ["hookType", "emotionalBeat", "openQuestion", "handoffState"])

private let planKnowledgeContract = pipelineShape(
  [
    ("pov", pipelineList(pipelineText(), minItems: 1, description: "entity keys whose ledgered knowledge bounds what the chapter may state")),
    (
      "learns",
      pipelineList(
        pipelineShape(
          [
            ("entityKey", keyText("entity key of the character who learns the fact on-page this chapter")),
            ("factKey", keyText("key of the canon fact being revealed")),
          ], required: ["entityKey", "factKey"]),
        description: "facts discovered on-page during this chapter; ledgered when the draft is approved")
    ),
  ], required: ["pov"])

private func planSchema(readerValueItems: OrderedJSON) -> OrderedJSON {
  pipelineShape(
    [
      ("title", pipelineText(minLength: 1)),
      ("objective", pipelineText(minLength: 1, description: "what this chapter does in the story")),
      ("scenes", pipelineList(planScene, minItems: 1, description: "the scenes of the chapter, in order, each naming its point of view")),
      ("requiredContext", pipelineList(pipelineText(), description: "context refs from the catalog the chapter needs, most important first")),
      ("continuesIntoNextChapter", pipelineFlag("the chapter ends with its central action still live, handed to the next chapter")),
      ("startsFromPreviousChapter", pipelineFlag("the chapter opens in the exact beat the previous chapter handed off")),
      ("handoffBeat", pipelineText(description: "the moment where continuation picks up — required when either continuation flag is true")),
      ("endingContract", planEndingContract),
      ("knowledgeContract", planKnowledgeContract),
      ("claimedMilestones", pipelineList(pipelineText(), description: "keys from the MILESTONES list that this chapter reaches on the page")),
      ("chapterPurpose", pipelineText(minLength: 1, description: "one sentence: why this chapter exists — its job in the story, not a restatement of the objective's events")),
      ("readerValue", pipelineList(readerValueItems, minItems: 1, description: readerValueDescription)),
      ("repetitionRisks", pipelineList(pipelineText(), description: "scene patterns from recent chapters this one must not repeat")),
      ("densityRisk", pipelineText(minLength: 1, description: "set only when the material cannot honestly fill the length target: what is missing and the remedy")),
      ("moves", pipelineText(minLength: 1, description: "which of the obligations this chapter moves, and how")),
    ], required: ["title", "objective", "scenes", "requiredContext", "endingContract", "chapterPurpose", "readerValue"])
}

// apps/novel-forge-server/src/modules/ai/schemas/chapter-plan.schema.ts:31
let chapterPlanSchema: OrderedJSON = planSchema(readerValueItems: pipelineText())

// apps/novel-forge-server/src/modules/ai/prompts/chapter-plan.prompt.ts:58
let chapterPlanConstrainedSchema: OrderedJSON = planSchema(readerValueItems: pipelineChoice(readerValueChanges))

let chapterPlanSchemaName = "chapter-plan"

let chapterPlanReaderValueChanges = readerValueChanges

let chapterPlanKeyPattern = keyPattern

// StructuredSchema.validate implements no `pattern`, so a call passes this schema and chapterPlanReview enforces the key pattern.
let chapterPlanCallSchema: OrderedJSON = withoutPatterns(chapterPlanSchema)

private func withoutPatterns(_ schema: OrderedJSON) -> OrderedJSON {
  switch schema {
  case .array(let items): .array(items.map(withoutPatterns))
  case .object(let fields): .object(OrderedJSONObject(fields.entries.filter { $0.key != "pattern" }.map { (key: $0.key, value: withoutPatterns($0.value)) }))
  default: schema
  }
}
