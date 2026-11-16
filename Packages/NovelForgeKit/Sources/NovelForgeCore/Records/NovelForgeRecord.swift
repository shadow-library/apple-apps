import Foundation
import ShadowCore
import ShadowStore

public protocol NovelForgeRecord: Sendable, Equatable {
  associatedtype Field: FieldName

  static var kind: NovelForgeKind { get }

  var novel: UUID { get }
  var ref: EntityRef { get }
  var fields: RecordFields<Field> { get }
  var storedMembers: [String: JSONValue] { get }

  init(ref: EntityRef, reading reader: FieldReader<Field>) throws(UnreadableReason)

  static func removal(in reader: FieldReader<Field>) throws(UnreadableReason) -> Bool
  static func owner(of ref: EntityRef, in reader: FieldReader<Field>) -> UUID?
}

extension NovelForgeRecord {
  public var storedMembers: [String: JSONValue] { fields.members }

  public static func removal(in reader: FieldReader<Field>) throws(UnreadableReason) -> Bool { false }

  public static func owner(of ref: EntityRef, in reader: FieldReader<Field>) -> UUID? { nil }
}

public protocol RemovableRecord: NovelForgeRecord {
  var key: NovelForgeKey { get }

  init(key: NovelForgeKey, reading reader: FieldReader<Field>) throws(UnreadableReason)
}

extension RemovableRecord {
  public var novel: UUID { key.novel }
  public var ref: EntityRef { key.ref }

  public var storedMembers: [String: JSONValue] {
    var members = fields.members
    members[CommonField.naturalKey.rawValue] = key.stored
    members[CommonField.removed.rawValue] = .bool(false)
    return members
  }

  public init(ref: EntityRef, reading reader: FieldReader<Field>) throws(UnreadableReason) {
    guard let stored = reader.stored(.naturalKey) else { throw .missing(field: CommonField.naturalKey.rawValue) }
    try self.init(key: try Self.naturalKey(stored, of: ref), reading: reader)
  }

  public static func removal(in reader: FieldReader<Field>) throws(UnreadableReason) -> Bool {
    try reader.common(.removed)
  }

  public static func owner(of ref: EntityRef, in reader: FieldReader<Field>) -> UUID? {
    guard let stored = reader.stored(.naturalKey) else { return nil }
    return try? Self.naturalKey(stored, of: ref).novel
  }

  private static func naturalKey(_ stored: JSONValue, of ref: EntityRef) throws(UnreadableReason) -> NovelForgeKey {
    do throws(NovelForgeKeyError) {
      return try NovelForgeKey(stored: stored, of: ref)
    } catch {
      throw .naturalKey(error)
    }
  }
}
