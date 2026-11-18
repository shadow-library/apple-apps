import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/database/schemas/projects.ts:44
public enum CostTier: String, CaseIterable, Codable, Sendable {
  case economy
  case balanced
  case performant
}

// apps/novel-forge-server/src/database/schemas/projects.ts:26
public struct WordTarget: Sendable, Equatable {
  public var min: Int
  public var max: Int

  public init(min: Int, max: Int) {
    self.min = min
    self.max = max
  }
}

extension WordTarget: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<WordTargetMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(min: try reader.required(.min), max: try reader.required(.max))
    } catch {
      return nil
    }
  }

  public var json: JSONValue {
    var fields = RecordFields<WordTargetMember>()
    fields.put(.min, min)
    fields.put(.max, max)
    return fields.json
  }
}

extension WordTargetMember: FieldName {}
extension NovelField: FieldName {}

public struct NovelRecord: NovelForgeRecord {
  public static let kind = NovelForgeKind.novel

  public let id: UUID
  public var name: String
  public var title: String?
  public var contentMode: StoredEnum<ContentMode>
  public var costTier: StoredEnum<CostTier>
  public var wordTarget: WordTarget?
  public var brief: String?
  public var premise: String?
  public var themes: [String]?
  public var theme: String?
  public var endingQuestion: String?
  public var ending: String?
  public var readerPromise: String?
  public var protagonist: String?
  public var opposition: String?
  public var writingStyle: String?
  public var archived: Bool
  public var autoKeep: [StoredEnum<FinalizeCategory>]?

  public init(
    id: UUID, name: String, title: String? = nil, contentMode: StoredEnum<ContentMode> = .known(.standard), costTier: StoredEnum<CostTier> = .known(.balanced),
    wordTarget: WordTarget? = nil, brief: String? = nil, premise: String? = nil, themes: [String]? = nil, theme: String? = nil, endingQuestion: String? = nil,
    ending: String? = nil, readerPromise: String? = nil, protagonist: String? = nil, opposition: String? = nil, writingStyle: String? = nil, archived: Bool = false,
    autoKeep: [StoredEnum<FinalizeCategory>]? = nil
  ) {
    self.id = id
    self.name = name
    self.title = title
    self.contentMode = contentMode
    self.costTier = costTier
    self.wordTarget = wordTarget
    self.brief = brief
    self.premise = premise
    self.themes = themes
    self.theme = theme
    self.endingQuestion = endingQuestion
    self.ending = ending
    self.readerPromise = readerPromise
    self.protagonist = protagonist
    self.opposition = opposition
    self.writingStyle = writingStyle
    self.archived = archived
    self.autoKeep = autoKeep
  }

  public init(ref: EntityRef, reading reader: FieldReader<NovelField>) throws(UnreadableReason) {
    guard ref.kind == Self.kind.entityKind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { throw .identity(ref) }
    self.init(
      id: id, name: try reader.required(.name), title: try reader.optional(.title), contentMode: try reader.required(.contentMode),
      costTier: try reader.required(.costTier), wordTarget: try reader.optional(.wordTarget), brief: try reader.optional(.brief), premise: try reader.optional(.premise),
      themes: try reader.optional(.themes), theme: try reader.optional(.theme), endingQuestion: try reader.optional(.endingQuestion),
      ending: try reader.optional(.ending), readerPromise: try reader.optional(.readerPromise), protagonist: try reader.optional(.protagonist),
      opposition: try reader.optional(.opposition), writingStyle: try reader.optional(.writingStyle), archived: try reader.required(.archived),
      autoKeep: try reader.optional(.autoKeep))
  }

  public var novel: UUID { id }

  public static func owner(of ref: EntityRef, in reader: FieldReader<NovelField>) -> UUID? {
    guard let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { return nil }
    return id
  }
  public var ref: EntityRef { NovelForgeKey.novel(id) }

  public var fields: RecordFields<NovelField> {
    var fields = RecordFields<NovelField>()
    fields.put(.name, name)
    fields.put(.title, title)
    fields.put(.contentMode, contentMode)
    fields.put(.costTier, costTier)
    fields.put(.wordTarget, wordTarget)
    fields.put(.brief, brief)
    fields.put(.premise, premise)
    fields.put(.themes, themes)
    fields.put(.theme, theme)
    fields.put(.endingQuestion, endingQuestion)
    fields.put(.ending, ending)
    fields.put(.readerPromise, readerPromise)
    fields.put(.protagonist, protagonist)
    fields.put(.opposition, opposition)
    fields.put(.writingStyle, writingStyle)
    fields.put(.archived, archived)
    fields.put(.autoKeep, autoKeep)
    return fields
  }
}

public struct NovelEdit: Sendable, Equatable {
  public var name: FieldChange<String> = .keep
  public var title: FieldChange<String?> = .keep
  public var contentMode: FieldChange<StoredEnum<ContentMode>> = .keep
  public var costTier: FieldChange<StoredEnum<CostTier>> = .keep
  public var wordTarget: FieldChange<WordTarget?> = .keep
  public var brief: FieldChange<String?> = .keep
  public var premise: FieldChange<String?> = .keep
  public var themes: FieldChange<[String]?> = .keep
  public var theme: FieldChange<String?> = .keep
  public var endingQuestion: FieldChange<String?> = .keep
  public var ending: FieldChange<String?> = .keep
  public var readerPromise: FieldChange<String?> = .keep
  public var protagonist: FieldChange<String?> = .keep
  public var opposition: FieldChange<String?> = .keep
  public var writingStyle: FieldChange<String?> = .keep
  public var archived: FieldChange<Bool> = .keep
  public var autoKeep: FieldChange<[StoredEnum<FinalizeCategory>]?> = .keep

  public init() {}

  public var fields: RecordFields<NovelField> {
    var fields = RecordFields<NovelField>()
    fields.put(.name, name)
    fields.put(.title, title)
    fields.put(.contentMode, contentMode)
    fields.put(.costTier, costTier)
    fields.put(.wordTarget, wordTarget)
    fields.put(.brief, brief)
    fields.put(.premise, premise)
    fields.put(.themes, themes)
    fields.put(.theme, theme)
    fields.put(.endingQuestion, endingQuestion)
    fields.put(.ending, ending)
    fields.put(.readerPromise, readerPromise)
    fields.put(.protagonist, protagonist)
    fields.put(.opposition, opposition)
    fields.put(.writingStyle, writingStyle)
    fields.put(.archived, archived)
    fields.put(.autoKeep, autoKeep)
    return fields
  }
}

extension NovelRecord {
  public static func edit(id: UUID, _ changes: NovelEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(NovelForgeKey.novel(id), changes.fields, in: &transaction)
  }

  public static func read<Transaction: StateReading & ~Copyable>(id: UUID, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<NovelRecord> {
    try read(NovelForgeKey.novel(id), in: transaction)
  }
}
