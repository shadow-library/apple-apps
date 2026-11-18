import ShadowCore

private let canonRefreshEvidence = pipelineShape(
  [
    ("ref", pipelineText(minLength: 1, description: #"the source this rests on, exactly as labelled in the material: "chapter:<n>", "doc:<section>/<slug>" or "entity:<key>""#)),
    ("quote", pipelineText(minLength: 1, description: "the words of that source, copied verbatim from the material")),
  ], required: ["ref", "quote"])

private func canonRefreshUpdate(changeSet: OrderedJSON) -> OrderedJSON {
  pipelineShape(
    [
      (
        "finding",
        pipelineText(minLength: 1, description: "what the chapter established and which page or record no longer says it, in one or two plain sentences the author can act on")
      ),
      (
        "evidence",
        pipelineList(
          canonRefreshEvidence, minItems: 1, description: "the chapter’s own words first, then the out-of-date words of the page or record when it states something else")
      ),
      ("changeSet", changeSet),
    ], required: ["finding", "evidence", "changeSet"])
}

private func canonRefreshSchema(changeSet: OrderedJSON) -> OrderedJSON {
  pipelineShape(
    [
      (
        "updates",
        pipelineList(
          canonRefreshUpdate(changeSet: changeSet), description: "one entry per page or record the chapter left out of date; empty when the Story Bible already reflects it")
      )
    ], required: ["updates"])
}

private let canonRefreshChangeDescription = "the ops that bring the page or record up to date (bible_document.upsert, entity.upsert only)"

// apps/novel-forge-server/src/modules/ai/schemas/chapter-canon-refresh.schema.ts:27
let canonRefreshSchema: OrderedJSON = canonRefreshSchema(
  changeSet: pipelineList(jsonObject([("type", .string("object"))]), minItems: 1, description: canonRefreshChangeDescription))

// apps/novel-forge-server/src/modules/ai/prompts/chapter-canon-refresh.prompt.ts:40
let canonRefreshConstrainedSchema: OrderedJSON = canonRefreshSchema(
  changeSet: pipelineList(ChangeSetItemSchema(canonRefreshOps).json, minItems: 1, description: canonRefreshChangeDescription))

let canonRefreshSchemaName = "chapter-canon-refresh"
