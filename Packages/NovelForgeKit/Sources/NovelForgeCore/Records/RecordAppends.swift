import Foundation
import ShadowCore
import ShadowStore

extension UUID: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let text = json.stringValue, let id = UUID(uuidString: text), id.uuidString.lowercased().utf8.elementsEqual(text.utf8) else { return nil }
    self = id
  }

  public var json: JSONValue { .string(uuidString.lowercased()) }
}

public struct AppendedEntry<Record: Sendable & Equatable>: Sendable, Equatable {
  public let record: Record
  public let clock: HLCTimestamp

  public init(record: Record, clock: HLCTimestamp) {
    self.record = record
    self.clock = clock
  }
}

public enum AppendedReading<Record: Sendable & Equatable>: Sendable, Equatable {
  case absent
  case readable(AppendedEntry<Record>)
  case unreadable(UnreadableReason)

  public var entry: AppendedEntry<Record>? {
    guard case .readable(let entry) = self else { return nil }
    return entry
  }
}

public struct AppendedListing<Record: Sendable & Equatable>: Sendable, Equatable {
  public let entries: [AppendedEntry<Record>]
  public let unreadable: Int
  public let unattributed: Int

  public init(entries: [AppendedEntry<Record>], unreadable: Int, unattributed: Int = 0) {
    self.entries = entries
    self.unreadable = unreadable
    self.unattributed = unattributed
  }

  public var records: [Record] { entries.map(\.record) }
}

// An appended item never changes once written, so a fact that comes later about it needs an appended kind of its own.
public protocol AppendedRecord: Sendable, Equatable {
  associatedtype Member: FieldName

  static var kind: NovelForgeKind { get }
  static var novelMember: Member { get }

  var id: UUID { get }
  var novel: UUID { get }
  var members: RecordFields<Member> { get }
  var unrecognised: [String: JSONValue] { get }

  init(id: UUID, reading reader: FieldReader<Member>) throws(UnreadableReason)
}

public protocol ChapterAppendedRecord: AppendedRecord {
  static var chapterMember: Member { get }

  var chapter: Int { get }
}

extension ChapterAppendedRecord {
  /// Unreadable items count when their chapter member names this chapter or cannot be read.
  public static func listing<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(StoreError)
    -> AppendedListing<Self>
  {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel) { reader in
      let stored: Int? = try? reader.required(chapterMember)
      return stored.map { $0 == chapter } ?? true
    }
  }

  static func attributedChapter(in state: EntityState) -> Int? {
    guard case .appended(let appended) = state, let reader = FieldReader<Member>(object: .object(appended.item)) else { return nil }
    return try? reader.required(chapterMember)
  }
}

extension AppendedRecord {
  public static func ref(_ id: UUID) -> EntityRef { EntityRef(kind: kind.entityKind, key: EntityKey(uuid: id)) }

  public var ref: EntityRef { Self.ref(id) }

  public var item: [String: JSONValue] { unrecognised.merging(members.members) { _, known in known } }

  public func append(in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.append(ref, item: item)
  }

  public static func reading(_ state: EntityState?, of ref: EntityRef) -> AppendedReading<Self> {
    guard let state else { return .absent }
    if case .purged = state { return .absent }
    guard let id = identity(of: ref) else { return .unreadable(.identity(ref)) }
    guard case .appended(let appended) = state, let reader = FieldReader<Member>(object: .object(appended.item)) else { return .unreadable(.wrongShape) }
    do throws(UnreadableReason) {
      return .readable(AppendedEntry(record: try Self(id: id, reading: reader), clock: appended.clock))
    } catch {
      return .unreadable(error)
    }
  }

  public static func read<Transaction: StateReading & ~Copyable>(_ ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> AppendedReading<Self> {
    reading(try transaction.state(of: ref, scope: .vault), of: ref)
  }

  public static func read<Transaction: StateReading & ~Copyable>(id: UUID, in transaction: borrowing Transaction) throws(StoreError) -> AppendedReading<Self> {
    try read(ref(id), in: transaction)
  }

  public static func listing<Transaction: StateReading & ~Copyable>(in transaction: borrowing Transaction) throws(StoreError) -> AppendedListing<Self> {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: nil)
  }

  public static func listing<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> AppendedListing<Self> {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel)
  }

  static func collecting(
    _ states: [(ref: EntityRef, state: EntityState)], owner: UUID?, including belongs: (FieldReader<Member>) -> Bool = { _ in true }
  ) -> AppendedListing<Self> {
    var entries = [AppendedEntry<Self>]()
    var unreadable = 0
    var unattributed = 0
    for (ref, state) in states {
      let raw = rawReader(of: state)
      let included = raw.map(belongs) ?? true
      if let owner, let raw, let actual = novel(in: raw), actual != owner || !included { continue }
      // Applies with owner == nil too: unreadable items of other sessions are then not counted.
      if raw != nil, !included { continue }
      switch reading(state, of: ref) {
      case .absent:
        continue
      case .readable(let entry):
        guard owner == nil || entry.record.novel == owner, included else { continue }
        entries.append(entry)
      case .unreadable:
        guard let actual = raw.flatMap(novel(in:)) else {
          if owner == nil { unattributed += 1 }
          continue
        }
        if owner == nil || (actual == owner && included) { unreadable += 1 }
      }
    }
    return AppendedListing(entries: entries.sorted(by: chronologically), unreadable: unreadable, unattributed: unattributed)
  }

  static func chronologically(_ first: AppendedEntry<Self>, _ second: AppendedEntry<Self>) -> Bool {
    guard first.clock == second.clock else { return first.clock < second.clock }
    return first.record.ref < second.record.ref
  }

  private static func identity(of ref: EntityRef) -> UUID? {
    guard NovelForgeKind(ref.kind) == kind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { return nil }
    return id
  }

  private static func rawReader(of state: EntityState) -> FieldReader<Member>? {
    guard case .appended(let appended) = state else { return nil }
    return FieldReader(object: .object(appended.item))
  }

  private static func novel(in reader: FieldReader<Member>) -> UUID? {
    try? reader.required(novelMember)
  }
}
