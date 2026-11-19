import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func draftHead(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws -> String? {
  guard case .revisioned(let state)? = try transaction.state(of: try DraftRecord.ref(novel: novel, chapter: chapter), scope: .vault) else { return nil }
  return state.headRevision
}

/// The chapter operations as random writes on three replicas: whatever they refuse writes nothing, and what they write keeps the chapter area's derived
/// tables equal to a rebuild on every replica.
enum ChapterDomainOperations {
  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "seed a novel, a learner and secrets", weight: 2) { generator, universe in
      let novel = universe.novel(&generator)
      return { transaction in
        if try NovelRecord.read(NovelForgeKey.novel(novel), in: transaction) == .absent { _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction) }
        try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
        for (key, chapter) in [("heir", 1), ("tide", 3)] where try SecretRecord.read(SecretRecord.ref(novel: novel, secret: key), in: transaction) == .absent {
          try PlanWorldWrites.secret(novel: novel, key, revealChapter: chapter, in: &transaction)
        }
      }
    },
    ProjectionOperation(name: "write a plan", weight: 4) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      let learns = generator.chance(0.6) ? [reveal("mara", generator.pick(from: ["heir", "tide"]))] : []
      let edit = ChapterBook.planEdit(learns: learns, ending: generator.chance(0.1) ? true : nil, body: universe.text(&generator))
      return { transaction in try ChapterPlans.write(novel: novel, chapter: chapter, edit, in: &transaction) }
    },
    ProjectionOperation(name: "save a hand-written draft", weight: 6) { generator, universe in
      let (novel, chapter, body) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator) + " \(generator.int(in: 0...9))")
      let (againstHead, now) = (generator.chance(0.8), generator.pick(from: [Date.distantPast, Date.distantFuture]))
      return { transaction in
        let base = againstHead ? try draftHead(novel: novel, chapter: chapter, in: transaction) : nil
        _ = try ChapterDrafts.save(novel: novel, chapter: chapter, DraftEdit(body: body, summary: "It turns."), base: base, at: now, in: &transaction)
      }
    },
    ProjectionOperation(name: "commit the working copy", weight: 2) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in _ = try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "approve a draft", weight: 5) { generator, universe in
      let (novel, chapter, id, asWritten) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid(), generator.chance(0.4))
      return { transaction in
        guard let head = try draftHead(novel: novel, chapter: chapter, in: transaction) else { return }
        let stale = try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: transaction.database)?.stale
        let intent: ApprovalIntent = asWritten ? .asWritten(seen: stale ?? .unrecorded) : .standard
        _ = try ChapterApprovals.approve(novel: novel, chapter: chapter, revision: head, as: intent, id: id, requester: SchemaFixture.requester, in: &transaction)
      }
    },
    ProjectionOperation(name: "finalize a chapter", weight: 4) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), generator.chance(0.5) ? nil : universe.chapter(&generator))
      return { transaction in _ = try FinalizeReviews.finalize(novel: novel, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "restore a draft version", weight: 1) { generator, universe in
      let (novel, chapter, pick) = (universe.novel(&generator), universe.chapter(&generator), generator.int(in: 0...3))
      return { transaction in
        let versions = try DraftVersions.list(novel: novel, chapter: chapter, in: transaction)
        guard !versions.isEmpty else { return }
        let base = try draftHead(novel: novel, chapter: chapter, in: transaction)
        _ = try DraftVersions.restore(novel: novel, chapter: chapter, revision: versions[pick % versions.count].revision, base: base, in: &transaction)
      }
    },
    ProjectionOperation(name: "amend a final chapter or its summary", weight: 2) { generator, universe in
      let (novel, chapter, text, summary) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator), generator.chance(0.5))
      return { transaction in
        if summary {
          try FinalChapters.editSummary(novel: novel, chapter: chapter, summary: text, in: &transaction)
        } else {
          try FinalChapters.amend(novel: novel, chapter: chapter, ChapterAmendment(content: text), in: &transaction)
        }
      }
    },
  ]
}

@Suite("Chapter operations projection property", TestTimeLimit.property)
struct ChapterOperationPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldKeepTheChapterAreaARebuildUnderTheOperations(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(derivations: chapterAreaDerivations, operations: ChapterDomainOperations.all, iterations: 6, steps: 36)
    try await property.check(order: order, seed: 0xD23_0001)
  }
}
