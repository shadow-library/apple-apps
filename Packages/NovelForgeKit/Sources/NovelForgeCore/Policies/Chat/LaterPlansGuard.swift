import ShadowText

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:8
private let notesOrganiseLeads = ["here are my notes for the story.", "organise my notes", "organize my notes"]

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:9
let organiseNotesOp = "action.organise_notes"

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:12
private let plansTitle = ProseRegex.literal(
  #"^(?:(?:the|my|our|story|author'?s?)\s+)?(?:plans?|planned|upcoming|roadmap|(?:future|later)\s+(?:plans|events|arcs?|beats)|what happens (?:next|later))\b"#, "i")

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:49 without the `m` flag the regex engine lacks: `^` and `$` become line-terminator lookarounds, `.` its class.
private let firstHeading = ProseRegex.literal(#"(?<![^\n\r  ])#\s+([^\n\r  ]+)(?![^\n\r  ])"#)

private let separatorRuns = ProseRegex.literal(#"[-_]+"#, "g")

// packages/sdk/src/organise.ts:6
private let laterBandLabels = ["Early on", "Later", "The ending", "Not yet placed"]

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:13
let laterBandHeadings = laterBandLabels.map { "\"## \($0)\"" }.joined(separator: ", ")

private let timelineRef = "\(BibleDocAddress.organisedTimeline.section)/\(BibleDocAddress.organisedTimeline.slug)"

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:18
let organiseRoutedNote =
  "Organising your notes runs as its own step: it keeps the world as the story opens in your Story Bible and puts what happens later in your private timeline, which only planning reads."

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:20
let organiseCardNote = "Accept the card to start it."

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:21
let plansWithheldNote =
  "Forge kept a page of plans for later off the pages the chapter writer reads, so later events cannot leak into chapter prose. Ask again to keep them in your private timeline, which only planning reads."

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:27
enum OrganiseRouting: Sendable {
  case none
  case card
  case start
}

protocol ChatTurnOutput: Sendable {
  var reply: String { get }
  var changeSet: [OrderedJSONObject]? { get }
  func replacing(reply: String, changeSet: [OrderedJSONObject]?) -> Self
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:34
func isNotesOrganiseRequest(_ message: String) -> Bool {
  let opening = message.jsTrimStart().jsToLowerCase()
  return notesOrganiseLeads.contains { opening.jsStartsWith($0) }
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:39
func organiseRouting(organiseRequest: Bool, mode: RefinementChatMode, justDiscussing: Bool) -> OrganiseRouting {
  guard organiseRequest else { return .none }
  return mode == .auto && !justDiscussing ? .start : .card
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:44
private func pageTitle(_ fields: OrderedJSONObject) -> String {
  if let title = fields["frontmatter"]?.objectValue?["title"]?.stringValue, !title.jsTrim().isEmpty { return title.jsTrim() }
  let body = fields["body"]?.stringValue ?? ""
  return firstHeading.exec(body)?.groups.first.flatMap { $0 }?.jsTrim() ?? ""
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:53
func writesPlansOnWriterPage(_ fields: OrderedJSONObject) -> Bool {
  guard fields["op"]?.stringValue?.jsEquals("bible_document.upsert") == true, let section = fields["section"]?.stringValue, let slug = fields["slug"]?.stringValue else {
    return false
  }
  if isWriterExcludedBibleDoc(BibleDocAddress(section: section, slug: slug)) { return false }
  return [pageTitle(fields), slug.jsReplace(separatorRuns, " ")].contains { plansTitle.test($0) }
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:60
private func onlyOrganises(_ changeSet: [OrderedJSONObject]) -> Bool {
  changeSet.count == 1 && changeSet[0]["op"]?.stringValue?.jsEquals(organiseNotesOp) == true
}

private func describe(_ value: OrderedJSON?) -> String {
  value?.stringValue ?? ""
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:64
func laterPlanIssues(_ changeSet: [OrderedJSONObject]?, organiseRequest: Bool) -> [String] {
  let ops = changeSet ?? []
  if organiseRequest {
    if onlyOrganises(ops) { return [] }
    return [
      "The author asked you to organise their notes. That runs as its own step, which keeps the world as the story opens in the Story Bible and puts what happens later on the private timeline only planning reads, so answer with exactly one op, {\"op\":\"\(organiseNotesOp)\"}, and write no Story Bible page or record from the notes yourself."
    ]
  }
  return ops.enumerated().compactMap { index, fields in
    guard writesPlansOnWriterPage(fields) else { return nil }
    return
      "changeSet[\(index)]: \(describe(fields["section"]))/\(describe(fields["slug"])) holds plans for later on a page the chapter writer reads, so later events would leak into chapter prose. Keep that page to how things stand when the story opens, and put what happens later on the private timeline instead: bible_document.upsert \(timelineRef) (fetch it first when it exists), each event a \"- \" line under \(laterBandHeadings)."
  }
}

// apps/novel-forge-server/src/modules/refinement/later-plans-guard.ts:82
func withLaterPlansRouted<Output: ChatTurnOutput>(_ output: Output, organise: OrganiseRouting) -> Output {
  let changeSet = output.changeSet ?? []
  if organise != .none {
    if onlyOrganises(changeSet) { return output }
    let note = organise == .card ? "\(organiseRoutedNote) \(organiseCardNote)" : organiseRoutedNote
    return output.replacing(reply: "\(output.reply)\n\n\(note)", changeSet: [OrderedJSONObject([(key: "op", value: .string(organiseNotesOp))])])
  }
  let kept = changeSet.filter { !writesPlansOnWriterPage($0) }
  if kept.count == changeSet.count { return output }
  return output.replacing(reply: "\(output.reply)\n\n\(plansWithheldNote)", changeSet: kept.isEmpty ? nil : kept)
}
