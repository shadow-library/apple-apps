import ShadowCore

private let proofreadKinds = ["grammar", "spelling", "punctuation", "tense", "pov", "name", "reference"]

private let editorialFinding = pipelineShape(
  [
    ("severity", pipelineChoice(["blocking", "suggestion"])), ("text", pipelineText(minLength: 1, description: "specific finding with location if possible")),
    ("evidence", pipelineText(description: "the passage the finding rests on, quoted verbatim from the draft; omit when the finding is about something missing")),
  ], required: ["severity", "text"])

private let proofreadSlip = pipelineShape(
  [
    ("kind", pipelineChoice(proofreadKinds)),
    ("quote", pipelineText(minLength: 1, description: "the exact offending span, copied verbatim from the draft with a few words around the slip")),
    ("fix", pipelineText(minLength: 1, description: "the same span corrected, changing only the slip")),
    (
      "reason",
      pipelineText(description: "a few words on why, when the fix alone does not say it (the spelling the Story Bible uses, the tense the scene is in)")
    ),
  ], required: ["kind", "quote", "fix"])

// apps/novel-forge-server/src/modules/ai/schemas/review.schema.ts:32
let editorialReviewSchema: OrderedJSON = pipelineShape(
  [
    ("disposition", pipelineChoice(["approve", "revision_requested"])), ("note", pipelineText(description: "overall note to the author")),
    ("findings", pipelineList(editorialFinding)),
    ("proofreading", pipelineList(proofreadSlip, description: "every proofreading slip, most important first; an empty array when the prose is clean")),
  ], required: ["disposition"])

let editorialReviewSchemaName = "review"
