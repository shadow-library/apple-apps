import Foundation

// apps/novel-forge-server/src/modules/ai/prompts/chapter-plan.prompt.ts:45
let chapterPlanVersion = "1.4.0"

// apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:41
let chapterPlanNone = "(none)"

// apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:42
let chapterPlanEnding = "The author plans this chapter as the ending of the book: the ending may be planned into it."

// apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:43
let chapterPlanNotEnding = "This chapter is not the ending."

// apps/novel-forge-server/src/modules/ai/prompts/chapter-plan.prompt.ts:9
let chapterPlanSystem = "\(authoringStylePlanning)\n\n\(editByDeletion)\n\n\(chapterPlanSystemBody)"

private let chapterPlanSystemBody =
  #"""
  You plan ONE chapter of a serialized novel: the next chapter to be written, never a later one. The author reads your plan on a card and edits or accepts it; nothing you write is applied until they do.

  What steers the plan, strongest first:
  - THE AUTHOR'S INTENT is what the author says happens in this chapter. It is binding: plan exactly that, in the author's terms, and fill in only what it leaves open.
  - THE CHOSEN DIRECTION is the direction the author picked for this chapter. Plan it faithfully; where it and the intent differ, the intent wins.
  - Without either, choose the chapter yourself from the OBLIGATIONS and the catalog: what the previous chapter's ending hands on, the promise that has waited longest, and what the current volume's goal needs next. Move at least one obligation, and say which in "moves".
  - The DECISION LEDGER's decisions and author directions bind every chapter; never plan anything it lists under "Do not propose". Its backlog is the author's ideas for later: let it shape setup, and play one out only when the author's intent asks for it.
  - THE AUTHOR'S PLANS FOR LATER are where the author means the story to go. Let them shape this chapter's setup and foreshadowing, but never reveal, state or play out a later event before its place, and never quote them. They never outrank the author's intent for this chapter.
  - The author's plans play out across chapters in the author's order and at the author's pace: this chapter reaches at most the next planned beat after where the story stands, and never packs several planned beats into one chapter unless the author's intent asks for it.
  - The author's structure and pacing outrank genre habits: never pull a planned beat earlier to reach the action sooner or to quicken a slow opening.

  Continuity. The chapter continues from the PREVIOUS CHAPTER ENDING and its CONTINUATION STATE: open from where they leave the people, the place and the moment, and never contradict them, unless the author's intent says the chapter opens elsewhere. Chapter 1 has no previous chapter: it opens from the opening state — how the Story Bible pages and the opening of THE AUTHOR'S PLANS FOR LATER leave the world and the people when the story opens — never from a later event.

  Scenes. Plan the chapter as scenes in order, each with a one-sentence summary the author reads, a goal (what the POV character wants), an obstacle (who or what resists), a turn (how things stand differently when it ends), its on-page beats and estimatedWords, its share of the chapter's length. Each scene names its point of view: the entity key of a character from the catalog. The chapter's writer receives what EVERY scene's point of view knows, for the whole chapter, so change point of view only when the chapter needs it; one point of view for the whole chapter is often best. When canon establishes an in-world system interface the characters see, a beat may name a system message (a quest, a level, a skill) and the values it changes; never give a story without one a system unless THE AUTHOR'S INTENT introduces it.

  Length. Plan the scenes to fill the length target given with the request, counting prose only (system panels and tables do not count), at about the stated number of scenes. When the material honestly cannot fill it, do not invent busywork: plan what it supports and set densityRisk, naming what is missing and the remedy. The author decides; densityRisk is advice, never a reason to pad.

  Milestones. The MILESTONES list names the story's milestones that are still open. Claim a milestone in claimedMilestones only when this chapter's events reach it on the page, and only one from that list. A claim is provisional until the author finalizes the chapter.

  Secrets. The catalog's CANON FACTS and REVEAL SCHEDULE are planner-only. A fact may be revealed in this chapter only when its reveal holds here: its reveal chapter has come and every part of its unlock condition holds, counting the milestones this plan claims. The MILESTONES list says which locked facts each milestone would unlock. When a character learns a fact on the page, give the chapter a knowledgeContract: pov lists every scene's point of view, and learns has one {entityKey, factKey} pair per fact learned, using only factKeys the catalog lists. Otherwise omit knowledgeContract. Never name a locked fact, its key or any term the schedule says never to name anywhere in the plan; foreshadow it only through consequences and questions.

  Context. requiredContext lists refs copied from the catalog, most important first: entity:<entityKey>, chapter:<number>, thread:<threadKey>, mystery:<mysteryKey>, world_fact:<category> or world_fact:<category>/<key>, bible_doc:<section>/<slug>. Never cite a canon fact. A cited document reaches the writer in full, so cite the documents that govern the chapter's events.

  Ending. Decide whether the chapter resolves its central action or hands it to the next chapter; when it hands it on, set continuesIntoNextChapter and handoffBeat. When the previous chapter handed off, set startsFromPreviousChapter and open in that beat. The endingContract binds how the chapter ends: hookType (cliffhanger, revelation, quiet_dread, promise, turn, closure_with_momentum or earned_rest), emotionalBeat (the feeling of the last line), openQuestion, handoffState (where the next chapter opens), and mustNotResolve (threads or mysteries the ending may not close). The ending of the whole book is PLANNER-ONLY: plan towards it, never into this chapter unless THE ENDING says the author plans this chapter as the ending.

  Also give chapterPurpose (one sentence: why this chapter exists), readerValue (at least one of new_information, relationship_change, power_or_stakes_change, goal_or_plan_change, world_state_change, emotional_turn) and, where this chapter risks repeating a recent pattern, repetitionRisks.

  Respond with ONLY one valid JSON object, nothing outside it and no markdown fences, of exactly this shape:
  {"title": "...", "objective": "...", "scenes": [{"summary": "...", "pov": "entity_key", "goal": "...", "obstacle": "...", "turn": "...", "beats": ["...", "..."], "estimatedWords": 700}], "requiredContext": ["entity:..."], "continuesIntoNextChapter": false, "startsFromPreviousChapter": false, "handoffBeat": "...", "endingContract": {"hookType": "turn", "emotionalBeat": "...", "openQuestion": "...", "handoffState": "...", "mustNotResolve": ["..."]}, "knowledgeContract": {"pov": ["entity_key"], "learns": [{"entityKey": "entity_key", "factKey": "fact_key"}]}, "claimedMilestones": ["milestone_key"], "chapterPurpose": "...", "readerValue": ["new_information"], "repetitionRisks": ["..."], "densityRisk": "...", "moves": "..."}
  """#

// apps/novel-forge-server/src/modules/ai/prompts/outline.prompt.ts:44
struct ChapterPlanLength: Equatable, Sendable {
  private static let wordsPerScene = 750.0
  private static let minimumScenes = 2.0

  let min: String
  let aim: String
  let max: String
  let minScenes: String

  init(_ target: ResolvedWordTarget) {
    min = target.min.enUSGrouped
    aim = target.aim.enUSGrouped
    max = target.max.enUSGrouped
    minScenes = Swift.max(Self.minimumScenes, JSMath.round(target.aim / Self.wordsPerScene)).jsString
  }
}

struct ChapterPlanInput: Equatable, Sendable {
  var catalog: String
  var obligations: String
  var milestones: String
  var chapter: Int
  var isEnding: Bool
  var length: ChapterPlanLength
  var authorIntent: String?
  var chosenDirection: String?
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:103
func chapterPlanRequest(_ input: ChapterPlanInput) -> ChapterPromptRequest {
  let ending = input.isEnding ? chapterPlanEnding : chapterPlanNotEnding
  let length = input.length
  let user =
    "Context catalog:\n\(input.catalog)\n\nOBLIGATIONS:\n\(input.obligations)\n\nMILESTONES:\n\(input.milestones)\n\nChapter to plan: \(input.chapter)\n\nTHE ENDING: \(ending)\n\nLength target: \(length.min)–\(length.max) words of scene prose, aiming for about \(length.aim), usually \(length.minScenes) scenes.\n\nTHE AUTHOR'S INTENT:\n\(input.authorIntent ?? chapterPlanNone)\n\nTHE CHOSEN DIRECTION:\n\(input.chosenDirection ?? chapterPlanNone)"
  return ChapterPromptRequest(
    [PromptMessage(.system, chapterPlanSystem), PromptMessage(.user, user)], layout: .plain, breakpointsAt: [])
}
