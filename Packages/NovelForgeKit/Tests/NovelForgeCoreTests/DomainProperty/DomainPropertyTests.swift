import Foundation
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

@Suite("Three-replica domain property", .timeLimit(.minutes(4)))
struct DomainPropertyTests {
  /// The operations a default run must see succeed at least once, over both delivery orders.
  static let mustSucceed = [
    "create a volume", "reorder a volume", "remove or restore a volume", "mark a volume's goal met", "create or relabel a milestone", "settle a promise",
    "write a secret", "remove or restore a secret", "reveal or retract a fact for a character", "create or edit an entity", "remove or restore an entity",
    "save a page", "record a Notebook entry by the author", "supersede a Notebook entry", "withdraw a Notebook entry", "write a plan", "claim a milestone", "plan an ending",
    "save a hand-written draft", "approve a draft", "finalize a chapter", "amend a final chapter or its summary",
    "write the next chapter to a draft, an approval or final, then maybe draft the one after",
  ]

  /// How many settle points, over both delivery orders, must show each `DomainReach` feature that is not scenario-only.
  static let minimumReach = 3

  @Test func shouldKeepEveryDomainInvariantOnThreeReplicasUnderAnyOperationsAndDeliveryOrder() async throws {
    let (causal, writerOrder) = (DomainProperty(), DomainProperty())
    async let causalRun: Void = causal.check(order: .causal, seed: 0xD25_0001)
    async let writerOrderRun: Void = writerOrder.check(order: .writerOrderOnly, seed: 0xD25_0002)
    _ = try await (causalRun, writerOrderRun)
    guard DomainProperty.replaySeed == nil else { return }
    let (first, second) = (causal.tally.snapshot, writerOrder.tally.snapshot)
    let done = { (key: String) in (first[key]?.done ?? 0) + (second[key]?.done ?? 0) }
    let unknown = Self.mustSucceed.filter { name in !DomainProperty.operations.contains { $0.name == name } }
    #expect(unknown.isEmpty, "not operations: \(unknown)")
    let neverDone = Self.mustSucceed.filter { done($0) == 0 }
    #expect(neverDone.isEmpty, "operations that never succeeded: \(neverDone)")
    #expect((first["finalize a chapter"]?.done ?? 0) > 0 && (second["finalize a chapter"]?.done ?? 0) > 0, "a standalone finalize succeeds with each delivery order")
    let scenarioOnly = Set(DomainReach.scenarioOnly.map(\.key))
    #expect(scenarioOnly.isSubset(of: DomainReach.features.map(\.key)), "scenario-only states that are not features")
    let rare = DomainReach.features.map(\.key).filter { !scenarioOnly.contains($0) }.map { ($0, done("reached \($0)")) }.filter { $0.1 < Self.minimumReach }
    #expect(rare.isEmpty, "states reached at fewer than \(Self.minimumReach) settle points: \(rare)")
  }
}
