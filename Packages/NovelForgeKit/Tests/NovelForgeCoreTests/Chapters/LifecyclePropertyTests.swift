import Foundation
import GRDB
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

/// The chapter writes that rewrite or finalize what the lifecycle judges, without random upstreams that would leave every draft stale.
private let chapterWrites = ProjectionOperations.chapters.filter { ["finalize chapter", "purge final chapter", "revise a draft that has no key"].contains($0.name) }

@Suite("Chapter lifecycle property", .serialized, TestTimeLimit.property)
struct LifecyclePropertyTests {
  /// Both delivery orders in one test, one after the other, so each run's gates count only its own operations.
  @Test func shouldKeepTheLifecycleOverJobsReviewsAndRemediesEqualToARebuildOnEveryReplica() async throws {
    for (order, seed) in [(CausalReplicaOrder.causal, UInt64(0x6721)), (.writerOrderOnly, 0x6722)] {
      LifecycleOperations.resetGates()
      let property = ProjectionProperty(
        derivations: chapterAreaDerivations, operations: ProjectionOperations.novels + ProjectionOperations.lifecycle + chapterWrites, iterations: 12,
        steps: 80, gated: true)
      try await property.check(order: order, seed: seed)
      let seen = LifecycleOperations.reached
      #expect(seen.isSuperset(of: [.generating, .contradiction, .approved, .needsReview]), "\(order): reached \(seen.map(\.rawValue).sorted())")
      #expect(LifecycleOperations.answersToAHold > 0, "\(order): no answer went to a review holding its chapter")
      #expect(LifecycleOperations.leakHolds > 0, "\(order): no chapter was held by its rewrite's leak alone")
    }
  }
}
