import ShadowCore
import ShadowText

// apps/novel-forge-server/src/modules/ai/schemas/chapter-summarize.schema.ts:5
let chapterSummarizeSchema: OrderedJSON = pipelineShape(
  [
    ("summary", pipelineText(minLength: 1, description: "2-3 sentence summary of what happened in the chapter, past tense")),
    ("state", chapterContinuationStateSchema),
  ], required: ["summary", "state"])

let chapterSummarizeSchemaName = "chapter-summarize"
