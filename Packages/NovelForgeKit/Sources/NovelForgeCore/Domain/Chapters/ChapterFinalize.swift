import Foundation
import ShadowCore
import ShadowStore

/// Finalizing a chapter (apps/novel-forge-server/src/modules/generation/generation.service.ts:604, finalize-refusals.ts:12 and the commit of
/// ai/graphs/chapter-finalization.graph.ts:126). The canon is the one first-writer-wins value that makes the chapter final, so everything it binds is
/// decided here: the draft head, the plan head, the approval in force, the plan's contract and what the chapter discloses to the reader.
public enum ChapterFinalize {
  /// Finalizes `chapter`, or the lowest approved one; refuses with DRF_001, DRF_002, DRF_004, CHP_005, CHP_010 or FIN_001 (every earlier chapter final), and,
  /// for a chapter with a plan, with `planStateUnavailable` while its plan world is faulted, as what it discloses cannot be computed.
  @discardableResult
  public static func finalize(novel: UUID, chapter: Int? = nil, in transaction: inout WriteTransaction) throws(DomainError) -> Int {
    try transaction.requireNovel(novel)
    let entries = try transaction.lifecycleEntries(novel: novel)
    guard let chapter = chapter ?? entries.filter({ $0.review == .approved }).map(\.chapter).min() else { throw .draftNotFound(nil) }
    let head = try transaction.liveDraft(novel: novel, chapter: chapter)
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
    let entry = try transaction.lifecycle(novel: novel, chapter: chapter, head: head.revision)
    guard entry.review == .approved, let approval = entry.approval else { throw .draftNotApproved(chapter) }
    let draft = head.content
    let summary = draft.summary.flatMap { $0.jsTrim().isEmpty ? nil : $0 }
    if draft.isolated, summary == nil { throw .isolatedWithoutSummary(chapter) }
    if !draft.isolated, summary == nil { throw .summaryMissing(chapter) }
    guard Set(try transaction.finalChapters(novel: novel)).isSuperset(of: 1..<chapter) else { throw .finalizeOutOfOrder(chapter) }
    let plan = try transaction.planHead(novel: novel, chapter: chapter)
    let title = draft.title.map(normalizeLineEndings).flatMap { $0.isEmpty ? nil : $0 }
    let disclosed = plan == nil ? [] : try disclosed(novel: novel, chapter: chapter, in: transaction)
    let canon = Canon(
      draftRevision: head.revision, planRevision: plan?.revision, approval: approval, title: title, body: normalizeLineEndings(draft.body), summary: draft.summary,
      generator: draft.generator, isolated: draft.isolated, volume: plan?.record.content.volume, contract: plan?.record.content.contract ?? ChapterContract(),
      disclosed: disclosed)
    let outcome: FinalizeOutcome
    do throws(StoreError) {
      outcome = try finalRecord(novel: novel, chapter: chapter, canon).finalize(in: &transaction)
    } catch {
      throw .store(error)
    }
    guard case .finalized = outcome else { throw .draftFinal(chapter) }
    guard let plan else { return chapter }
    do throws(StoreError) {
      _ = try ChapterPlanRecord.mark(plan.record.ref, revision: plan.revision, [.finalized], in: &transaction)
    } catch {
      throw .store(error)
    }
    return chapter
  }

  /// apps/novel-forge-server/src/common/provisional-knowledge.ts:130 at finalize, for a chapter that has a plan: what it shows the reader on the plan world as it
  /// stands, secrets an earlier chapter already disclosed included.
  static func disclosed(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> [String] {
    let world = try transaction.planWorld(novel: novel, chapter: chapter)
    return world.disclosureWorld(plans: world.chapters.map(\.plan)).chapterReveals(chapter: chapter)
  }

  private static func finalRecord(novel: UUID, chapter: Int, _ canon: Canon) throws(StoreError) -> FinalChapterRecord {
    do throws(NovelForgeKeyError) {
      return try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon)
    } catch {
      throw .invalidChange(error.errorDescription ?? error.code)
    }
  }
}
