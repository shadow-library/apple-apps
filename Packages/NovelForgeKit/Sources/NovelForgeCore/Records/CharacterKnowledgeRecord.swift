import Foundation
import ShadowCore
import ShadowStore

extension CharacterKnowledgeField: FieldName {}
extension ManualRevealMember: FieldName {}

// apps/novel-forge-server/src/modules/bible/fact/fact.service.ts:119
public struct ManualReveal: Sendable, Equatable {
  public var chapter: Int
  public var note: String?
  public private(set) var unrecognised: [String: JSONValue]

  public init(chapter: Int, note: String? = nil) {
    self.chapter = chapter
    self.note = note
    unrecognised = [:]
  }
}

extension ManualReveal: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ManualRevealMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(chapter: try reader.required(.chapter), note: try reader.optional(.note))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ManualRevealMember>()
    fields.put(.chapter, chapter)
    fields.put(.note, note)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:180; only the author's manual reveals live here, and a removal is a retraction
public struct CharacterKnowledgeRecord: RemovableRecord {
  public static let kind = NovelForgeKind.characterKnowledge

  public let key: NovelForgeKey
  public let fact: String
  public let entity: String
  public var reveal: ManualReveal

  public init(novel: UUID, fact: String, entity: String, reveal: ManualReveal) {
    let fact = fact.precomposedStringWithCanonicalMapping
    let entity = entity.precomposedStringWithCanonicalMapping
    self.fact = fact
    self.entity = entity
    key = .characterKnowledgeKey(novel: novel, fact: fact, entity: entity)
    self.reveal = reveal
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<CharacterKnowledgeField>) throws(UnreadableReason) {
    guard case .characterKnowledge(let fact, let entity) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(novel: key.novel, fact: fact, entity: entity, reveal: try reader.required(.reveal))
  }

  public var fields: RecordFields<CharacterKnowledgeField> {
    var fields = RecordFields<CharacterKnowledgeField>()
    fields.put(.reveal, reveal)
    return fields
  }

  public var secretRef: EntityRef { NovelForgeKey.secret(novel: novel, key: fact) }
  public var entityRef: EntityRef { NovelForgeKey.entity(novel: novel, key: entity) }
}

public struct CharacterKnowledgeEdit: Sendable, Equatable {
  public var reveal: FieldChange<ManualReveal> = .keep

  public init() {}

  public var fields: RecordFields<CharacterKnowledgeField> {
    var fields = RecordFields<CharacterKnowledgeField>()
    fields.put(.reveal, reveal)
    return fields
  }
}

extension CharacterKnowledgeRecord {
  public static func ref(novel: UUID, fact: String, entity: String) -> EntityRef { NovelForgeKey.characterKnowledge(novel: novel, fact: fact, entity: entity) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, fact: String, entity: String, in transaction: borrowing Transaction) throws(StoreError)
    -> RecordReading<CharacterKnowledgeRecord>
  {
    try read(ref(novel: novel, fact: fact, entity: entity), in: transaction)
  }

  public static func edit(novel: UUID, fact: String, entity: String, _ changes: CharacterKnowledgeEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, fact: fact, entity: entity), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, fact: String, entity: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, fact: fact, entity: entity), in: &transaction)
  }

  public static func visible(
    in knowledge: RecordListing<CharacterKnowledgeRecord>, secrets: RecordListing<SecretRecord>, entities: RecordListing<EntityRecord>
  ) -> [CharacterKnowledgeRecord] {
    let liveSecrets = Set(secrets.live.map(\.ref))
    let liveEntities = Set(entities.live.map(\.ref))
    return knowledge.live.filter { liveSecrets.contains($0.secretRef) && liveEntities.contains($0.entityRef) }
  }

  public static func visible<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> [CharacterKnowledgeRecord] {
    visible(
      in: try listing(novel: novel, in: transaction), secrets: try SecretRecord.listing(novel: novel, in: transaction),
      entities: try EntityRecord.listing(novel: novel, in: transaction))
  }
}
