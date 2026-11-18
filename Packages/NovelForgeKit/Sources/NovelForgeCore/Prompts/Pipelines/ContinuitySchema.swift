import ShadowCore

private let confidence = pipelineChoice(["high", "low"])

private func intentionallyOpen(_ kind: String) -> OrderedJSON {
  pipelineFlag("marked as a deliberate running \(kind), not an oversight — novel-validation must not flag it as unresolved")
}

private let continuityMilestone = pipelineShape(
  [
    ("milestoneKey", pipelineText(minLength: 1, description: "a key from the MILESTONES list in the context pack")),
    ("reached", pipelineFlag("true when the prose shows the milestone happening in this chapter")),
    ("evidence", pipelineText(description: "excerpt from the prose that shows it happening; omit when it does not happen")),
  ], required: ["milestoneKey", "reached"])

private let continuityNewEntity = pipelineShape(
  [
    ("entityKey", pipelineText(minLength: 1)), ("name", pipelineText(minLength: 1)), ("type", pipelineChoice(EntityType.allCases.map(\.rawValue))), ("notes", pipelineText()),
  ], required: ["entityKey", "name", "type"])

private let continuityThread = pipelineShape(
  [
    ("threadKey", pipelineText(minLength: 1)), ("status", pipelineChoice(ThreadStatus.allCases.map(\.rawValue))), ("summary", pipelineText()),
    ("intentionallyOpen", intentionallyOpen("thread")), ("confidence", confidence),
  ], required: ["threadKey", "status"])

private let continuityMystery = pipelineShape(
  [
    ("mysteryKey", pipelineText(minLength: 1)), ("status", pipelineChoice(MysteryStatus.allCases.map(\.rawValue))), ("question", pipelineText()),
    ("intentionallyOpen", intentionallyOpen("mystery")),
    ("truthFactKey", pipelineText(description: "corresponds to a canon_facts.factKey — the hidden fact that answers this mystery, when the prose has revealed which one it is")),
    ("confidence", confidence),
  ], required: ["mysteryKey", "status"])

private let continuityTimelineEvent = pipelineShape(
  [("whenText", pipelineText()), ("event", pipelineText(minLength: 1)), ("significance", pipelineText())], required: ["event"])

private let continuityRelationship = pipelineShape(
  [
    ("entityKey", pipelineText(minLength: 1)), ("targetKey", pipelineText(minLength: 1)), ("kind", pipelineText(minLength: 1)), ("note", pipelineText()),
    ("evidence", pipelineText(minLength: 1, description: "excerpt from the prose that justifies this relationship update")), ("confidence", confidence),
  ], required: ["entityKey", "targetKey", "kind", "evidence"])

private let continuityPower = pipelineShape(
  [("character", pipelineText(minLength: 1)), ("stage", pipelineText(minLength: 1)), ("feat", pipelineText()), ("next", pipelineText())], required: ["character", "stage"])

private let continuityCharacterState = pipelineShape(
  [
    ("entityKey", pipelineText(minLength: 1)), ("location", pipelineText()), ("conditions", pipelineList(pipelineText())), ("immediateGoal", pipelineText()),
    ("statusNote", pipelineText()), ("evidence", pipelineText(minLength: 1, description: "excerpt from the prose that justifies this state extraction")),
    ("confidence", confidence),
  ], required: ["entityKey", "evidence"])

private let continuityKnowledgeChange = pipelineShape(
  [
    ("entityKey", pipelineText(minLength: 1)), ("factKey", pipelineText(minLength: 1, description: "corresponds to a canon_facts.factKey — what the character now knows")),
    ("how", pipelineText(minLength: 1, description: "short description of how the character learned it")),
  ], required: ["entityKey", "factKey", "how"])

// apps/novel-forge-server/src/modules/ai/schemas/continuity.schema.ts:179
let continuitySchema: OrderedJSON = pipelineShape(
  [
    (
      "milestones",
      pipelineList(
        continuityMilestone, description: "every milestone the chapter plan claims, and any other listed milestone the prose shows happening, with whether it was reached")
    ),
    ("appeared", pipelineList(pipelineText(), description: "entityKeys of entities who appear in this chapter")),
    ("newEntities", pipelineList(continuityNewEntity, description: "new entities introduced in this chapter not yet in the knowledge base")),
    ("threads", pipelineList(continuityThread)),
    ("mysteries", pipelineList(continuityMystery)),
    ("timeline", pipelineList(continuityTimelineEvent)),
    ("relationships", pipelineList(continuityRelationship)),
    ("power", pipelineList(continuityPower)),
    ("characterStates", pipelineList(continuityCharacterState, description: "characters whose state materially changed this chapter — replaces, not merges, the prior state")),
    ("knowledgeChanges", pipelineList(continuityKnowledgeChange, description: "canon facts a character newly came to know this chapter")),
    ("chapterSummary", pipelineText(minLength: 1, description: "2-3 sentence summary of what happened")),
  ], required: ["appeared", "newEntities", "threads", "mysteries", "timeline", "relationships", "power", "characterStates", "knowledgeChanges", "chapterSummary"])

let continuitySchemaName = "continuity"
