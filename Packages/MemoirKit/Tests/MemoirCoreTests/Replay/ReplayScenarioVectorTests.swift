import Foundation
import Testing

@testable import MemoirCore

/// `Fixtures/replay/scenarios.json`: the reference's quest, compassion, progression, quick-log and metric handlers, and its rollover walk, over the same steps.
@Suite("Memoir replay scenario vectors", TestTimeLimit.quick)
struct ReplayScenarioVectorTests {
  @Test func shouldCoverTheReferenceSpecsItPorts() throws {
    let sources = Set(try ReplayScenario.all().map(\.source))
    let specs: Set<String> = [
      "tests/quests/day-stamp.spec.ts", "tests/quests/compassion-commands.service.spec.ts", "tests/quests/lock-capacity.spec.ts",
      "tests/quests/reschedule-window.spec.ts", "tests/quick-logs/quick-log-day.spec.ts", "tests/rollover/rollover.service.spec.ts",
    ]
    #expect(specs.isSubset(of: sources))
  }

  @Test(arguments: try ReplayScenario.all().map(\.id))
  func shouldMatchTheReferenceStepByStep(_ id: String) throws {
    let scenario = try #require(try ReplayScenario.all().first { $0.id == id })
    let run = try ReplayScenarioRun(scenario)
    #expect(run.state.halt == nil)
    for (index, (native, reference)) in zip(run.outcomes, scenario.expected.steps).enumerated() {
      #expect(native == reference, "step \(index) \(scenario.steps[index].type): native \(native), reference \(reference)")
    }
  }

  @Test(arguments: try ReplayScenario.all().map(\.id))
  func shouldEndInTheReferenceState(_ id: String) throws {
    let scenario = try #require(try ReplayScenario.all().first { $0.id == id })
    let native = try ReplayScenarioRun(scenario).snapshot.sorted
    let reference = scenario.expected.state.sorted
    #expect(native.hero == reference.hero)
    #expect(native.events == reference.events)
    #expect(native.logs == reference.logs)
    #expect(native.reschedules == reference.reschedules)
    #expect(native.streaks == reference.streaks)
    #expect(native.shieldConsumptions == reference.shieldConsumptions)
    #expect(native.counters == reference.counters)
    #expect(native.achievements == reference.achievements)
    #expect(native.titles == reference.titles)
    #expect(native.cosmetics == reference.cosmetics)
    #expect(native.displayedTitle == reference.displayedTitle)
    #expect(native.pendingReturnerShields == reference.pendingReturnerShields)
    #expect(native.days == reference.days)
    #expect(native.comebackEvents == reference.comebackEvents)
    #expect(native.recoveries == reference.recoveries)
    #expect(native.metrics == reference.metrics)
    #expect(native.quickLogs == reference.quickLogs)
  }
}
