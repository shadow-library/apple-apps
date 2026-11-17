import Foundation
import GRDB
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

/// One novel as its synced records say, read without any derived table: what the invariants are judged against.
struct NovelRecords {
  let novel: UUID
  let exists: Bool
  var finals: [Int: FinalChapterRecord] = [:]
  var heads: [Int: String] = [:]
  /// What each live draft's head revision records it was written against; nil when it records nothing readable.
  var upstreams: [Int: DraftUpstream?] = [:]
  var plans: [Int: ChapterContract] = [:]
  var approvals: [AppendedEntry<ApprovalRecord>] = []
  var secrets: [String: SecretRecord] = [:]
  var entities: Set<String> = []
  var created: [EntityRef: HLCTimestamp] = [:]
  var milestones: Set<String> = []
  var volumes: [VolumeRecord] = []
  var manual: [CharacterKnowledgeRecord] = []
  var retracted: Set<String> = []
  var entries: [AppendedEntry<NotebookEntryRecord>] = []
  var withdrawals: [AppendedEntry<NotebookWithdrawalRecord>] = []
  var pages = 0
  var promises = 0
  /// Per kind, every stored record as (stored ref, ref rebuilt from its natural key, natural key).
  var naturalKeys: [String: [(stored: EntityRef, rebuilt: EntityRef, key: String)]] = [:]

  static func pair(_ fact: String, _ entity: String) -> String { "\(fact)\u{0}\(entity)" }

  /// The highest F such that chapters 1 to F are all final.
  var frontier: Int {
    var next = 1
    while finals[next] != nil { next += 1 }
    return next - 1
  }

  func approval(_ id: UUID) -> AppendedEntry<ApprovalRecord>? { approvals.first { $0.record.id == id } }

  /// The contract the plan world reads for a chapter: a final one's canon, any other's live plan.
  func contract(of chapter: Int) -> ChapterContract? { finals[chapter]?.canon.contract ?? plans[chapter] }

  var worldChapters: [Int] { Set(finals.keys).union(plans.keys).sorted() }

  static func read(_ novel: UUID, in transaction: ReadTransaction) throws -> NovelRecords {
    var records = NovelRecords(novel: novel, exists: try NovelRecord.read(NovelForgeKey.novel(novel), in: transaction) != .absent)
    for entry in try FinalChapterRecord.listing(novel: novel, in: transaction).entries {
      records.finals[entry.record.chapter] = entry.record
      records.note("final", entry.record.ref, try FinalChapterRecord.ref(novel: novel, chapter: entry.record.chapter), "\(entry.record.chapter)")
    }
    for entry in try DraftRecord.listing(novel: novel, in: transaction).entries {
      records.note("draft", entry.record.ref, try DraftRecord.ref(novel: novel, chapter: entry.record.chapter), "\(entry.record.chapter)")
      guard !entry.isRemoved, case .revisioned(let state)? = try transaction.state(of: entry.record.ref, scope: .vault), let head = state.headRevision else { continue }
      records.heads[entry.record.chapter] = head
      records.upstreams[entry.record.chapter] = .some(entry.record.content.upstream)
    }
    for entry in try ChapterPlanRecord.listing(novel: novel, in: transaction).entries {
      records.note("plan", entry.record.ref, try ChapterPlanRecord.ref(novel: novel, chapter: entry.record.chapter), "\(entry.record.chapter)")
      if !entry.isRemoved { records.plans[entry.record.chapter] = entry.record.content.contract }
    }
    records.approvals = try ApprovalRecord.listing(novel: novel, in: transaction).entries
    for entry in try SecretRecord.listing(novel: novel, in: transaction).entries {
      records.note("secret", entry.record.ref, SecretRecord.ref(novel: novel, secret: entry.record.secret), entry.record.secret)
      records.created[entry.record.ref] = try creation(of: entry.record.ref, in: transaction)
      if !entry.isRemoved { records.secrets[entry.record.secret] = entry.record }
    }
    for entry in try EntityRecord.listing(novel: novel, in: transaction).entries {
      records.note("entity", entry.record.ref, EntityRecord.ref(novel: novel, entity: entry.record.entity), entry.record.entity)
      records.created[entry.record.ref] = try creation(of: entry.record.ref, in: transaction)
      if !entry.isRemoved { records.entities.insert(entry.record.entity) }
    }
    for entry in try MilestoneRecord.listing(novel: novel, in: transaction).entries {
      records.note("milestone", entry.record.ref, MilestoneRecord.ref(novel: novel, milestone: entry.record.milestone), entry.record.milestone)
      if !entry.isRemoved { records.milestones.insert(entry.record.milestone) }
    }
    for entry in try VolumeRecord.listing(novel: novel, in: transaction).entries {
      records.note("volume", entry.record.ref, VolumeRecord.ref(novel: novel, volume: entry.record.volume), entry.record.volume)
      if !entry.isRemoved { records.volumes.append(entry.record) }
    }
    for entry in try CharacterKnowledgeRecord.listing(novel: novel, in: transaction).entries {
      let (fact, entity) = (entry.record.fact, entry.record.entity)
      records.note("knowledge", entry.record.ref, CharacterKnowledgeRecord.ref(novel: novel, fact: fact, entity: entity), pair(fact, entity))
      if entry.isRemoved { records.retracted.insert(pair(fact, entity)) } else { records.manual.append(entry.record) }
    }
    for entry in try PageRecord.listing(novel: novel, in: transaction).entries {
      let (section, slug) = (entry.record.section, entry.record.slug)
      records.note("page", entry.record.ref, PageRecord.ref(novel: novel, section: section, slug: slug), "\(section.rawValue)/\(slug)")
      if !entry.isRemoved { records.pages += 1 }
    }
    for entry in try ThreadRecord.listing(novel: novel, in: transaction).entries {
      records.note("thread", entry.record.ref, ThreadRecord.ref(novel: novel, thread: entry.record.thread), entry.record.thread)
      if !entry.isRemoved { records.promises += 1 }
    }
    for entry in try MysteryRecord.listing(novel: novel, in: transaction).entries {
      records.note("mystery", entry.record.ref, MysteryRecord.ref(novel: novel, mystery: entry.record.mystery), entry.record.mystery)
      if !entry.isRemoved { records.promises += 1 }
    }
    records.entries = try NotebookEntryRecord.listing(novel: novel, in: transaction).entries
    records.withdrawals = try NotebookWithdrawalRecord.listing(novel: novel, in: transaction).entries
    return records
  }

