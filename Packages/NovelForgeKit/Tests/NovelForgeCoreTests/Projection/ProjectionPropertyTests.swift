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

private struct ExpectedRow: Equatable {
  let novel: UUID?
  let chapter: Int?
  let status: IndexedStatus
}

private func expectedRow<R: ChapterAppendedRecord>(_: R.Type, _ ref: EntityRef, _ state: EntityState) -> ExpectedRow? {
  guard case .appended(let appended) = state else { return nil }
  let novel = appended.item[R.novelMember.rawValue].flatMap(UUID.init(json:))
  let chapter = appended.item[R.chapterMember.rawValue].flatMap(Int.init(json:))
  switch R.reading(state, of: ref) {
  case .absent: return nil
  case .readable(let entry): return ExpectedRow(novel: entry.record.novel, chapter: entry.record.chapter, status: .live)
  case .unreadable: return ExpectedRow(novel: novel, chapter: chapter, status: .unreadable)
  }
}

private func expectedRow<R: KeyedRecord>(_: R.Type, _ ref: EntityRef, _ state: EntityState) -> ExpectedRow? {
  let key = try? NovelForgeKey(reading: state, of: ref)
  switch R.reading(state, of: ref) {
  case .absent: return nil
  case .readable(let entry): return ExpectedRow(novel: entry.record.novel, chapter: key?.components.chapters.first, status: entry.isRemoved ? .removed : .live)
  case .unreadable: return ExpectedRow(novel: key?.novel, chapter: key?.components.chapters.first, status: .unreadable)
  }
}

private func reviewIndexOracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  let kinds: [NovelForgeKind] = [.chapterReview, .reviewRemedy, .finalizeReview, .finalizeDecision, .refreshReport]
  let expected = try await store.read { transaction in
    var rows = [EntityRef: ExpectedRow]()
    for kind in kinds {
      for (ref, state) in try transaction.states(ofKind: kind.entityKind, scope: .vault) {
        let row: ExpectedRow? =
          switch kind {
          case .chapterReview: expectedRow(ChapterReviewRecord.self, ref, state)
          case .finalizeReview: expectedRow(FinalizeReviewRecord.self, ref, state)
          case .refreshReport: expectedRow(RefreshReportRecord.self, ref, state)
          case .reviewRemedy: expectedRow(ReviewRemedyRecord.self, ref, state)
          default: expectedRow(FinalizeDecisionRecord.self, ref, state)
          }
        rows[ref] = row
      }
    }
    return rows
  }
  let indexed = try await Projection.fetch(IndexedRecord.filter(kinds.map(\.rawValue).contains(Column("kind"))), in: store)
  let projected = Dictionary(uniqueKeysWithValues: indexed.map { ($0.ref, ExpectedRow(novel: $0.novel, chapter: $0.chapter, status: $0.status)) })
  guard projected == expected else { throw ProjectionPropertyFailure.oracle("indexed review and finalize records") }
}

@Suite("Projection property", TestTimeLimit.property)
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

  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldIndexEveryReviewAndFinalizeRecordUnderItsNovelAndChapterAsARebuildDoes(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(operations: ProjectionOperations.novels + ProjectionOperations.reviews, iterations: 8, settled: reviewIndexOracle)
    try await property.check(order: order, seed: order == .causal ? 0xD13E : 0xD13F)
  }
}
