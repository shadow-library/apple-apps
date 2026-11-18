import Foundation
import ShadowCore
import ShadowStore

extension EntityField: FieldName {}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:39
public enum EntitySignificance: String, CaseIterable, Sendable {
  case major
  case minor
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:40
public enum EntityOrigin: String, CaseIterable, Sendable {
  case extracted
  case seeded
  case generated
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:53
public enum EntityWikiVisibility: String, CaseIterable, Sendable {
  case `default`
  case hidden
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:55
public struct EntityRecord: RemovableRecord {
  public static let kind = NovelForgeKind.entity

  public let key: NovelForgeKey
  public let entity: String
  public var type: StoredEnum<EntityType>
  public var name: String
  public var attributes: JSONValue?
  public var significance: StoredEnum<EntitySignificance>?
  public var status: String?
  public var origin: StoredEnum<EntityOrigin>?
  public var notes: String?
  public var motivation: String?
  public var body: String?
  public var appearance: String?
  public var wikiVisibility: StoredEnum<EntityWikiVisibility>
  public var age: Int?

  public init(
    novel: UUID, entity: String, type: StoredEnum<EntityType>, name: String, attributes: JSONValue? = nil, significance: StoredEnum<EntitySignificance>? = nil,
    status: String? = nil, origin: StoredEnum<EntityOrigin>? = nil, notes: String? = nil, motivation: String? = nil, body: String? = nil, appearance: String? = nil,
    wikiVisibility: StoredEnum<EntityWikiVisibility> = .known(.default), age: Int? = nil
  ) {
    let entity = entity.precomposedStringWithCanonicalMapping
    self.entity = entity
    key = .entityKey(novel: novel, entity: entity)
    self.type = type
    self.name = name
    self.attributes = attributes
    self.significance = significance
    self.status = status
    self.origin = origin
    self.notes = notes
    self.motivation = motivation
    self.body = body
    self.appearance = appearance
    self.wikiVisibility = wikiVisibility
    self.age = age
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<EntityField>) throws(UnreadableReason) {
    guard case .entity(let entity) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(
      novel: key.novel, entity: entity, type: try reader.required(.type), name: try reader.required(.name), attributes: try reader.optional(.attributes),
      significance: try reader.optional(.significance), status: try reader.optional(.status), origin: try reader.optional(.origin), notes: try reader.optional(.notes),
      motivation: try reader.optional(.motivation), body: try reader.optional(.body), appearance: try reader.optional(.appearance),
      wikiVisibility: try reader.required(.wikiVisibility), age: try reader.optional(.age))
  }

  public var fields: RecordFields<EntityField> {
    var fields = RecordFields<EntityField>()
    fields.put(.type, type)
    fields.put(.name, name)
    fields.put(.attributes, attributes)
    fields.put(.significance, significance)
    fields.put(.status, status)
    fields.put(.origin, origin)
    fields.put(.notes, notes)
    fields.put(.motivation, motivation)
    fields.put(.body, body)
    fields.put(.appearance, appearance)
    fields.put(.wikiVisibility, wikiVisibility)
    fields.put(.age, age)
    return fields
  }
}

public struct EntityEdit: Sendable, Equatable {
  public var type: FieldChange<StoredEnum<EntityType>> = .keep
  public var name: FieldChange<String> = .keep
  public var attributes: FieldChange<JSONValue?> = .keep
  public var significance: FieldChange<StoredEnum<EntitySignificance>?> = .keep
  public var status: FieldChange<String?> = .keep
  public var origin: FieldChange<StoredEnum<EntityOrigin>?> = .keep
  public var notes: FieldChange<String?> = .keep
  public var motivation: FieldChange<String?> = .keep
  public var body: FieldChange<String?> = .keep
  public var appearance: FieldChange<String?> = .keep
  public var wikiVisibility: FieldChange<StoredEnum<EntityWikiVisibility>> = .keep
  public var age: FieldChange<Int?> = .keep

  public init() {}

  public var fields: RecordFields<EntityField> {
    var fields = RecordFields<EntityField>()
    fields.put(.type, type)
    fields.put(.name, name)
    fields.put(.attributes, attributes)
    fields.put(.significance, significance)
    fields.put(.status, status)
    fields.put(.origin, origin)
    fields.put(.notes, notes)
    fields.put(.motivation, motivation)
    fields.put(.body, body)
    fields.put(.appearance, appearance)
    fields.put(.wikiVisibility, wikiVisibility)
    fields.put(.age, age)
    return fields
  }
}

extension EntityRecord {
  public static func ref(novel: UUID, entity: String) -> EntityRef { NovelForgeKey.entity(novel: novel, key: entity) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, entity: String, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<
    EntityRecord
  > {
    try read(ref(novel: novel, entity: entity), in: transaction)
  }

  public static func edit(novel: UUID, entity: String, _ changes: EntityEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, entity: entity), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, entity: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, entity: entity), in: &transaction)
  }
}
