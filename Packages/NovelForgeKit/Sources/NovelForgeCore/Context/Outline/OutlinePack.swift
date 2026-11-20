import ShadowCore
import ShadowText

private let recentChapterCount = 3

// apps/novel-forge-server/src/modules/ai/context/sections.ts:29 (AssembledPack) as an outline call reads it
struct OutlinePack: Equatable, Sendable {
  let chapter: Int
  let volumeKey: String?
  let budgetTokens: Int
  let usedTokens: Int
  let sections: [ChatPackSection]
  let omitted: [ChatPackOmission]
  let renderedStable: String
  let renderedVolatile: String
  let rendered: String

  // context-assembler.service.ts:129
  static let budget = 32_000
  // context-assembler.service.ts:132
  static let timelineCap = 2_500
}

extension OutlinePack {
  /// What the planner reads before it plans `request.chapter`: the volume goal, the last summaries, how the previous chapter ended, the decision ledger, the author's
  /// plans for later, the whole catalog and, when `recalled` is given, the prose and lore retrieval found for the volume goal. Every section but the retrieved
  /// two is required, so only those are evicted to fit the budget; the catalog is cut to what the other required sections leave.
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:587 (forOutline)
  static func assemble(_ world: OutlineWorld, _ request: OutlineRequest, recalled: RetrievalResults? = nil) throws(OutlineLoadError) -> OutlinePack {
    let chapter = request.chapter
    let previous = chapter - 1
    let (volumeKey, currentVolume) = volume(world, request)

    var sections: [ChatPackSection] = []
    func require(_ section: ChatPackSection) {
      var required = section
      required.required = true
      sections.append(required)
    }

    if let currentVolume, let objective = ChatPack.present(currentVolume.objective) {
      require(ChatPack.makeSection("volume_objective", objective, tier: .approvedIntent, sourceRefs: ["volume:\(currentVolume.volumeKey)"]))
    }

    let recent = world.chapters.filter { $0.number < chapter }.jsStableSorted { $0.number > $1.number }.prefix(recentChapterCount).reversed()
    let recentLines = recent.enumerated().map { index, row in
      let summary: String = row.isolated ? ChatPack.noBridgeSummary : row.summary ?? ""
      return "\(index + 1). Ch \(row.number): \(summary)"
    }
    if !recentLines.isEmpty { require(ChatPack.makeSection("memory", recentLines.joined(separator: "\n"), tier: .canonical)) }

    var disclosure = WriterDisclosurePolicy.planner
    let ending: WriterPreviousEnding
    do throws(DisclosureError) {
      ending = try WriterRender.previousEnding(
        chapter: previous, row: world.previous, draft: world.previousDraft, rawIsolated: request.readsIsolatedRaw, disclosure: &disclosure)
    } catch {
      throw .disclosure(error)
    }
    for found in [ending.ending, ending.state] { if let found { require(found) } }
    require(ChatPack.ledgerSection(world.ledger, segment: .volatile))
    if let timeline = timelineText(world.documents) {
      require(ChatPack.fitToCap(ChatPack.makeSection("later_plans", "\(laterPlansLead)\n\n\(timeline)", tier: .approvedIntent), cap: timelineCap))
    }

    let maxTokens = WriterRender.sizedSectionCeiling("catalog", available: request.budgetTokens - sections.reduce(0) { $0 + $1.tokens })
    let catalog = world.catalog(OutlineCatalogOptions(maxTokens: maxTokens, span: request.planSpan, insertAfter: request.insertAfter))
    if !catalog.isEmpty { require(ChatPack.makeSection("catalog", catalog, tier: .canonical)) }

    if let recalled {
      if !recalled.prose.isEmpty { sections.append(ChatPack.makeSection("prose_retrieved", recalledLines(recalled.prose), tier: .canonical)) }
      if !recalled.lore.isEmpty { sections.append(ChatPack.makeSection("lore_retrieved", recalledLines(recalled.lore), tier: .canonical)) }
    }

    let budgeted = applyBudget(sections, budgetTokens: request.budgetTokens)
    if request.readsIsolatedRaw {
      let screens = sectionScreens(budgeted.fitting.map { ContextSection(key: $0.key, rendered: $0.rendered, sourceRefs: $0.sourceRefs) })
      if let hit = screenTexts(screens, lexicon: HardLineLexicon.standard.adding(minorNames: world.minorNames)) { throw .hardLine(hardLineError(hit)) }
    }
    let split = splitSegments(budgeted.fitting)
    return OutlinePack(
      chapter: chapter, volumeKey: volumeKey, budgetTokens: request.budgetTokens, usedTokens: budgeted.fitting.reduce(0) { $0 + $1.tokens }, sections: budgeted.fitting,
      omitted: budgeted.omitted.map(ChatPackOmission.init), renderedStable: split.renderedStable, renderedVolatile: split.renderedVolatile,
      rendered: joinSections(budgeted.fitting.filter { $0.segment == .stable } + budgeted.fitting.filter { $0.segment != .stable }))
  }

  /// context-assembler.service.ts:660: the first line of the current volume's objective, or nil when that line is empty and nothing is searched for.
  static func retrievalQuery(_ world: OutlineWorld, _ request: OutlineRequest) -> String? {
    guard let objective = volume(world, request).current?.objective, let line = objective.jsSplit("\n").first, !line.isEmpty else { return nil }
    return line
  }

  private static func volume(_ world: OutlineWorld, _ request: OutlineRequest) -> (key: String?, current: OutlineVolume?) {
    let key: String?
    switch request.volume {
    case .key(let chosen): key = chosen
    case .nearest: key = nearestVolumeKey(world.planWorld.plans.map(\.claims), chapter: request.insertAfter ?? request.chapter)
    }
    return (key, key.flatMap { key in world.volumes.first { $0.volumeKey.jsEquals(key) } })
  }

  // context-assembler.service.ts:667,671
  private static func recalledLines(_ hits: [RetrievalHit]) -> String {
    hits.enumerated().map { index, hit in "\(index + 1). [\(hit.outlineLabel)] \(hit.text)" }.joined(separator: "\n\n")
  }
}
