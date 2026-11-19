import ShadowCore

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
  /// plans for later and the whole catalog. Every section is required, so none is evicted to fit the budget; the catalog is cut to what the others leave.
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:587 (forOutline)
  static func assemble(_ world: OutlineWorld, _ request: OutlineRequest) throws(OutlineLoadError) -> OutlinePack {
    let chapter = request.chapter
    let previous = chapter - 1
    let volumeKey: String?
    switch request.volume {
    case .key(let key): volumeKey = key
    case .nearest: volumeKey = nearestVolumeKey(world.planWorld.plans.map(\.claims), chapter: request.insertAfter ?? chapter)
    }
    let currentVolume = volumeKey.flatMap { key in world.volumes.first { $0.volumeKey.jsEquals(key) } }

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
}
