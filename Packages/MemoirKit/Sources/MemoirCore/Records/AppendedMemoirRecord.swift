import Foundation
import ShadowCore
import ShadowStore

public struct AppendedEntry<Record: Sendable & Equatable>: Sendable, Equatable {
  public let record: Record
  public let clock: HLCTimestamp

  public init(record: Record, clock: HLCTimestamp) {
    self.record = record
    self.clock = clock
  }
}

/// An immutable item under its id. Appending the same item again does nothing; a different item under the same id is refused.
public protocol AppendedMemoirRecord: Sendable, Equatable {
  associatedtype Member: MemoirField

  static var kind: MemoirKind { get }

  var id: UUID { get }
  var members: RecordMembers<Member> { get }

  init(id: UUID, reading reader: MemberReader<Member>) throws(MemoirUnreadable)
}

extension AppendedMemoirRecord {
  public static func ref(_ id: UUID) -> EntityRef { EntityRef(kind: kind.entityKind, key: EntityKey(uuid: id)) }

  public var ref: EntityRef { Self.ref(id) }

  /// `nil` when the store already holds this exact item.
  @discardableResult
  public func append(in transaction: inout WriteTransaction) throws(MemoirRecordError) -> ChangeRecord? {
    let item = members.values
    let existing: EntityState?
    do throws(StoreError) {
      existing = try transaction.state(of: ref, scope: .vault)
    } catch {
      throw .store(error)
    }
    switch existing {
    case nil:
      do throws(StoreError) {
        return try transaction.append(ref, item: item)
      } catch {
        throw .store(error)
      }
    case .appended(let stored):
      guard sameJSON(.object(stored.item), .object(item)) else { throw .conflictingItem(ref) }
      return nil
    case .purged:
      throw .store(.entityPurged(ref))
    case .record, .revisioned:
      throw .conflictingItem(ref)
    }
  }

  public static func reading(_ state: EntityState?, of ref: EntityRef) -> MemoirReading<AppendedEntry<Self>> {
    guard let state else { return .absent }
    if case .purged = state { return .absent }
    guard ref.kind == kind.entityKind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { return .unreadable(.identity(ref)) }
    guard case .appended(let appended) = state, let reader = MemberReader<Member>(object: .object(appended.item)) else { return .unreadable(.wrongShape) }
    do throws(MemoirUnreadable) {
      try reader.requireOnlyDeclaredMembers()
      return .readable(AppendedEntry(record: try Self(id: id, reading: reader), clock: appended.clock))
    } catch {
      return .unreadable(error)
    }
  }

  public static func read<Source: RecordSource & ~Copyable>(id: UUID, in source: borrowing Source) throws(StoreError) -> MemoirReading<AppendedEntry<Self>> {
    let ref = ref(id)
    return reading(try source.state(of: ref, scope: .vault), of: ref)
  }

  public static func listing<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(StoreError) -> MemoirListing<AppendedEntry<Self>> {
    var entries = [AppendedEntry<Self>]()
    var unreadable = 0
    for (ref, state) in try source.states(ofKind: kind.entityKind, scope: .vault) {
      switch reading(state, of: ref) {
      case .absent: continue
      case .readable(let entry): entries.append(entry)
      case .unreadable: unreadable += 1
      }
    }
    let ordered = entries.sorted { first, second in
      guard first.clock == second.clock else { return first.clock < second.clock }
      return first.record.ref < second.record.ref
    }
    return MemoirListing(entries: ordered, unreadable: unreadable)
  }
}
