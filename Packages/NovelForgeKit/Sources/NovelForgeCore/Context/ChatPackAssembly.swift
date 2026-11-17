struct ChatPackSections: Equatable, Sendable {
  var stable: [ChatPackSection]
  var volatile: [ChatPackSection]
}

extension ChatPack {
  /// World facts, character states, isolation bridges, continuation state, jobs, finalize reviews, continuity proposals and plugin sections are left out: the vault records
  /// none of them. Budgeting is the caller's.
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:763
  static func sections(_ inputs: ChatPackInputs) throws(DisclosureError) -> ChatPackSections {
    let chapters = inputs.chapters.map(\.walledOff)
    let drafts = inputs.drafts.map(\.walledOff)
    let next = nextChapterNumber(chapters: chapters, drafts: drafts)
    var stable: [ChatPackSection] = []
    if let story = inputs.story {
      stable.append(capped("story", renderStory(story), tier: .canonical, cap: Cap.story, segment: .stable, required: true))
    }
    stable.append(capped("notebook", renderNotebook(inputs.ledger), tier: .approvedIntent, cap: Cap.notebook, segment: .stable, required: true))
    if let pointer = renderNotesPointer(inputs.authorNotes ?? "") {
      stable.append(capped("author_notes", pointer, tier: .approvedIntent, cap: Cap.authorNotes, segment: .stable, required: true))
    }
    if !inputs.volumes.isEmpty {
      stable.append(capped("volume_plan", renderVolumeGoals(inputs.volumes), tier: .approvedIntent, cap: Cap.volumes, segment: .stable, priority: 0))
    }
    let promises = renderPromises(
      inputs.promises, nextChapter: next, milestoneStates: inputs.milestones.jsLastByKey(\.milestoneKey).mapValues(\.state),
      volumeStates: inputs.volumes.jsLastByKey(\.volumeKey).mapValues(\.state))
    if !promises.isEmpty { stable.append(capped("promises", promises, tier: .canonical, cap: Cap.promises, segment: .stable, priority: 1)) }
    let inventory = renderInventory(entities: inputs.entities, pages: inputs.pages, facts: inputs.facts, milestones: inputs.milestones)
    if !inventory.isEmpty { stable.append(capped("inventory", inventory, tier: .canonical, cap: Cap.inventory, segment: .stable, priority: 2)) }
    if let index = renderChapterIndex(chapters: chapters, drafts: drafts, plannedChapters: inputs.plannedChapters) {
      stable.append(capped("chapter_index", index, tier: .canonical, cap: Cap.chapterIndex, segment: .stable, priority: 3))
    }

    var volatile = [
      capped("handoff", renderHandoff(chapters: chapters, drafts: drafts, briefs: inputs.briefs), tier: .working, cap: Cap.handoff, segment: .volatile, required: true)
    ]
    if var ending = try previousEnding(chapter: next - 1, row: inputs.latestChapter, draft: inputs.latestDraft) {
      ending.priority = 0
      volatile.append(ending)
    }
    volatile.append(capped("pipeline_status", renderPipelineStatus(inputs.pipeline), tier: .working, cap: Cap.changedSince, segment: .volatile, priority: 0))
    let changed = changedSinceLines(inputs.changes)
    if !changed.isEmpty {
      volatile.append(capped("changed_since", changed.joined(separator: "\n"), tier: .working, cap: Cap.changedSince, segment: .volatile, priority: 1))
    }
    if let progress = inputs.progress.flatMap(renderProgress) {
      volatile.append(capped("progress", progress, tier: .working, cap: Cap.progress, segment: .volatile, priority: 2))
    }
    return ChatPackSections(stable: stable, volatile: volatile)
  }
}
