import Foundation
import ShadowCore
import ShadowStore

extension SecretField: FieldName {}
extension CluesAndTermsMember: FieldName {}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:162,170 judges the clues against the terms
public struct CluesAndTerms: Sendable, Equatable {
  public var clues: [String]?
  public var terms: [String]?
  public private(set) var unrecognised: [String: JSONValue]

  public init(clues: [String]? = nil, terms: [String]? = nil) {
    self.clues = clues
    self.terms = terms
    unrecognised = [:]
  }
}

extension CluesAndTerms: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<CluesAndTermsMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(clues: try reader.optional(.clues), terms: try reader.optional(.terms))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<CluesAndTermsMember>()
    fields.put(.clues, clues)
    fields.put(.terms, terms)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:150
public struct SecretRecord: RemovableRecord {
  public static let kind = NovelForgeKind.secret

  public let key: NovelForgeKey
  public let secret: String
  public var text: String
  public var subjects: [String]?
  public var constraintNote: String?
  public var writerNote: String?
  public var cluesAndTerms: CluesAndTerms?
  public var revealChapter: Int?
  public var unlock: JSONValue?
  public var source: StoredEnum<FactSource>

  public init(
    novel: UUID, secret: String, text: String, subjects: [String]? = nil, constraintNote: String? = nil, writerNote: String? = nil, cluesAndTerms: CluesAndTerms? = nil,
    revealChapter: Int? = nil, unlock: JSONValue? = nil, source: StoredEnum<FactSource> = .known(.manual)
  ) {
    let secret = secret.precomposedStringWithCanonicalMapping
    self.secret = secret
    key = .secretKey(novel: novel, secret: secret)
    self.text = text
    self.subjects = subjects
    self.constraintNote = constraintNote
    self.writerNote = writerNote
    self.cluesAndTerms = cluesAndTerms
    self.revealChapter = revealChapter
    self.unlock = unlock
    self.source = source
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<SecretField>) throws(UnreadableReason) {
    guard case .secret(let secret) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(
      novel: key.novel, secret: secret, text: try reader.required(.text), subjects: try reader.optional(.subjects), constraintNote: try reader.optional(.constraintNote),
      writerNote: try reader.optional(.writerNote), cluesAndTerms: try reader.optional(.cluesAndTerms), revealChapter: try reader.optional(.revealChapter),
      unlock: try reader.optional(.unlock), source: try reader.required(.source))
  }

  public var fields: RecordFields<SecretField> {
    var fields = RecordFields<SecretField>()
    fields.put(.text, text)
    fields.put(.subjects, subjects)
    fields.put(.constraintNote, constraintNote)
    fields.put(.writerNote, writerNote)
    fields.put(.cluesAndTerms, cluesAndTerms)
    fields.put(.revealChapter, revealChapter)
    fields.put(.unlock, unlock)
    fields.put(.source, source)
    return fields
  }
}

public struct SecretEdit: Sendable, Equatable {
  public var text: FieldChange<String> = .keep
  public var subjects: FieldChange<[String]?> = .keep
  public var constraintNote: FieldChange<String?> = .keep
  public var writerNote: FieldChange<String?> = .keep
  public var cluesAndTerms: FieldChange<CluesAndTerms?> = .keep
  public var revealChapter: FieldChange<Int?> = .keep
  public var unlock: FieldChange<JSONValue?> = .keep
  public var source: FieldChange<StoredEnum<FactSource>> = .keep

  public init() {}

  public var fields: RecordFields<SecretField> {
    var fields = RecordFields<SecretField>()
    fields.put(.text, text)
    fields.put(.subjects, subjects)
    fields.put(.constraintNote, constraintNote)
    fields.put(.writerNote, writerNote)
    fields.put(.cluesAndTerms, cluesAndTerms)
    fields.put(.revealChapter, revealChapter)
    fields.put(.unlock, unlock)
    fields.put(.source, source)
    return fields
  }
}

extension SecretRecord {
  public static func ref(novel: UUID, secret: String) -> EntityRef { NovelForgeKey.secret(novel: novel, key: secret) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, secret: String, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<
    SecretRecord
  > {
    try read(ref(novel: novel, secret: secret), in: transaction)
  }

  public static func edit(novel: UUID, secret: String, _ changes: SecretEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, secret: secret), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, secret: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, secret: secret), in: &transaction)
  }
}
