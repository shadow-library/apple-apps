import Foundation
import ShadowCore
import ShadowStore

public protocol RecordSource: ~Copyable {
  func state(of ref: EntityRef, scope: StateScope) throws(StoreError) -> EntityState?
  func states(ofKind kind: EntityKind, scope: StateScope) throws(StoreError) -> [(ref: EntityRef, state: EntityState)]
}

extension ReadTransaction: RecordSource {}
extension WriteTransaction: RecordSource {}

public struct MemoirEntry<Record: Sendable & Equatable>: Sendable, Equatable {
  public let record: Record
  public let isRemoved: Bool

  public init(record: Record, isRemoved: Bool) {
    self.record = record
    self.isRemoved = isRemoved
  }
}

public enum MemoirReading<Entry: Sendable & Equatable>: Sendable, Equatable {
  case absent
  case readable(Entry)
  case unreadable(MemoirUnreadable)

  public var entry: Entry? {
    guard case .readable(let entry) = self else { return nil }
    return entry
  }
}

public struct MemoirListing<Entry: Sendable & Equatable>: Sendable, Equatable {
  public let entries: [Entry]
  public let unreadable: Int

  public init(entries: [Entry], unreadable: Int) {
    self.entries = entries
    self.unreadable = unreadable
  }
}

/// A record-shaped kind written through `create`, `edit` and, where the kind declares it, `remove` and `restore`; never through raw fields.
public protocol MemoirRecord: Sendable, Equatable {
  associatedtype Field: MemoirField

  static var kind: MemoirKind { get }

  var ref: EntityRef { get }
  var members: RecordMembers<Field> { get }
  var identityMembers: [String: JSONValue] { get }
  var body: JSONValue? { get }

  init(ref: EntityRef, reading reader: MemberReader<Field>) throws(MemoirUnreadable)
}

public protocol RecordIdentifier: Hashable, Sendable, StoredValue {
  var recordUUID: UUID { get }

  init(recordUUID: UUID)
}

extension UUID: RecordIdentifier {
  public var recordUUID: UUID { self }

  public init(recordUUID: UUID) {
    self = recordUUID
  }
}

public protocol IdentifiedRecord: MemoirRecord {
  associatedtype Identifier: RecordIdentifier

  var id: Identifier { get }

  init(id: Identifier, reading reader: MemberReader<Field>) throws(MemoirUnreadable)
}

public protocol NaturalKeyRecord: MemoirRecord {
  var key: MemoirKey { get }

  init(key: MemoirKey, reading reader: MemberReader<Field>) throws(MemoirUnreadable)
}

public protocol RemovableMemoirRecord: MemoirRecord {}

extension MemoirRecord {
  public var body: JSONValue? { nil }

  public static func reading(_ state: EntityState?, of ref: EntityRef) -> MemoirReading<MemoirEntry<Self>> {
    let reader: MemberReader<Field>
    switch state {
    case nil, .purged:
      return .absent
    case .record(let record):
      reader = MemberReader(record.fields.mapValues(\.value))
    case .revisioned(let document):
      reader = MemberReader(document.fields.mapValues(\.value), body: document.headRevision.flatMap { document.revisions[ExactString($0)]?.body })
    case .appended:
      return .unreadable(.wrongShape)
    }
    do throws(MemoirUnreadable) {
      let removed = try removal(in: reader)
      return .readable(MemoirEntry(record: try Self(ref: ref, reading: reader), isRemoved: removed))
    } catch {
      return .unreadable(error)
    }
  }

  public static func read<Source: RecordSource & ~Copyable>(_ ref: EntityRef, in source: borrowing Source) throws(StoreError) -> MemoirReading<MemoirEntry<Self>> {
    reading(try source.state(of: ref, scope: .vault), of: ref)
  }

  public static func listing<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(StoreError) -> MemoirListing<MemoirEntry<Self>> {
    var entries = [MemoirEntry<Self>]()
    var unreadable = 0
    for (ref, state) in try source.states(ofKind: kind.entityKind, scope: .vault) {
      switch reading(state, of: ref) {
      case .absent: continue
      case .readable(let entry): entries.append(entry)
      case .unreadable: unreadable += 1
      }
    }
    return MemoirListing(entries: entries.sorted { $0.record.ref < $1.record.ref }, unreadable: unreadable)
  }

  @discardableResult
  public func create(in transaction: inout WriteTransaction) throws(MemoirRecordError) -> [ChangeRecord] {
    do throws(StoreError) {
      var changes = [try transaction.set(ref, storedMembers)]
      if let body { changes.append(try transaction.revise(ref, body: body).record) }
      return changes
    } catch {
      throw .store(error)
    }
  }

