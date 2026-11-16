import ShadowStore

public enum NovelForgeSchema {
  public static let version = 1

  // apps/novel-forge-server/src/common/draft-history.ts:10
  static let revisionLimit = 50

  public static let entities: [EntitySchema] = [
    record(.novel, registers(NovelField.self)),
    removableRecord(.volume, registers(VolumeField.self)),
    removableRecord(.milestone, registers(MilestoneField.self)),
    removableRecord(.thread, registers(ThreadField.self)),
    removableRecord(.mystery, registers(MysteryField.self)),
    removableRecord(.secret, registers(SecretField.self)),
    removableRecord(.entity, registers(EntityField.self)),
    removableRecord(.characterKnowledge, registers(CharacterKnowledgeField.self)),
    document(.page, fields: removable([:])),
    document(.chapterPlan, fields: removable([:]), marks: ChapterPlanMark.allCases.map(\.rawValue)),
    document(.draft, fields: removable([:]), marks: DraftMark.allCases.map(\.rawValue)),
    appended(.approval),
    document(.finalChapter, fields: keyed([FinalChapterField.canon.rawValue: .firstWriterWins, FinalChapterField.summary.rawValue: .register])),
    appended(.notebookEntry),
    appended(.notebookWithdrawal),
    document(.authorNotes, fields: keyed([:])),
  ]

  private static func registers<Field: RawRepresentable & CaseIterable>(_: Field.Type) -> [String: FieldRule] where Field.RawValue == String {
    Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0.rawValue, FieldRule.register) })
  }

  private static func keyed(_ fields: [String: FieldRule]) -> [String: FieldRule] {
    fields.merging([CommonField.naturalKey.rawValue: .firstWriterWins]) { _, _ in preconditionFailure("natural_key is declared twice") }
  }

  private static func removable(_ fields: [String: FieldRule]) -> [String: FieldRule] {
    keyed(fields).merging([CommonField.removed.rawValue: .register]) { _, _ in preconditionFailure("removed is declared twice") }
  }

  private static func record(_ kind: NovelForgeKind, _ fields: [String: FieldRule]) -> EntitySchema {
    EntitySchema(kind: kind.entityKind, shape: .record(fields: fields), syncClass: .general)
  }

  private static func removableRecord(_ kind: NovelForgeKind, _ fields: [String: FieldRule]) -> EntitySchema {
    record(kind, removable(fields))
  }

  private static func document(_ kind: NovelForgeKind, fields: [String: FieldRule], marks: [String] = []) -> EntitySchema {
    EntitySchema(kind: kind.entityKind, shape: .revisioned(fields: fields, marks: marks, retention: .keepNewest(revisionLimit)), syncClass: .general)
  }

  private static func appended(_ kind: NovelForgeKind) -> EntitySchema {
    EntitySchema(kind: kind.entityKind, shape: .appended, syncClass: .general)
  }
}
