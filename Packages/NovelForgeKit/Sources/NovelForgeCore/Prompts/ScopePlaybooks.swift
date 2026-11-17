// apps/novel-forge-server/src/modules/notes/organise-plan.ts:60
let organiseMinWords = 600

// packages/sdk/src/organise.ts:6
private let timelineOpeningLabel = "The opening"

private let laterMaterial = [
  "Organising the author's notes is action.organise_notes, never pages you write yourself: when they hand you their notes or ask you to organise them and the notes run to \(organiseMinWords) words or more, propose that action alone, without reading the notes first — it keeps the world as the story opens in the Story Bible and puts what happens later on the private timeline. Shorter notes you organise yourself, by the two rules that follow.",
  "Story Bible pages say how things stand when the story opens.",
  "What the author plans to happen later — events, arcs and volumes still to come — goes only on the planner-only timeline page project/timeline, each event a \"- \" line under \(laterBandHeadings), and never on a page the chapter writer reads.",
].joined(separator: " ")

private let chapterIdeas = [
  "Chapter ideas start from where the story stands: chapter 1 from the opening state — the Story Bible pages on how the world and the people stand when the story opens, and the timeline's \"\(timelineOpeningLabel)\" — and every later chapter from the previous chapter's ending.",
  "Read that material first (get_bible_document for those pages; the latest chapter is already in your context) before you suggest.",
  "The author's plans set the direction and play out across chapters in the author's order and at the author's pace: each idea reaches at most the next planned beat, and never packs several planned beats into one chapter unless the author asks.",
  "The author's structure and pacing outrank genre habits: a craft concern such as a slow opening is one sentence of advice in the reply, never the premise of every option.",
].joined(separator: " ")

// apps/novel-forge-server/src/modules/ai/prompts/scope-playbooks.ts:30
let hubGuidance = [hubGuidanceCore, laterMaterial, chapterIdeas].joined(separator: " ")

// apps/novel-forge-server/src/modules/ai/prompts/scope-playbooks.ts:36
let hubContentOps: [OpType] = [
  .premiseUpdate, .bibleDocumentUpsert, .bibleDocumentRemove, .volumeUpsert, .volumeRemove, .briefUpdate, .briefRemove, .draftUpdate, .draftRemove, .draftRewritePassage,
  .entityUpsert, .entityRemove, .factUpsert, .factRemove, .milestoneUpsert, .milestoneRemove, .promiseCreate, .promiseUpdate, .promiseSetPayoff, .promiseDrop,
]

// apps/novel-forge-server/src/modules/ai/prompts/scope-playbooks.ts:66
let hubAllowedOps: [OpType] = hubContentOps + OpType.actions

// apps/novel-forge-server/src/modules/ai/prompts/scope-playbooks.ts:62
let hubInstructions = [hubGuidance, renderOpVocabulary(hubContentOps, OpVocabularyOptions(quotes: true)), renderActionVocabulary(OpType.actions)].joined(separator: "\n\n")
