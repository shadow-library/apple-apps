import Foundation
import GRDB
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

/// The chapter writes that rewrite or finalize what the lifecycle judges, without random upstreams that would leave every draft stale.
private let chapterWrites = ProjectionOperations.chapters.filter { ["finalize chapter", "purge final chapter", "revise a draft that has no key"].contains($0.name) }

@Suite("Chapter lifecycle property", TestTimeLimit.property)
struct LifecyclePropertyTests {
  @Test(arguments: [(CausalReplicaOrder.causal, UInt64(0x6721)), (.writerOrderOnly, 0x6722)])
  func shouldKeepTheLifecycleOverJobsReviewsAndRemediesEqualToARebuildOnEveryReplica(order: CausalReplicaOrder, seed: UInt64) async throws {
    let reached = Reached()
    let property = ProjectionProperty(
      derivations: chapterAreaDerivations, operations: ProjectionOperations.novels + LifecycleOperations.all(reaching: reached) + chapterWrites,
      iterations: 12, steps: 80, gated: true)
    try await property.check(order: order, seed: seed)
    let seen = reached.all
    let statuses = [DraftReviewState.generating, .contradiction, .approved, .needsReview].map(\.rawValue)
    #expect(seen.isSuperset(of: statuses), "\(order): reached \(seen.sorted())")
    #expect(seen.contains(LifecycleOperations.answerToAHold), "\(order): no answer went to a review holding its chapter")
    #expect(seen.contains(LifecycleOperations.leakHold), "\(order): no chapter was held by its rewrite's leak alone")
  }
}
