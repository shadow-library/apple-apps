import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

// Fixtures/chat-turns/generate.ts
@Suite("Chat scenarios against the reference", .timeLimit(.minutes(5)))
struct ChatScenarioTests {
  @Test func shouldHoldEveryScenarioWithAnOutcomePerStep() throws {
    let scenarios = try ChatScenarioFixture.load().scenarios
    #expect(scenarios.count >= 12)
    #expect(Set(scenarios.map(\.name)).count == scenarios.count)
    for scenario in scenarios {
      #expect(!scenario.steps.isEmpty && scenario.steps.count == scenario.expected.count, "\(scenario.name)")
      for difference in scenario.differences { #expect(scenario.steps.indices.contains(difference.step) && !difference.why.isEmpty, "\(scenario.name)") }
    }
  }

  @Test(arguments: ChatScenarioFixture.names)
  func shouldReproduceTheReferenceOutcomeOfEveryStep(_ name: String) async throws {
    let fixture = try ChatScenarioFixture.load()
    let scenario = try #require(fixture.scenarios.first { $0.name == name })
    let runner = try await ChatScenarioRunner.start(fixture.world, vault: scenario.vault, watch: scenario.watch)
    for (index, step) in scenario.steps.enumerated() {
      let actual = try await runner.run(step, index: index)
      switch scenario.expectation(at: index) {
      case .failure(let stale):
        Issue.record("\(name) step \(index): a recorded difference no longer holds\n\(stale)")
      case .success(let expected):
        var lines = [String]()
        ChatScenarioJSON.compare(expected, actual, at: "step \(index)", into: &lines)
        #expect(lines.isEmpty, "\(name)\n\(lines.joined(separator: "\n"))")
      }
    }
  }
}
