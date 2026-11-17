import Testing

@testable import NovelForgeCore

struct ChatPackRenderParityTests {
  private static let fixture = ChatContextFixture.shared

  @Test func shouldHeadEverySectionKeyAsTheReferenceDoes() throws {
    for item in try Self.fixture.get().labels {
      expectSame(renderSection(item.key, item.key.isEmpty ? "" : "body of \(item.key)\nsecond line"), item.rendered, "label \(item.key)")
    }
  }

  @Test func shouldJoinAndSplitSegmentsAsTheReferenceDoes() throws {
    for (position, join) in try Self.fixture.get().joins.enumerated() {
      expectSame(joinSections(join.sections), join.joined, "join \(position)")
      let split = splitSegments(join.sections)
      expectSame(split.renderedStable, join.stable, "stable \(position)")
      expectSame(split.renderedVolatile, join.volatile, "volatile \(position)")
    }
  }

  @Test func shouldCutASectionToItsCapAsTheReferenceDoes() throws {
    for (position, fit) in try Self.fixture.get().fits.enumerated() {
      expectSame(ChatPack.fitToCap(fit.section, cap: fit.cap), fit.expected, "fit \(position)")
    }
  }

  @Test func shouldBuildASectionWithTheReferenceTokenCount() throws {
    for (position, fit) in try Self.fixture.get().fits.enumerated() {
      let sectionBody = fit.section.rendered.jsSlice(max(0, fit.section.rendered.jsIndexOf("\n\n") + 2))
      let built = ChatPack.makeSection(fit.section.key, sectionBody, tier: fit.section.tier, sourceRefs: fit.section.sourceRefs)
      expectSame(
        built,
        ChatPackSection(
          key: fit.section.key, tier: fit.section.tier, segment: .volatile, tokens: fit.section.tokens, truncated: false, sourceRefs: fit.section.sourceRefs,
          rendered: fit.section.rendered), "make \(position)")
    }
  }

