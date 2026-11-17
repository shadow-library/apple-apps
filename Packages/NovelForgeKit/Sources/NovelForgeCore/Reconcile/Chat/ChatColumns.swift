import Foundation
import GRDB
import ShadowCore
import ShadowStore

enum ChatColumns {
  static func id(of ref: EntityRef, _ kind: NovelForgeKind) -> UUID? {
    guard NovelForgeKind(ref.kind) == kind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { return nil }
    return id
  }

  static func key(_ row: Row, _ column: String) throws -> EntityKey {
    guard let key = EntityKey(try row.decode(String.self, forColumn: column)) else { throw StoreError.corruptStore("a chat row holds an invalid key in \(column)") }
    return key
  }

  static func optionalKey(_ row: Row, _ column: String) throws -> EntityKey? {
    guard let text = try row.decode(String?.self, forColumn: column) else { return nil }
    guard let key = EntityKey(text) else { throw StoreError.corruptStore("a chat row holds an invalid key in \(column)") }
    return key
  }

  static func clock(_ row: Row, _ column: String) throws -> HLCTimestamp {
    guard let clock = try optionalClock(row, column) else { throw StoreError.corruptStore("a chat row holds no clock in \(column)") }
    return clock
  }

  static func optionalClock(_ row: Row, _ column: String) throws -> HLCTimestamp? {
    guard let text = try row.decode(String?.self, forColumn: column) else { return nil }
    guard let clock = HLCTimestamp(text) else { throw StoreError.corruptStore("a chat row holds an invalid clock in \(column)") }
    return clock
  }

  static func stored<Value>(_ row: Row, _ column: String) throws -> StoredEnum<Value>? {
    try row.decode(String?.self, forColumn: column).map(StoredEnum.init(rawValue:))
  }

  /// A member as an enum: absent or null is nil, a value that is not text reads as an unknown value, never as a known one.
  static func stored<Value>(_ member: JSONValue?) -> StoredEnum<Value>? {
    guard let member, !member.isNull else { return nil }
    return member.stringValue.map(StoredEnum.init(rawValue:)) ?? .unknown("")
  }

  /// Chronological order of appended items: clock, then ref, as `AppendedRecord.chronologically`.
  static func precedes(_ first: (clock: HLCTimestamp, ref: EntityRef), _ second: (clock: HLCTimestamp, ref: EntityRef)) -> Bool {
    guard first.clock == second.clock else { return first.clock < second.clock }
    return first.ref < second.ref
  }
}