  /// Writes only the members `change` altered; a first-writer field that already holds a value cannot be altered.
  @discardableResult
  public static func edit(_ ref: EntityRef, in transaction: inout WriteTransaction, _ change: (inout Self) throws(MemoirRecordError) -> Void) throws(MemoirRecordError)
    -> [ChangeRecord]
  {
    let current = try present(ref, in: transaction).record
    var updated = current
    try change(&updated)
    guard updated.ref == ref else { throw .identityChanged(ref) }
    let before = current.members.values
    let after = updated.members.values
    var fields = [String: JSONValue]()
    for field in Field.allCases {
      let old = before[field.rawValue]
      let new = after[field.rawValue]
      guard !sameJSON(old, new) else { continue }
      if old != nil, MemoirSchema.rule(of: kind, field: field.rawValue) == .firstWriterWins { throw .firstWriterField(kind: kind.rawValue, field: field.rawValue) }
      fields[field.rawValue] = new ?? .null
    }
    do throws(StoreError) {
      var changes = [ChangeRecord]()
      if !fields.isEmpty { changes.append(try transaction.set(ref, fields)) }
      if let body = updated.body, !sameJSON(current.body, body) { changes.append(try transaction.revise(ref, body: body).record) }
      return changes
    } catch {
      throw .store(error)
    }
  }

  var storedMembers: [String: JSONValue] {
    var values = members.values.merging(identityMembers) { $1 }
    if MemoirSchema.isRemovable(Self.kind) { values[CommonField.removed.rawValue] = .bool(false) }
    return values
  }

  static func present(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(MemoirRecordError) -> MemoirEntry<Self> {
    let reading: MemoirReading<MemoirEntry<Self>>
    do throws(StoreError) {
      reading = try read(ref, in: transaction)
    } catch {
      throw .store(error)
    }
    switch reading {
    case .absent: throw .absent(ref)
    case .unreadable(let reason): throw .unreadable(ref, reason)
    case .readable(let entry): return entry
    }
  }

  private static func removal(in reader: MemberReader<Field>) throws(MemoirUnreadable) -> Bool {
    guard let json = reader.common(.removed), !json.isNull else { return false }
    guard let flag = json.boolValue else { throw .invalid(field: CommonField.removed.rawValue) }
    return flag
  }
}

extension RemovableMemoirRecord {
  @discardableResult
  public static func remove(_ ref: EntityRef, in transaction: inout WriteTransaction) throws(MemoirRecordError) -> ChangeRecord {
    _ = try present(ref, in: transaction)
    do throws(StoreError) {
      return try transaction.set(ref, [CommonField.removed.rawValue: .bool(true)])
    } catch {
      throw .store(error)
    }
  }

  @discardableResult
  public static func restore(_ ref: EntityRef, in transaction: inout WriteTransaction) throws(MemoirRecordError) -> ChangeRecord {
    _ = try present(ref, in: transaction)
    do throws(StoreError) {
      return try transaction.set(ref, [CommonField.removed.rawValue: .bool(false)])
    } catch {
      throw .store(error)
    }
  }
}

extension IdentifiedRecord {
  public static func ref(_ id: Identifier) -> EntityRef { EntityRef(kind: kind.entityKind, key: EntityKey(uuid: id.recordUUID)) }

  public var ref: EntityRef { Self.ref(id) }
  public var identityMembers: [String: JSONValue] { [:] }

  public init(ref: EntityRef, reading reader: MemberReader<Field>) throws(MemoirUnreadable) {
    guard ref.kind == Self.kind.entityKind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { throw .identity(ref) }
    try self.init(id: Identifier(recordUUID: id), reading: reader)
  }

  public static func read<Source: RecordSource & ~Copyable>(id: Identifier, in source: borrowing Source) throws(StoreError) -> MemoirReading<MemoirEntry<Self>> {
    try read(ref(id), in: source)
  }

  @discardableResult
  public static func edit(id: Identifier, in transaction: inout WriteTransaction, _ change: (inout Self) throws(MemoirRecordError) -> Void) throws(MemoirRecordError)
    -> [ChangeRecord]
  {
    try edit(ref(id), in: &transaction, change)
  }
}

extension NaturalKeyRecord {
  public var ref: EntityRef { key.ref }
  public var identityMembers: [String: JSONValue] { [CommonField.naturalKey.rawValue: key.stored] }

  public init(ref: EntityRef, reading reader: MemberReader<Field>) throws(MemoirUnreadable) {
    guard ref.kind == Self.kind.entityKind else { throw .identity(ref) }
    guard let stored = reader.common(.naturalKey) else { throw .missing(field: CommonField.naturalKey.rawValue) }
    try self.init(key: try MemoirKey(stored: stored, of: ref), reading: reader)
  }

  public static func read<Source: RecordSource & ~Copyable>(key: MemoirKey, in source: borrowing Source) throws(StoreError) -> MemoirReading<MemoirEntry<Self>> {
    try read(key.ref, in: source)
  }
}

func sameJSON(_ first: JSONValue?, _ second: JSONValue?) -> Bool {
  switch (first, second) {
  case (nil, nil): true
  case (let first?, let second?): CanonicalJSON.encode(first) == CanonicalJSON.encode(second)
  default: false
  }
}
