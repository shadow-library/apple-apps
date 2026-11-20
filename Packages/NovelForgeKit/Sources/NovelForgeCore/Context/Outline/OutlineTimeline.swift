import ShadowCore
import ShadowText

// packages/sdk/src/organise.ts:6
private let bandLabels = (opening: "The opening", early: "Early on", later: "Later", ending: "The ending", unplaced: "Not yet placed")

private let bands = [
  "\"\(bandLabels.opening)\" is how the story opens;",
  "everything under \"\(bandLabels.early)\", \"\(bandLabels.later)\" and \"\(bandLabels.ending)\" happens where it is placed and never in the opening;",
  "\"\(bandLabels.unplaced)\" is not the opening either — place it only where it plainly fits",
].joined(separator: " ")

// apps/novel-forge-server/src/modules/ai/context/organised-timeline.ts:19 ('kept': the vault has no organise-run decision to say the page is current or stale)
private let keptRule = [
  "The author's own timeline, kept by them in the Story Bible.",
  "It binds where things happen: \(bands).",
  "The ending is the author's own, and every step keeps to it.",
].joined(separator: " ")

extension OutlinePack {
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:134
  static let laterPlansLead = [
    "Planner-only: the chapter writer and readers never see this, and you never quote or cite it. It is where the author means the story to go.",
    "Let what is placed later shape this chapter: set it up, seed it, foreshadow it and put people and things where it will need them.",
    "Never state, reveal or play out a later event before its place.",
  ].joined(separator: " ")

  /// The timeline as a planner reads it, rule first; nil when the page is missing or empty.
  // apps/novel-forge-server/src/modules/ai/context/organised-timeline.ts:56 (organisedTimelineText)
  static func timelineText(_ documents: [OutlineDocument]) -> String? {
    guard let body = documents.first(where: { $0.address == .organisedTimeline })?.body?.jsTrim(), !body.isEmpty else { return nil }
    return "\(keptRule)\n\n\(body)"
  }
}
