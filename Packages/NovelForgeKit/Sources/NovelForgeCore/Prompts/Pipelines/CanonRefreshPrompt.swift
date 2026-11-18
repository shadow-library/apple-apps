// apps/novel-forge-server/src/modules/ai/prompts/chapter-canon-refresh.prompt.ts:27
let canonRefreshVersion = "1.0.0"

// apps/novel-forge-server/src/modules/ai/prompts/chapter-canon-refresh.prompt.ts:9
let canonRefreshOps: [OpType] = [.bibleDocumentUpsert, .entityUpsert]

// apps/novel-forge-server/src/modules/ai/prompts/chapter-canon-refresh.prompt.ts:11
let canonRefreshSystem = "\(canonRefreshSystemHead)\n\n\(editByDeletion)\n\n\(canonRefreshSystemMiddle)\n\n\(renderOpVocabulary(canonRefreshOps))\n\n\(canonRefreshSystemTail)"

private let canonRefreshSystemHead =
  #"""
  A chapter of a serialized web novel has just been finalized: readers will read it, and it is now canon. You keep the Story Bible in step with it. You receive the Story Bible pages (`doc:<section>/<slug>`), the entity records (`entity:<key>`) and the canon facts (`fact:<key>`), each under its own label, then the finalized chapter (`chapter:<n>`) and the updates the author already kept from its review.

  Find each page or record that the chapter has left out of date: a place whose state changed, a faction’s standing or leadership, a rule of the world the chapter demonstrated or bent, a character’s rank, role, allegiance or condition, an item that changed hands or was lost. Propose only what this chapter established — never what an earlier chapter did, never what may happen later, never style notes, gaps unrelated to this chapter or a wish for more detail.

  The kept updates are already recorded on the records and trackers; repeat them on a page only when the page itself now says something the chapter overturned. The declined updates are the author’s answer: never propose them again.

  Evidence: quote the chapter’s own words, verbatim, for what it established; when a page or record states something else, quote its out-of-date words too. Never cite a label that is not in the material.

  Changes: stage the smallest change that brings the page or record up to date. A bible_document.upsert replaces the whole body, so copy the page as it stands and change only the sentences the chapter overturned or add the one it established. An entity.upsert changes only the fields it carries and only updates a record that exists — new records come from the chapter’s review, never from you. Prefer the page or record the fact belongs to; never touch a page about volumes, the timeline or open questions — those hold the author’s plans.

  Secrets: a fact marked SECRET is a truth the reader has not been told. Never write a secret’s truth, or anything that gives it away, into a page or record — even when the chapter hints at it. A page that tells the cover story is the disclosure plan working.
  """#

private let canonRefreshSystemMiddle = "Nothing is applied until the author approves."

private let canonRefreshSystemTail =
  #"""
  Respond with ONLY one valid JSON object — nothing outside the JSON, no markdown fences — of exactly this shape:
  {"updates": [{"finding": "...", "evidence": [{"ref": "chapter:<n>" | "doc:<section>/<slug>" | "entity:<key>", "quote": "..."}], "changeSet": [ops]}]}
  Return {"updates": []} when the Story Bible already reflects the chapter.
  """#

// apps/novel-forge-server/src/modules/audit/chapter-canon-refresh.service.ts:94
func canonRefreshRequest(material: String, chapterProse: String) -> ChapterPromptRequest {
  ChapterPromptRequest(
    [
      PromptMessage(.system, canonRefreshSystem), PromptMessage(.user, material),
      PromptMessage(.user, "\(chapterProse)\n\nList every page or record this chapter left out of date."),
    ], layout: .stablePrefix)
}
