import Testing

@testable import NovelForgeCore

struct ChatPackAssemblyParityTests {
  private static let fixture = ChatContextFixture.shared

  private struct Budgeted {
    let sections: [ChatPackSection]
    let omitted: [ChatPackOmission]
    let budgetTokens: Int
  }

  private static func budgeted(_ pack: ChatContextFixture.Pack, constants: ChatContextFixture.Constants) throws -> Budgeted {
    let sections = try ChatPack.sections(pack.inputs)
    let stableRoom = max(constants.packFloor, constants.requestBudget - pack.promptTokens - constants.historyAllowance) - constants.packMargin
    let kept = applyBudget(sections.stable, budgetTokens: stableRoom)
    let packRoom = max(constants.packFloor, constants.requestBudget - pack.promptTokens - pack.requestTokens) - constants.packMargin
    let pinned = kept.fitting.map { section -> ChatPackSection in
      var pinned = section
      pinned.required = true
      return pinned
    }
    let budget = max(kept.fitting.reduce(0) { $0 + $1.tokens }, packRoom)
    let final = applyBudget(pinned + sections.volatile, budgetTokens: budget)
    return Budgeted(sections: final.fitting, omitted: (kept.omitted + final.omitted).map(ChatPackOmission.init), budgetTokens: budget)
  }

  @Test func shouldAssembleTheChatPackAsForNovelChatDoes() throws {
    let fixture = try Self.fixture.get()
    for (position, pack) in fixture.packs.enumerated() {
      let result = try Self.budgeted(pack, constants: fixture.constants)
      #expect(result.sections.count == pack.expected.sections.count, "pack \(position) section count \(result.sections.map(\.key)) vs \(pack.expected.sections.map(\.key))")
      for (section, expected) in zip(result.sections, pack.expected.sections) { expectSame(section, expected, "pack \(position) \(expected.key)") }
      #expect(result.omitted == pack.expected.omitted, "pack \(position) omissions")
      #expect(result.budgetTokens == pack.expected.budgetTokens, "pack \(position) budget")
      #expect(result.sections.reduce(0) { $0 + $1.tokens } == pack.expected.usedTokens, "pack \(position) used")
      #expect(joinSections(result.sections).jsLength == pack.expected.renderedLength, "pack \(position) rendered length")
    }
  }

  @Test func shouldCoverBothKindsOfOmissionAndAnUntruncatedPack() throws {
    let packs = try Self.fixture.get().packs
    #expect(packs.contains { !$0.expected.omitted.isEmpty })
    #expect(packs.contains { $0.expected.omitted.isEmpty })
    #expect(packs.contains { $0.expected.sections.contains { $0.truncated } })
    #expect(packs.contains { $0.inputs.story == nil })
    #expect(packs.contains { $0.inputs.latestChapter?.isolated == true })
    #expect(packs.contains { $0.inputs.latestChapter == nil && $0.inputs.latestDraft != nil })
  }

  @Test func shouldListStableSectionsFirstWithTheReferenceRanks() throws {
    for pack in try Self.fixture.get().packs {
      let sections = try ChatPack.sections(pack.inputs)
      #expect(sections.stable.allSatisfy { $0.segment == .stable })
      #expect(sections.volatile.allSatisfy { $0.segment == .volatile })
      let ranks = Dictionary(uniqueKeysWithValues: sections.stable.map { ($0.key, ($0.required, $0.priority)) })
      for (key, rank) in ranks {
        switch key {
        case "story", "notebook", "author_notes": #expect(rank == (true, nil), "\(key)")
        case "volume_plan": #expect(rank == (false, 0))
        case "promises": #expect(rank == (false, 1))
        case "inventory": #expect(rank == (false, 2))
        case "chapter_index": #expect(rank == (false, 3))
        default: Issue.record("unexpected stable section \(key)")
        }
      }
      for section in sections.volatile {
        switch section.key {
        case "handoff": #expect(section.required && section.priority == nil)
        case "prev_ending", "pipeline_status": #expect(!section.required && section.priority == 0)
        case "changed_since": #expect(!section.required && section.priority == 1)
        case "progress": #expect(!section.required && section.priority == 2)
        default: Issue.record("unexpected volatile section \(section.key)")
        }
      }
    }
  }
}
