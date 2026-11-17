import Foundation
import GRDB
import ShadowCore
import ShadowStore

public protocol StateReading: ~Copyable {
  func state(of ref: EntityRef, scope: StateScope) throws(StoreError) -> EntityState?
  func states(ofKind kind: EntityKind, scope: StateScope) throws(StoreError) -> [(ref: EntityRef, state: EntityState)]
}

extension ReadTransaction: StateReading {}
extension WriteTransaction: StateReading {}

extension NovelForgeRecord {
  public static func reading(_ state: EntityState?, of ref: EntityRef) -> RecordReading<Self> {
    guard let state else { return .absent }
    if case .purged = state { return .absent }
    if isPending(state) { return .absent }
    guard let reader = reader(of: state) else { return .unreadable(.wrongShape) }
    do throws(UnreadableReason) {
      let removed = try removal(in: reader)
      return .readable(RecordEntry(record: try Self(ref: ref, reading: reader), isRemoved: removed))
    } catch {
      return .unreadable(error)
    }
  }

  public static func read<Transaction: StateReading & ~Copyable>(_ ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<Self> {
    reading(try transaction.state(of: ref, scope: .vault), of: ref)
  }

  public static func listing<Transaction: StateReading & ~Copyable>(in transaction: borrowing Transaction) throws(StoreError) -> RecordListing<Self> {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: nil)
  }

  static func collecting(_ states: [(ref: EntityRef, state: EntityState)], owner: UUID?) -> RecordListing<Self> {
    var entries = [RecordEntry<Self>]()
    var unreadable = 0
    var unattributed = 0
    for (ref, state) in states {
      switch reading(state, of: ref) {
      case .absent:
        continue
      case .readable(let entry):
        if let owner, entry.record.novel != owner { continue }
        entries.append(entry)
      case .unreadable(.unknownSection):
        continue
      case .unreadable:
        guard let actual = reader(of: state).flatMap({ Self.owner(of: ref, in: $0) }) else {
          if owner == nil { unattributed += 1 }
          continue
        }
        if owner == nil || actual == owner { unreadable += 1 }
      }
    }
    return RecordListing(entries: entries.sorted { $0.record.ref < $1.record.ref }, unreadable: unreadable, unattributed: unattributed)
  }

  private static func reader(of state: EntityState) -> FieldReader<Field>? {
    switch state {
    case .record(let record): FieldReader(record.fields)
    case .revisioned(let revisioned): FieldReader(revisioned)
    case .appended, .purged: nil
    }
  }
}

extension KeyedRecord {
  public static func listing<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> RecordListing<Self> {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel)
  }
}

/// Kinds that decode from the head and marks alone; a final chapter picks its text from every retained amendment, so it is not one.
public protocol HeadReadable: KeyedRecord {}

extension PageRecord: HeadReadable {}
extension DraftRecord: HeadReadable {}
extension ChapterPlanRecord: HeadReadable {}
extension AuthorNotesRecord: HeadReadable {}
extension EntityRecord: HeadReadable {}
extension VolumeRecord: HeadReadable {}
extension MilestoneRecord: HeadReadable {}
extension ThreadRecord: HeadReadable {}
extension MysteryRecord: HeadReadable {}
extension SecretRecord: HeadReadable {}
extension CharacterKnowledgeRecord: HeadReadable {}

extension HeadReadable {
  public static func readHead(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> RecordReading<Self> {
    reading(try transaction.stateNamingRevisions(of: ref, scope: .vault), of: ref)
  }

  /// The novel's live records through the record index, reading each one's head only; the index trails a write that is still open, so write paths use `listing(novel:)`.
  public static func indexedListing(novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> RecordListing<Self> {
    let rows = try transaction.query { database in
      try IndexedRecord.filter(Column("novel") == novel && Column("kind") == kind.rawValue && Column("status") != IndexedStatus.removed).fetchAll(database)
    }
    var entries = [RecordEntry<Self>]()
    var unreadable = 0
    for row in rows {
      switch try readHead(row.ref, in: transaction) {
      case .absent, .unreadable(.unknownSection): continue
      case .unreadable: unreadable += 1
      case .readable(let entry): if !entry.isRemoved { entries.append(entry) }
      }
    }
    return RecordListing(entries: entries.sorted { $0.record.ref < $1.record.ref }, unreadable: unreadable)
  }
}
