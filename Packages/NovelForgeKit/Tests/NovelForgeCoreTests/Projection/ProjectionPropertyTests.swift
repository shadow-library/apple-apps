import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func chapterOracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  let expected = try await store.read { transaction in
    let finals = try FinalChapterRecord.listing(in: transaction).entries.map(\.record)
    var cursors = [UUID: Int]()
    for novel in universe.novels {
      let chapters = Set(finals.filter { $0.novel == novel }.map(\.chapter))
      guard try NovelRecord.read(NovelForgeKey.novel(novel), in: transaction) != .absent || !chapters.isEmpty else { continue }
      var cursor = 1
      while chapters.contains(cursor) { cursor += 1 }
      cursors[novel] = cursor
    }
    return (finals: Set(finals.map(\.ref)), cursors: cursors)
  }
  guard Set(try await Projection.finals(in: store).map(\.ref)) == expected.finals else { throw ProjectionPropertyFailure.oracle("final chapters") }
  guard try await Projection.cursors(in: store) == expected.cursors else { throw ProjectionPropertyFailure.oracle("story cursors") }
}

private func volumeOracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  for novel in universe.novels {
    let expected = try await store.read { transaction in try VolumeRecord.listing(novel: novel, in: transaction).live.map(\.ordinal).max() }
    let projected = try await Projection.fetch(HighestVolumeDerivation.request(for: novel), in: store).first?.ordinal
    guard projected == expected else { throw ProjectionPropertyFailure.oracle("highest volume of \(novel)") }
  }
}

@Suite("Projection property", .timeLimit(.minutes(5)))
struct ProjectionPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAtEveryStepAndConvergeOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(settled: chapterOracle)
    try await property.check(order: order, seed: order == .causal ? 0xD13A : 0xD13B)
  }

  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldKeepAPerNovelAggregateOverEditedRecordsEqualToARebuild(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(
      derivations: NovelForgeDerivations.standard + [HighestVolumeDerivation()], operations: ProjectionOperations.novels + ProjectionOperations.volumes, iterations: 8,
      settled: volumeOracle)
    try await property.check(order: order, seed: order == .causal ? 0xD13C : 0xD13D)
  }
}
