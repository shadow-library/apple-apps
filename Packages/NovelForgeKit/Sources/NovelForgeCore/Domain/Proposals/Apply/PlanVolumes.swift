import Foundation
import GRDB
import ShadowCore
import ShadowStore

extension PlanHandlers {
  /// apps/novel-forge-server/src/modules/refinement/staged-plan.ts:15: the plan as applying `update` would leave it, merged in memory; nothing is written.
  static func stagedPlan(_ update: BriefUpdate, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> ChapterPlanContent {
    let chapter = update.chapter
    let ref = try handlerDomain { () throws(DomainError) in try ChapterRefs.plan(novel: novel, chapter: chapter) }
    var existing: ChapterPlanContent?
    switch try handlerStore({ () throws(StoreError) in try ChapterPlanRecord.read(ref, in: transaction) }) {
    case .unreadable: throw .unreadable(ref: "chapter:\(chapter)")
    case .readable(let entry): if !entry.isRemoved { existing = entry.record.content }
    case .absent: break
    }
    let volume = existing != nil || update.volumeKey != nil ? nil : try nearestVolume(to: chapter, novel: novel, in: transaction)
    return PlanBriefMerge.merged(existing, update, defaults: PlanDefaults(volume: volume, contentMode: nil))
  }

  /// apps/novel-forge-server/src/common/brief-volume.ts:9 over the plan world reconciled at the transaction's start with the plans it has written since. A
  /// plan this device cannot read is refused only when, with a volume of its own, it would be the nearest.
  static func nearestVolume(to chapter: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> String? {
    let world = try handlerDomain { () throws(DomainError) in try transaction.planWorld(novel: novel, chapter: chapter) }
    var volumes = [Int: String?]()
    for planned in world.chapters { volumes.updateValue(planned.volume, forKey: planned.chapter) }
    // a final chapter whose canon cannot be read leaves the world without its volume, though the reference reads that chapter's plan
    var unreadable = Set(world.plans + world.unreadablePlans).subtracting(volumes.keys)
    for (written, reading) in try plansWritten(novel: novel, in: transaction) {
      switch reading {
      case .readable(let entry) where !entry.isRemoved:
        volumes.updateValue(entry.record.content.volume, forKey: written)
        unreadable.remove(written)
      case .unreadable:
        volumes.removeValue(forKey: written)
        unreadable.insert(written)
      case .readable, .absent:
        volumes.removeValue(forKey: written)
        unreadable.remove(written)
      }
    }
    try requireAttributedPlans(chapter, in: transaction)
    let plans = volumes.map { PlanClaims(chapter: $0.key, volumeKey: $0.value, isEnding: false, claimedMilestones: nil) }
    for candidate in unreadable.sorted() {
      let probed = ["\u{0}first", "\u{0}second"].map { probe in
        nearestVolumeKey(plans + [PlanClaims(chapter: candidate, volumeKey: probe, isEnding: false, claimedMilestones: nil)], chapter: chapter)
      }
      if !sameText(probed[0], probed[1]) { throw .unreadable(ref: "chapter:\(candidate)") }
    }
    return nearestVolumeKey(plans, chapter: chapter)
  }

  /// The plans of the novel this transaction wrote, as they stand now (DraftApplyGuards.draftChaptersWritten's pattern).
  private static func plansWritten(novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> [(Int, RecordReading<ChapterPlanRecord>)] {
    var written = [(Int, RecordReading<ChapterPlanRecord>)]()
    var seen = Set<Int>()
    for change in transaction.changes where change.entity == NovelForgeKind.chapterPlan.entityKind {
      let ref = EntityRef(kind: change.entity, key: change.key)
      guard let state = try handlerStore({ () throws(StoreError) in try transaction.state(of: ref, scope: .vault) }),
        let key = try? NovelForgeKey(reading: state, of: ref), key.novel == novel, case .chapterPlan(let chapter) = key.components, seen.insert(chapter).inserted
      else { continue }
      written.append((chapter, ChapterPlanRecord.reading(state, of: ref)))
    }
    return written
  }

  /// The plan world reads only plans whose natural key names their novel; one whose key cannot be read might belong to this novel, so it is refused, as is a
  /// record index faulted on a plan, which could hide one.
  private static func requireAttributedPlans(_ chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) {
    let unattributed = try handlerDomain { () throws(DomainError) in
      try transaction.fetch(
        IndexedRecord.filter(
          Column("kind") == NovelForgeKind.chapterPlan.rawValue && Column("novel") == nil && Column("status") == IndexedStatus.unreadable.rawValue))
    }
    if let plan = unattributed.first { throw .unreadable(ref: "\(plan.ref.kind.rawValue)/\(plan.ref.key.rawValue)") }
    let faults = try handlerDomain { () throws(DomainError) in try transaction.faultKeys(of: IndexedRecord.databaseTableName) }
    let planKind = NovelForgeKind.chapterPlan.entityKind
    if faults.contains(where: { ProjectionFaults.kind(ofKey: $0).map { $0 == planKind } ?? true }) { throw .domain(.planStateUnavailable(chapter)) }
  }
}
