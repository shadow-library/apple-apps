import ShadowCore
import ShadowText

struct WriterRecentSummary: Equatable, Sendable {
  var chapter: Int
  var summary: String
  var draft: Bool
  var stale: Bool
}

struct WriterOpenCanon: Equatable, Sendable {
  var section: ChatPackSection
  var omitted: [ChatPackOmission]
}

private let recentSummaryMax = 400
// context-assembler.service.ts:149: the "earlier volumes not shown" line the summary may add after it is sized
private let completedVolumesNoteMargin = 20

extension WriterPackRender {
  // pack-render.ts:13
  static let recentSummaryCount = 3
  // context-assembler.service.ts:128
  static let fullCastMax = 5
  // context-assembler.service.ts:147: room for the card's own heading, name, alias and status lines inside the POV card's limit
  static let povCardBodyMax = WriterRender.Cap.povCard - 200

  // pack-render.ts:230
  static func characterState(name: String, _ state: WriterPackCharacterState) -> String? {
    var lines: [String] = []
    if let location = ChatPack.present(state.location) { lines.append("Location: \(location)") }
    if let conditions = state.conditions, !conditions.isEmpty { lines.append("Conditions: \(conditions.joined(separator: ", "))") }
    if let goal = ChatPack.present(state.immediateGoal) { lines.append("Goal: \(goal)") }
    if let note = ChatPack.present(state.statusNote) { lines.append("Status: \(note)") }
    if lines.isEmpty { return nil }
    return (["**\(name)** (as of ch \(state.lastUpdatedChapter))"] + lines).joined(separator: "\n")
  }

  /// The highest-chapter observation of each pair and kind, the later one winning a tie.
  // pack-render.ts:386
  static func latestRelationships(_ rows: [WriterPackRelationship]) -> [WriterPackRelationship] {
    var order: [JSString] = []
    var latest: [JSString: WriterPackRelationship] = [:]
    for row in rows {
      let key = JSString("\(row.entity)::\(row.target)::\(row.kind)")
      guard let current = latest[key] else {
        order.append(key)
        latest[key] = row
        continue
      }
      let (chapter, held) = (row.chapter ?? -1, current.chapter ?? -1)
      if chapter > held || (chapter == held && row.order > current.order) { latest[key] = row }
    }
    return order.compactMap { latest[$0] }
  }

  /// A batch drafts chapter N before N-1 is finalized, so a chapter without a final row speaks through its draft's summary.
  // pack-render.ts:260
  static func recentSummaries(finals: [(chapter: Int, summary: String?)], drafts: [(chapter: Int, summary: String?, stale: Bool)]) -> [WriterRecentSummary] {
    var order: [Int] = []
    var byChapter: [Int: WriterRecentSummary] = [:]
    func put(_ entry: WriterRecentSummary) {
      if byChapter[entry.chapter] == nil { order.append(entry.chapter) }
      byChapter[entry.chapter] = entry
    }
    for draft in drafts where !(draft.summary?.jsTrim() ?? "").isEmpty {
      put(WriterRecentSummary(chapter: draft.chapter, summary: draft.summary ?? "", draft: true, stale: draft.stale))
    }
    for final in finals {
      let summary = (final.summary?.jsTrim() ?? "").isEmpty ? (byChapter[final.chapter]?.summary ?? "") : final.summary ?? ""
      put(WriterRecentSummary(chapter: final.chapter, summary: summary, draft: false, stale: false))
    }
    return Array(order.compactMap { byChapter[$0] }.jsStableSorted { $0.chapter < $1.chapter }.suffix(recentSummaryCount))
  }

  // pack-render.ts:272
  static func recentSummaryLine(_ entry: WriterRecentSummary, index: Int) -> String {
    let labels = (entry.draft ? "[DRAFT — not yet canon] " : "") + (entry.stale ? "\(ChatPack.staleLabel) " : "")
    return "\(index + 1). \(labels)Ch \(entry.chapter): \(entry.summary)"
  }
}

