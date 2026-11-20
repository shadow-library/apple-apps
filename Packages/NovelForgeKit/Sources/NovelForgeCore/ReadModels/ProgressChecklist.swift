import Foundation
import GRDB
import ShadowStore
import ShadowText

public struct ChecklistItem: Sendable, Equatable {
  public let key: ProgressItemKey
  public let label: String
  public let why: String
  public let status: ProgressStatus
  public let overrideEntry: UUID?
}

// platform/apps/novel-forge-web/src/features/chat/chat-view.ts:379
public struct Checklist: Sendable, Equatable {
  public let items: [ChecklistItem]

  public var visible: [ChecklistItem] { items.filter { $0.status != .dismissed } }
  public var settled: Int { visible.count { $0.status != .open } }
  public var dismissed: Int { items.count - visible.count }
  public var isComplete: Bool { settled == visible.count }

  public var percent: Int {
    let shown = visible.count
    guard shown > 0 else { return 100 }
    return Int(JSMath.round(Double(settled) / Double(shown) * 100))
  }
}

public enum ChecklistReading: Sendable, Equatable {
  case missing
  case unreadable
  case ready(Checklist)

  public var checklist: Checklist? {
    guard case .ready(let checklist) = self else { return nil }
    return checklist
  }
}

// apps/novel-forge-server/src/modules/new-novel/new-novel.service.ts:64; a missing or removed novel is PRJ_001 there
public struct ProgressChecklist: ReadModel {
  public let checklist: Derived<ChecklistReading>
  public let faults: [ReadFault]

  private static let tables = [
    IndexedRecord.databaseTableName, ChapterLifecycleEntry.databaseTableName, PlanRevealEntry.databaseTableName, NotebookEntryStateRow.databaseTableName,
  ]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ProgressChecklist {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    return ProgressChecklist(checklist: try report.section(tables) { () throws(StoreError) in try checklist(of: novel, in: transaction) }, faults: report.relevant)
  }

  private static func checklist(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChecklistReading {
    let project: NovelRecord
    switch try NovelRecord.read(id: novel, in: transaction) {
    case .absent: return .missing
    case .unreadable: return .unreadable
    case .readable(let entry):
      guard !entry.isRemoved else { return .missing }
      project = entry.record
    }
    let volumes = try VolumeRecord.indexedListing(novel: novel, in: transaction).live.sorted {
      ($0.ordinal, JSString($0.volume)) < ($1.ordinal, JSString($1.volume))
    }
    let next = try nextWritableChapter(of: novel, in: transaction)
    let plan = try transaction.query { database in try PlanRevealEntry.filter(Column("novel") == novel && Column("chapter") == next).fetchOne(database) }
    let fields = progressFieldsFrom(
      ProgressProjectFields(
        premise: project.premise, protagonistKey: project.protagonist, opposition: project.opposition, theme: project.theme, readerPromise: project.readerPromise,
        endingQuestion: project.endingQuestion, ending: project.ending),
      volumeObjectives: volumes.map(\.objective), next: ProgressNextChapter(chapter: next, brief: plan.map(brief)))
    let items = computeProgress(fields, overrides: ChecklistOverrides.overrides(try activeProgressEntries(of: novel, in: transaction)))
    return .ready(
      Checklist(
        items: items.map { ChecklistItem(key: $0.key, label: $0.label, why: $0.why, status: $0.status, overrideEntry: $0.overrideEntryId) }))
  }

  // new-novel.service.ts:68 nextWritableChapter (next-chapter.ts:11): the first chapter with neither a draft nor a final text
  private static func nextWritableChapter(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> Int {
    let entries = try transaction.query { database in try ChapterLifecycleEntry.filter(Column("novel") == novel).fetchAll(database) }
    return ChapterSequence.nextWritable(draftChapters: entries.filter { $0.draft != nil }.map(\.chapter), finalizedChapters: entries.filter(\.isFinal).map(\.chapter))
  }

  // plan-state.ts:94: only a reveal violation marks a brief stale, so a plan this version cannot judge counts as planned
  private static func brief(_ plan: PlanRevealEntry) -> ProgressNextChapter.Brief {
    ProgressNextChapter.Brief(staleReason: plan.status == .violated ? revealStalePrefix + (plan.reason ?? "") : nil)
  }

  // new-novel.service.ts:70 lists the active entries under progress.* oldest first
  private static func activeProgressEntries(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [NotebookEntryRecord] {
    let active = try transaction.query { database in
      try NotebookEntryStateRow.filter(Column("novel") == novel && Column("status") == LedgerEntryStatus.active.rawValue).fetchAll(database)
    }
    var entries = [AppendedEntry<NotebookEntryRecord>]()
    for row in active {
      guard let entry = try NotebookEntryRecord.read(id: row.entry, in: transaction).entry, progressKeyFromTopic(entry.record.topic) != nil else { continue }
      entries.append(entry)
    }
    return entries.sorted(by: NotebookEntryRecord.chronologically).map(\.record)
  }
}
