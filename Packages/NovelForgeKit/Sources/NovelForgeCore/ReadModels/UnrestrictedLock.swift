import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum UnrestrictedHolder: Hashable, Sendable {
  /// A chat of the novel, a removed one included.
  case chats
  /// A retained revision of the chapter's draft, a removed draft's included; the chapter is nil when the draft's key cannot be read.
  case draft(chapter: Int?)
  case canon(chapter: Int?)
  /// A chapter review or finalize review of isolated prose, which quotes it.
  case chapterReview(chapter: Int?)
  case finalizeReview(chapter: Int?)
}

/// What keeps a novel unrestricted, since the mode is one-way after first use (shadow-native-apps-plan.md:715): every chat, draft revision or canon that holds,
/// or may hold, unrestricted text. What this version cannot read counts as holding, and a fault that could withdraw a holder makes the lock unavailable, which
/// `isLocked` treats as locked. Chapter records are found through the record index, which trails a write still open; one whose novel cannot be read counts
/// for every novel.
public struct UnrestrictedLock: ReadModel {
  public let holders: Derived<[UnrestrictedHolder]>
  public let faults: [ReadFault]

  public var isLocked: Bool { holders != .available([]) }

  private static let chapterKinds: [NovelForgeKind] = [.draft, .finalChapter, .chapterReview, .finalizeReview]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> UnrestrictedLock {
    let chats = try ChatSessions.load(novel, in: transaction)
    let faults = ChatUnrestrictedLock.faults(among: chats.faults) + (try indexFaults(novel, in: transaction))
    guard faults.isEmpty, let chatsHold = chats.holdsUnrestrictedText.value else { return UnrestrictedLock(holders: .unavailable(faults), faults: faults) }
    let chapters = try chapterHolders(novel, in: transaction)
    return UnrestrictedLock(holders: .available((chatsHold ? [.chats] : []) + chapters), faults: [])
  }

  private static func chapterHolders(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [UnrestrictedHolder] {
    let kinds = chapterKinds.map(\.rawValue)
    let rows = try transaction.query { database in
      try IndexedRecord.filter((Column("novel") == novel || Column("novel") == nil) && kinds.contains(Column("kind")))
        .order(Column("chapter"), Column("kind"), Column("key")).fetchAll(database)
    }
    var holders = [UnrestrictedHolder]()
    for row in rows {
      switch row.kind {
      case .draft: if try draftHolds(row.ref, in: transaction) { holders.append(.draft(chapter: row.chapter)) }
      case .finalChapter: if try canonHolds(row.ref, in: transaction) { holders.append(.canon(chapter: row.chapter)) }
      case .chapterReview: if try reviewHolds(ChapterReviewRecord.read(row.ref, in: transaction), \.isolated) { holders.append(.chapterReview(chapter: row.chapter)) }
      case .finalizeReview: if try reviewHolds(FinalizeReviewRecord.read(row.ref, in: transaction), \.isolated) { holders.append(.finalizeReview(chapter: row.chapter)) }
      default: continue
      }
    }
    return holders
  }

  private static func draftHolds(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    switch DraftRecord.history(of: try transaction.state(of: ref, scope: .vault), at: ref) {
    case .absent: false
    case .unreadable: true
    case .readable(let history): history.revisions.contains { $0.body.body.map { holdsUnrestrictedText(generator: $0.generator, isolated: $0.isolated) } ?? true }
    }
  }

  private static func canonHolds(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    switch try FinalChapterRecord.read(ref, in: transaction) {
    case .absent: false
    case .unreadable: true
    case .readable(let entry): holdsUnrestrictedText(generator: entry.record.canon.generator, isolated: entry.record.canon.isolated)
    }
  }

  private static func reviewHolds<Record>(_ reading: AppendedReading<Record>, _ isolated: KeyPath<Record, Bool>) -> Bool {
    switch reading {
    case .absent: false
    case .unreadable: true
    case .readable(let entry): entry.record[keyPath: isolated]
    }
  }

  private static func holdsUnrestrictedText(generator: StoredEnum<ContentGenerator>, isolated: Bool) -> Bool {
    switch generator {
    case .known(.standard), .known(.human): isolated
    case .known(.unrestricted), .unknown: true
    }
  }

  /// A fault on the record index for the whole table or this novel blocks the read; one on a single chapter record blocks it when that entity is this novel's
  /// or its novel cannot be read, since its index row is withdrawn. A fault on another kind or another novel's entity cannot hide a holder.
  private static func indexFaults(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [ReadFault] {
    let table = IndexedRecord.databaseTableName
    let rows = try FaultRows(in: transaction)
    let blocking = ReadFaults(novel: novel, reading: [table], from: rows).blocking([table])
    let entries = rows.rows.compactMap { row -> (key: String, message: String)? in
      let (derivation, key): (String, String) = (row["derivation"], row["key"])
      guard derivation == table, key != ProjectionFaults.wholeDerivation, UUID(uuidString: key) == nil else { return nil }
      if let kind = ProjectionFaults.kind(ofKey: key), !chapterKinds.contains(where: { $0.entityKind == kind }) { return nil }
      return (key, row["message"])
    }
    guard !entries.isEmpty else { return blocking }
    let owners = try owners(in: transaction)
    let hiding = entries.filter { entry in owners[entry.key].map { $0 == nil || $0 == novel } ?? true }
    return blocking + hiding.map { ReadFault(derivation: table, scope: .entry, message: $0.message) }
  }

  private static func owners(in transaction: ReadTransaction) throws(StoreError) -> [String: UUID?] {
    var owners = [String: UUID?]()
    for kind in chapterKinds {
      for (ref, state) in try transaction.states(ofKind: kind.entityKind, scope: .vault) { owners[ProjectionFaults.key(ref)] = owner(of: kind, ref, state) }
    }
    return owners
  }

  private static func owner(of kind: NovelForgeKind, _ ref: EntityRef, _ state: EntityState) -> UUID? {
    switch kind {
    case .chapterReview: ChapterReviewRecord.attributedNovel(in: state)
    case .finalizeReview: FinalizeReviewRecord.attributedNovel(in: state)
    default: try? NovelForgeKey(reading: state, of: ref).novel
    }
  }
}