  @Test func shouldRenderTheStoryAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().story.enumerated() { expectSame(ChatPack.renderStory(item.story), item.expected, "story \(position)") }
  }

  @Test func shouldPointAtTheAuthorsNotesAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().notes.enumerated() {
      #expect(ChatPack.notesParagraphs(item.notes).count == item.paragraphs.count, "paragraph count \(position)")
      for (index, paragraph) in item.paragraphs.enumerated() { expectSame(ChatPack.notesParagraphs(item.notes)[index], paragraph, "paragraph \(position).\(index)") }
      expectSame(ChatPack.renderNotesPointer(item.notes), item.expected, "notes \(position)")
    }
  }

  @Test func shouldRenderTheChecklistAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().progress.enumerated() { expectSame(ChatPack.renderProgress(item.items), item.expected, "progress \(position)") }
  }

  @Test func shouldRenderTheVolumeGoalsAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().volumes.enumerated() { expectSame(ChatPack.renderVolumeGoals(item.volumes), item.expected, "volumes \(position)") }
  }

  @Test func shouldRenderTheNotebookAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().notebook.enumerated() {
      let rendered = item.maxTokens.map { ChatPack.renderNotebook(item.entries, maxTokens: $0) } ?? ChatPack.renderNotebook(item.entries)
      expectSame(rendered, item.expected, "notebook \(position) loneSurrogate \(item.loneSurrogate)")
    }
  }

  @Test func shouldKeepTheNotebookLinesTheBudgetJustFitsAsTheReferenceDoes() throws {
    for sweep in try Self.fixture.get().notebookSweeps {
      for run in sweep.runs { expectSame(ChatPack.renderNotebook(sweep.entries, maxTokens: run.maxTokens), run.expected, "notebook at \(run.maxTokens)") }
    }
  }

  @Test func shouldKeepTheLinesTheBudgetJustFitsAsTheReferenceDoes() throws {
    for sweep in try Self.fixture.get().fitLines {
      for run in sweep.runs { expectSame(ChatPack.fitLines(sweep.lines, maxTokens: run.maxTokens, leftOut: sweep.leftOut), run.expected, "lines at \(run.maxTokens)") }
    }
  }

  @Test func shouldRenderThePromisesAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().promises.enumerated() {
      let milestones = Dictionary(item.milestones.compactMap { pair in MilestoneState(rawValue: pair[1]).map { (JSString(pair[0]), $0) } }) { _, last in last }
      let volumes = Dictionary(item.volumes.compactMap { pair in VolumeState(rawValue: pair[1]).map { (JSString(pair[0]), $0) } }) { _, last in last }
      expectSame(ChatPack.renderPromises(item.promises, nextChapter: item.next, milestoneStates: milestones, volumeStates: volumes), item.expected, "promises \(position)")
    }
  }

  @Test func shouldLabelWhatAPromisePaysOffByAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().payoff.enumerated() {
      expectSame(ChatPack.payoffLabel(window: item.window, milestoneKey: item.milestone, volumeKey: item.volume), item.expected, "payoff \(position)")
    }
  }

  @Test func shouldRenderTheInventoryAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().inventory.enumerated() {
      expectSame(ChatPack.renderInventory(entities: item.entities, pages: item.pages, facts: item.facts, milestones: item.milestones), item.expected, "inventory \(position)")
    }
  }

  @Test func shouldIndexTheChaptersAndHandOffAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().chapters.enumerated() {
      let chapters = item.chapters.map(\.walledOff)
      let drafts = item.drafts.map(\.walledOff)
      #expect(ChatPack.nextChapterNumber(chapters: chapters, drafts: drafts) == item.next, "next \(position)")
      expectSame(ChatPack.renderChapterIndex(chapters: chapters, drafts: drafts, plannedChapters: item.planned), item.index, "index \(position)")
      expectSame(ChatPack.renderHandoff(chapters: chapters, drafts: drafts, briefs: item.briefs), item.handoff, "handoff \(position)")
    }
  }

  @Test func shouldWallOffIsolatedChaptersAsTheReferenceDoesWithoutABridge() throws {
    for (position, item) in try Self.fixture.get().chapters.enumerated() {
      let chapters = item.chapters.filter(\.isolated).map(\.walledOff)
      #expect(chapters.count == item.walledChapters.count, "chapters \(position)")
      for (walled, expected) in zip(chapters, item.walledChapters) {
        #expect(walled.number == expected.number)
        #expect(walled.title == expected.title)
        expectSame(walled.summary, expected.summary, "walled chapter \(position).\(walled.number)")
      }
      let drafts = item.drafts.filter(\.isolated).map(\.walledOff)
      #expect(drafts.count == item.walledDrafts.count, "drafts \(position)")
      for (walled, expected) in zip(drafts, item.walledDrafts) {
        #expect(walled.chapter == expected.chapter)
        #expect(walled.title == expected.title)
        expectSame(walled.summary, expected.summary, "walled draft \(position).\(walled.chapter)")
      }
    }
  }

  @Test func shouldNameWhatWaitsOnTheAuthorAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().awaiting.enumerated() { expectSame(ChatPack.renderAwaitingAuthor(item.awaiting), item.expected, "awaiting \(position)") }
  }

  @Test func shouldReadHowTheLatestChapterEndsAsTheReferenceDoesUnderThePlannerPolicy() throws {
    for (position, item) in try Self.fixture.get().endings.enumerated() {
      let ending = try ChatPack.previousEnding(chapter: item.chapter, row: item.row, draft: item.draft, cap: item.cap)
      expectSame(ending, item.expected, "ending \(position)")
    }
  }

  @Test func shouldRenderThePipelineAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().pipeline.enumerated() { expectSame(ChatPack.renderPipelineStatus(item.pipeline), item.expected, "pipeline \(position)") }
  }

  @Test func shouldListWhatChangedSinceTheSessionStartedAsTheReferenceDoes() throws {
    for (position, item) in try Self.fixture.get().changes.enumerated() {
      let lines = ChatPack.changedSinceLines(item.changes)
      #expect(lines.count == item.expected.count, "changes \(position)")
      for (line, expected) in zip(lines, item.expected) { expectSame(line, expected, "change \(position)") }
    }
  }

  @Test func shouldShareTheReferenceConstants() throws {
    let constants = try Self.fixture.get().constants
    #expect(ChatPack.requestBudget == constants.requestBudget)
    #expect(ChatPack.packFloor == constants.packFloor)
    #expect(ChatPack.packMargin == constants.packMargin)
    #expect(ChatPack.messageAllowance == constants.messageAllowance)
    #expect(ChatPack.previousEndingTail == constants.previousEndingTail)
    #expect(ChatPack.Cap.story == constants.caps.story)
    #expect(ChatPack.Cap.notebook == constants.caps.notebook)
    #expect(ChatPack.Cap.authorNotes == constants.caps.authorNotes)
    #expect(ChatPack.Cap.volumes == constants.caps.volumes)
    #expect(ChatPack.Cap.promises == constants.caps.promises)
    #expect(ChatPack.Cap.inventory == constants.caps.inventory)
    #expect(ChatPack.Cap.chapterIndex == constants.caps.chapterIndex)
    #expect(ChatPack.Cap.handoff == constants.caps.handoff)
    #expect(ChatPack.Cap.latestEnding == constants.caps.latestEnding)
    #expect(ChatPack.Cap.latestState == constants.caps.latestState)
    #expect(ChatPack.Cap.changedSince == constants.caps.changedSince)
    #expect(ChatPack.Cap.progress == constants.caps.progress)
    expectSame(ChatPack.endingPlannerOnlyLabel, constants.labels.ending, "ending label")
    expectSame(ChatPack.endingQuestionPlannerOnlyLabel, constants.labels.endingQuestion, "ending question label")
    expectSame(ChatPack.laterVolumeGoalLabel, constants.labels.laterVolume, "later volume label")
  }
}
