import Foundation
import ShadowStore

// apps/novel-forge-server/src/modules/generation/passage-leaks.ts
enum PassageLeaks {
  /// The kinds the writer's disclosure policy is built from, directly or through the derived tables the writer pack reads.
  private static let policyInputs: Set<NovelForgeKind> = [.novel, .volume, .milestone, .secret, .entity, .characterKnowledge, .page, .chapterPlan, .finalChapter, .approval]

  /// The writer pack parts `WriterPackWorld.disclosureWorld` reads; the characters' standing state is not among them.
  private static let policyParts = Set(WriterPackPart.allCases).subtracting([.characters])

  /// passage-leaks.ts:13, judged by the chapter's writer policy as it stands now (loadWriterDisclosurePolicy). The derived tables are reconciled only at the
  /// transaction's start, so once this transaction wrote a policy input (an earlier op of the same change set, apply-rules.ts:41-44) the policy cannot be read as
  /// it stands; that, a part of it this device cannot read, or a policy it cannot build holds the rewrite.
  static func holdNewLeaks(_ rewrites: [DraftRewritePassage], novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Bool {
    guard try !wrotePolicyInput(novel: novel, before: chapter, in: transaction) else { return true }
    let load: WriterPackLoad
    do throws(StoreError) {
      load = try WriterPackLoader.load(novel: novel, chapter: chapter, in: ReadTransaction(database: transaction.database, registry: NovelForgeSchema.registry))
    } catch {
      throw .store(error)
    }
    guard policyParts.isDisjoint(with: load.unreadable) else { return true }
    do throws(DisclosureError) {
      var disclosure = try writerDisclosurePolicy(in: load.world.disclosureWorld, chapter: chapter)
      return try !givesNothingAway(rewrites, disclosure: &disclosure)
    } catch {
      return true
    }
  }

  /// A draft of an earlier chapter counts: rewriting it ends that chapter's approval and the reveals it ledgered (draft.handler.ts:84). The rewrite's own
  /// chapter does not, so settling its working copy first holds nothing.
  private static func wrotePolicyInput(novel: UUID, before chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Bool {
    let earlierDrafts: Set<EntityKey>
    do throws(NovelForgeKeyError) {
      earlierDrafts = Set(try (1..<max(chapter, 1)).map { earlier throws(NovelForgeKeyError) in try DraftRecord.ref(novel: novel, chapter: earlier).key })
    } catch {
      throw .domain(.belowMinimum(field: "chapter", minimum: 1))
    }
    return transaction.changes.contains { change in
      guard let kind = NovelForgeKind(change.entity) else { return false }
      return policyInputs.contains(kind) || kind == .draft && earlierDrafts.contains(change.key)
    }
  }

  // passage-leaks.ts:15-19
  static func givesNothingAway(_ rewrites: [DraftRewritePassage], disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> Bool {
    for rewrite in rewrites {
      let before = Set(try disclosure.leakLines(rewrite.passage).map { JSString($0) })
      let after = try disclosure.leakLines(rewrite.replacement).map { JSString($0) }
      guard after.allSatisfy(before.contains) else { return false }
    }
    return true
  }
}
