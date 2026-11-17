import Foundation
import Testing

@testable import NovelForgeCore

struct ChatContextAssemblerParityTests {
  private static let fixture = ChatAssemblyFixture.shared

  private static func packs() async throws -> [ChatContextPack] {
    var packs = [ChatContextPack]()
    for scenario in try fixture.get().scenarios {
      let spec = scenario.spec
      let inputs = try await ChatAssemblyWorld.inputs(try await ChatAssemblyWorld.build(spec))
      #expect(inputs.unresolved.isEmpty, "\(spec.name): unresolved \(inputs.unresolved)")
      packs.append(ChatContextAssembler.assemble(inputs, promptTokens: spec.promptTokens, requestTokens: spec.requestTokens))
    }
    return packs
  }

  @Test func shouldAssembleTheVaultAsForNovelChatDoes() async throws {
    let scenarios = try Self.fixture.get().scenarios
    for (scenario, pack) in zip(scenarios, try await Self.packs()) {
      let name = scenario.spec.name
      let expected = scenario.expected
      #expect(pack.sections.map(\.key) == expected.sections.map(\.key), "\(name): sections")
      for (section, wanted) in zip(pack.sections, expected.sections) { expectSame(section, wanted, "\(name) \(wanted.key)") }
      #expect(pack.omitted == expected.omitted, "\(name): omissions")
      #expect(pack.partial.isEmpty, "\(name): partial")
      #expect(pack.budgetTokens == expected.budgetTokens, "\(name): budget")
      #expect(pack.usedTokens == expected.usedTokens, "\(name): used")
      expectSame(pack.renderedStable, expected.renderedStable, "\(name): stable")
      expectSame(pack.renderedVolatile, expected.renderedVolatile, "\(name): volatile")
    }
  }

  @Test func shouldSendTheContextUpdatesTheReferenceSends() async throws {
    let fixture = try Self.fixture.get()
    let packs = try await Self.packs()
    for update in fixture.updates {
      let pack = packs[update.scenario]
      let holding: ChatHeldSections? =
        switch update.holding {
        case "same": ChatContextExchange.contextUpdate(pack, holding: nil).sections
        case "previous": ChatContextExchange.contextUpdate(packs[update.scenario - 1], holding: nil).sections
        default: nil
        }
      let result = ChatContextExchange.contextUpdate(pack, holding: holding)
      expectSame(result.text, update.text, "update \(update.scenario) \(update.holding)")
      #expect(result.sections.entries.map { [$0.key, $0.section.digest, $0.section.heading] } == update.sections, "update \(update.scenario) \(update.holding) sections")
    }
  }

  @Test func shouldCoverOmissionsChangesAndEveryUpdateKind() throws {
    let fixture = try Self.fixture.get()
    let expected = fixture.scenarios.map(\.expected)
    #expect(fixture.historyAllowance == ChatContextAssembler.historyAllowance)
    #expect(expected.contains { !$0.omitted.isEmpty })
    #expect(expected.contains { $0.sections.contains { $0.key == "changed_since" } })
    #expect(expected.contains { $0.sections.contains { $0.key == "prev_ending" && $0.rendered.contains(ChatPack.noApprovedBridge) } })
    #expect(fixture.scenarios.contains { $0.spec.novel == nil })
    #expect(fixture.scenarios.contains { $0.spec.pendingProposals > 0 })
    #expect(fixture.scenarios.contains { $0.spec.ledger.contains { $0.anchorChanged } })
    #expect(Set(fixture.updates.map(\.text)).count > 3)
    #expect(fixture.updates.contains { $0.text == ChatContextExchange.unchanged })
  }
}
