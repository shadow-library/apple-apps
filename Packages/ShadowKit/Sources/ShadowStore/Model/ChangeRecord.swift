import Foundation
import ShadowCore

public enum ChangeKind: String, Sendable, Codable, CaseIterable {
  case set
  case purge
  case append
  case revise
}

public enum ChangeRecordError: ShadowError, Equatable {
  case notAnObject
  case missingMember(String)
  case unexpectedMember(String)
  case invalidMember(String)

  public var code: String {
    switch self {
    case .notAnObject: "change_record.not_an_object"
    case .missingMember: "change_record.missing_member"
    case .unexpectedMember: "change_record.unexpected_member"
    case .invalidMember: "change_record.invalid_member"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notAnObject: "Change record is not a JSON object."
    case .missingMember(let name): "Change record has no \"\(name)\" member."
    case .unexpectedMember(let name): "Change record has an unexpected \"\(name)\" member."
    case .invalidMember(let name): "Change record member \"\(name)\" is invalid."
    }
  }
}

public struct ChangeRecord: Hashable, Sendable {
  private static let memberNames = ["clock", "entity", "fields", "id", "key", "kind", "schema"]

  public let id: UUID
  public let clock: HLCTimestamp
  public let schema: Int
  public let entity: EntityKind
  public let key: EntityKey
  public let kind: ChangeKind
  public let fields: [String: JSONValue]

  public init(id: UUID, clock: HLCTimestamp, schema: Int, entity: EntityKind, key: EntityKey, kind: ChangeKind, fields: [String: JSONValue]) {
    self.id = id
    self.clock = clock
    self.schema = schema
    self.entity = entity
    self.key = key
    self.kind = kind
    self.fields = fields
  }

  public var ref: EntityRef { EntityRef(kind: entity, key: key) }

  public var json: JSONValue {
    .object([
      "clock": .string(clock.description),
      "entity": .string(entity.rawValue),
      "fields": .object(fields),
      "id": .string(id.uuidString.lowercased()),
      "key": .string(key.rawValue),
      "kind": .string(kind.rawValue),
      "schema": .int(Int64(schema)),
    ])
  }

  public init(json: JSONValue) throws(ChangeRecordError) {
    guard case .object(let members) = json else { throw .notAnObject }
    for name in members.keys where !Self.memberNames.contains(where: { $0.utf8.elementsEqual(name.utf8) }) { throw .unexpectedMember(name) }
    for name in Self.memberNames where members[name] == nil { throw .missingMember(name) }
    guard let idText = members["id"]?.stringValue, let id = Self.uuid(idText) else { throw .invalidMember("id") }
    guard let clockText = members["clock"]?.stringValue, let clock = HLCTimestamp(clockText) else { throw .invalidMember("clock") }
    guard let schema = members["schema"]?.intValue, let schemaValue = Int(exactly: schema), schemaValue >= 0 else { throw .invalidMember("schema") }
    guard let entityText = members["entity"]?.stringValue, let entity = EntityKind(entityText) else { throw .invalidMember("entity") }
    guard let keyText = members["key"]?.stringValue, let key = EntityKey(keyText) else { throw .invalidMember("key") }
    guard let kindText = members["kind"]?.stringValue, let kind = ChangeKind.allCases.first(where: { $0.rawValue.utf8.elementsEqual(kindText.utf8) }) else {
      throw .invalidMember("kind")
    }
    guard let fields = members["fields"]?.objectValue else { throw .invalidMember("fields") }
    self.init(id: id, clock: clock, schema: schemaValue, entity: entity, key: key, kind: kind, fields: fields)
  }

  public func canonicalBytes() -> Data {
    CanonicalJSON.encode(json)
  }

  public static func == (lhs: ChangeRecord, rhs: ChangeRecord) -> Bool {
    lhs.canonicalBytes() == rhs.canonicalBytes()
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(canonicalBytes())
  }

  private static func uuid(_ text: String) -> UUID? {
    let bytes = Array(text.utf8)
    guard bytes.count == 36 else { return nil }
    for (index, byte) in bytes.enumerated() {
      let valid = [8, 13, 18, 23].contains(index) ? byte == UInt8(ascii: "-") : (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
      guard valid else { return nil }
    }
    return UUID(uuidString: text)
  }
}