extension WriterPackWorld {
  /// The POV card pays only its own, far larger limit: the drafter writes from inside this head, so a truncated card is a truncated narrator.
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:528
  func povSection(_ pov: String, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> ChatPackSection? {
    guard let entity = entity(pov) else { return nil }
    let label = try disclosure.scrub(WriterPackRender.entityLabel(entity, pov: true), .heading)
    let card = WriterPackRender.entityCard(entity, maxTokens: WriterPackRender.povCardBodyMax)
    return WriterPackRender.refSection(
      "entity:\(pov)", label: label, content: try disclosure.scrub(card.text, .entity), tier: WriterPackRender.entityCardTier(entity.status), truncated: card.truncated)
  }

  /// Per-chapter dynamic state, scoped to the cast the plan names plus its POV, so a large cast pays only for the characters on stage.
  // context-assembler.service.ts:538
  func dynamicCastSections(_ entityCards: [ChatPackSection], pov: String?, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> [ChatPackSection] {
    var castKeys = Set(entityCards.map { JSString($0.key.jsSlice("ref:entity:".jsLength)) })
    if let pov, !pov.isEmpty { castKeys.insert(JSString(pov)) }
    if castKeys.isEmpty { return [] }
    let cast = entities.filter { castKeys.contains(JSString($0.entity)) }
    let names = cast.jsLastByKey(\.entity)
    var sections: [ChatPackSection] = []

    let inCast = characterStates.filter { castKeys.contains(JSString($0.entity)) }.jsStableSorted { JSText.localePrecedes($0.entity, $1.entity) }
    let blocks = inCast.compactMap { WriterPackRender.characterState(name: names[JSString($0.entity)]?.name ?? $0.entity, $0) }
    if !blocks.isEmpty {
      sections.append(
        ChatPack.makeSection(
          "character_state", try disclosure.scrub(blocks.joined(separator: "\n\n"), .summary), tier: .working, sourceRefs: inCast.map { "entity:\($0.entity)" }))
    }

    if cast.isEmpty { return sections }
    let rows = relationships.filter { names[JSString($0.entity)] != nil }
    let lines = WriterPackRender.latestRelationships(rows).map { row in
      let note = ChatPack.present(row.note).map { ": \($0)" } ?? ""
      let at = row.chapter.map { " [ch \($0)]" } ?? ""
      return "\(names[JSString(row.entity)]?.name ?? row.entity) → \(row.target) (\(row.kind))\(note)\(at)"
    }.jsStableSorted(by: JSText.localePrecedes)
    if !lines.isEmpty {
      let refs = rows.map(\.entity).jsUnique().map { "entity:\($0)" }
      sections.append(ChatPack.makeSection("relationships", try disclosure.scrub(lines.joined(separator: "\n"), .summary), tier: .working, sourceRefs: refs))
    }
    return sections
  }

  /// Every rule the whole book obeys, those about the chapter's cast surviving a cut first, rendered by key so the stable section holds whatever the chapter.
  // context-assembler.service.ts:432
  func openCanon(chapterCast: Set<JSString>, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> WriterOpenCanon? {
    let locked = Set(disclosure.lockedFacts.map { JSString($0.factKey) })
    let open = facts.filter { isOpenCanon($0.revealChapter) && !$0.hasUnlock && !locked.contains(JSString($0.factKey)) }
    if open.isEmpty { return nil }
    let fitted = WriterRender.fitFacts(
      WriterRender.subjectsFirst(open, castKeys: chapterCast), maxTokens: WriterRender.sizedSectionCeiling("open_canon", available: WriterRender.Cap.openCanon)
    ) { renderKnownFacts([$0]) }
    let kept = fitted.kept.jsStableSorted { JSText.localePrecedes($0.factKey, $1.factKey) }
    let content = try disclosure.scrub(renderKnownFacts(kept), .knowledge)
    let section = ChatPack.makeSection("open_canon", content, tier: .canonical, sourceRefs: kept.map { "fact:\($0.factKey)" }).asStable
    return WriterOpenCanon(section: section, omitted: fitted.omitted)
  }

  /// The volumes behind the chapter's own: every earlier one when its volume is known, otherwise every one whose goal is met. A chapter belongs to the volume
  /// its plan names, or else the one it was imported into; an isolated chapter has no approved bridge here, so it adds nothing.
  // context-assembler.service.ts:461
  func completedVolumes(chapter: Int, current: WriterPackVolume?, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> ChatPackSection? {
    let completed = volumesByOrdinal.filter { volume in
      if let current, volume.volume.jsEquals(current.volume) { return false }
      let behind = current.map { volume.ordinal < $0.ordinal } ?? volume.goalMet
      return behind && disclosure.canResolve("volume:\(volume.volume)")
    }
    if completed.isEmpty { return nil }
    let keys = Set(completed.map { JSString($0.volume) })
    var plannedIn: [Int: String] = [:]
    for plan in plans where plan.chapter < chapter {
      if let volume = plan.volume { plannedIn[plan.chapter] = volume }
    }
    var byVolume: [JSString: [WriterVolumeChapter]] = [:]
    for final in finals.filter({ $0.chapter < chapter }).jsStableSorted(by: { $0.chapter < $1.chapter }) {
      guard let volume = plannedIn[final.chapter] ?? final.volume, !volume.isEmpty, keys.contains(JSString(volume)) else { continue }
      guard !final.isolated, let summary = final.summary, !summary.jsTrim().isEmpty else { continue }
      byVolume[JSString(volume), default: []].append(WriterVolumeChapter(number: final.chapter, summary: summary))
    }
    var blocks: [WriterCompletedVolume] = []
    for volume in completed {
      let title = try disclosure.scrub(volume.title ?? volume.volume, .heading)
      let goal = try ChatPack.present(volume.objective).map { objective throws(DisclosureError) in try disclosure.scrub(objective, .plan) }
      blocks.append(WriterCompletedVolume(ordinal: volume.ordinal, title: title, goal: goal, chapters: byVolume[JSString(volume.volume)] ?? []))
    }
    let room = WriterRender.sizedSectionCeiling("completed_volumes", available: WriterRender.Cap.completedVolumes) - completedVolumesNoteMargin
    guard let rendered = try WriterRender.renderCompletedVolumes(blocks, maxTokens: room, scrub: { summary throws(DisclosureError) in try disclosure.scrub(summary, .summary) })
    else { return nil }
    let refs = completed.filter { byVolume[JSString($0.volume)] != nil }.map { "volume:\($0.volume)" }
    return ChatPack.makeSection("completed_volumes", rendered, tier: .canonical, sourceRefs: refs).asStable
  }

  /// The recent summaries as a standard writer reads them: an isolated chapter's summary is walled off unless the route is permissive.
  // context-assembler.service.ts:385-396
  func recentSummaries(chapter: Int, rawIsolated: Bool) -> [WriterRecentSummary] {
    let recentFinals = finals.filter { $0.chapter < chapter }.jsStableSorted { $0.chapter > $1.chapter }.prefix(WriterPackRender.recentSummaryCount)
    let window = (chapter - WriterPackRender.recentSummaryCount)...(chapter - 1)
    let recentDrafts = drafts.filter { window.contains($0.chapter) }
    func readable(_ summary: String?, isolated: Bool) -> String? {
      rawIsolated ? summary : WriterPackRender.walledOff(title: nil, summary: summary, isolated: isolated).summary
    }
    return WriterPackRender.recentSummaries(
      finals: recentFinals.map { (chapter: $0.chapter, summary: readable($0.summary, isolated: $0.isolated)) },
      drafts: recentDrafts.map { (chapter: $0.chapter, summary: readable($0.summary, isolated: $0.isolated), stale: $0.staleReason != nil) })
  }

  func memorySection(chapter: Int, rawIsolated: Bool, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> ChatPackSection? {
    let recent = recentSummaries(chapter: chapter, rawIsolated: rawIsolated)
    if recent.isEmpty { return nil }
    var lines: [String] = []
    for (index, entry) in recent.enumerated() {
      var shown = entry
      shown.summary = truncateAtParagraph(try disclosure.scrub(entry.summary, .summary), maxTokens: recentSummaryMax).text
      lines.append(WriterPackRender.recentSummaryLine(shown, index: index))
    }
    return ChatPack.makeSection("memory", lines.joined(separator: "\n"), tier: recent.contains(where: \.draft) ? .working : .canonical)
  }
}