  private mutating func note(_ kind: String, _ stored: EntityRef, _ rebuilt: EntityRef, _ key: String) {
    naturalKeys[kind, default: []].append((stored, rebuilt, key))
  }

  /// A natural-key record's first creation: its key field is first-writer-wins, so removal and re-creation keep it.
  private static func creation(of ref: EntityRef, in transaction: ReadTransaction) throws -> HLCTimestamp? {
    guard case .record(let state)? = try transaction.state(of: ref, scope: .vault) else { return nil }
    return state[field: CommonField.naturalKey.rawValue]?.clock
  }
}

/// One novel's derived rows, as the replica's reconciler left them.
struct NovelDerived {
  let finals: [FinalChapterEntry]
  let cursor: StoryCursor?
  let lifecycle: [Int: ChapterLifecycleEntry]
  let inForce: [Int: ApprovalInForce]
  let claims: [MilestoneClaimEntry]
  let milestoneStates: [MilestoneStateEntry]
  let reveals: [Int: PlanRevealEntry]
  let volumes: [VolumeStateEntry]
  let notebook: [UUID: NotebookEntryStateRow]
  let knowledge: [CharacterKnowledgeEntry]

  static func read(_ novel: UUID, in database: Database) throws -> NovelDerived {
    let mine = Column("novel") == novel
    return NovelDerived(
      finals: try FinalChapterEntry.filter(mine).fetchAll(database), cursor: try StoryCursor.filter(mine).fetchOne(database),
      lifecycle: Dictionary(uniqueKeysWithValues: try ChapterLifecycleEntry.filter(mine).fetchAll(database).map { ($0.chapter, $0) }),
      inForce: Dictionary(uniqueKeysWithValues: try ApprovalInForce.filter(mine).fetchAll(database).map { ($0.chapter, $0) }),
      claims: try MilestoneClaimEntry.filter(mine).fetchAll(database), milestoneStates: try MilestoneStateEntry.filter(mine).fetchAll(database),
      reveals: Dictionary(uniqueKeysWithValues: try PlanRevealEntry.filter(mine).fetchAll(database).map { ($0.chapter, $0) }),
      volumes: try VolumeStateEntry.filter(mine).fetchAll(database),
      notebook: Dictionary(uniqueKeysWithValues: try NotebookEntryStateRow.filter(mine).fetchAll(database).map { ($0.entry, $0) }),
      knowledge: try CharacterKnowledgeEntry.filter(mine).fetchAll(database))
  }
}
