import Foundation
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

@Suite("Chat replicas converge", TestTimeLimit.property)
struct ChatReplicaPropertyTests {
  static let mustSucceed = ChatReplicaOperation.allCases.map(\.rawValue)

  @Test func shouldConvergeOnOneSessionWhenDevicesChatDecideUndoAndCompactUnderAnyDelivery() async throws {
    let (causal, writerOrder) = (ChatReplicaProperty(), ChatReplicaProperty())
    async let causalRun: Void = causal.check(order: .causal, seed: 0xF26_0001)
    async let writerOrderRun: Void = writerOrder.check(order: .writerOrderOnly, seed: 0xF26_0002)
    _ = try await (causalRun, writerOrderRun)
    guard ChatReplicaProperty.replaySeed == nil else { return }
    let (first, second) = (causal.tally.snapshot, writerOrder.tally.snapshot)
    let done = { (name: String) in (first[name]?.done ?? 0) + (second[name]?.done ?? 0) }
    let neverDone = Self.mustSucceed.filter { done($0) == 0 }
    #expect(neverDone.isEmpty, "operations that never succeeded: \(neverDone)")
    let reach = causal.reach.snapshot + writerOrder.reach.snapshot
    #expect(reach.map(\.repliesToOneMessage).reduce(0, +) > 0, "no message was answered twice")
    #expect(reach.map(\.raisedByMerge).reduce(0, +) > 0, "no decision was raised by a merge")
    #expect(reach.map(\.appliedWithTwoSelections).reduce(0, +) > 0, "no card was applied on two devices with different selections")
    #expect(reach.contains { $0.summaries > 1 }, "no session folded twice")
    #expect(reach.map(\.competingSummaries).reduce(0, +) > 0, "no two folds competed")
    #expect(reach.contains(where: \.locked) && reach.contains { !$0.locked }, "runs did not both lock and stay unlocked")
  }
}
