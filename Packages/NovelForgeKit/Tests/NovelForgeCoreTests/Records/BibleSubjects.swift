import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

extension Gen {
  static func optionalStored<Value: RawRepresentable & CaseIterable & Hashable & Sendable>(_ generator: inout SeededGenerator) -> StoredEnum<Value>?
  where Value.RawValue == String {
    generator.chance(0.35) ? nil : stored(&generator)
  }

  static func texts(_ generator: inout SeededGenerator) -> [String] {
    (0..<generator.int(in: 0...3)).map { _ in text(&generator) }
  }

  static func optionalTexts(_ generator: inout SeededGenerator) -> [String]? {
    generator.chance(0.35) ? nil : texts(&generator)
  }

  static func cluesAndTerms(_ generator: inout SeededGenerator) -> CluesAndTerms? {
    generator.chance(0.35) ? nil : CluesAndTerms(clues: optionalTexts(&generator), terms: optionalTexts(&generator))
  }

  static func optionalJSON(_ generator: inout SeededGenerator) -> JSONValue? {
    switch generator.int(in: 0...3) {
    case 0: nil
    case 1: .object(["note": .string(text(&generator)), "level": .int(Int64(int(&generator)))])
    case 2: .array([.string(text(&generator)), .null])
    default: .string(text(&generator))
    }
  }

  static func unlock(_ generator: inout SeededGenerator) -> JSONValue? {
    generator.chance(0.4) ? nil : .object(["all": .array([.object(["chapter": .int(Int64(generator.int(in: 1...90)))]), .object(["ending": .bool(true)])])])
  }

  static func reveal(_ generator: inout SeededGenerator) -> ManualReveal {
    ManualReveal(chapter: generator.int(in: 1...90), note: optionalText(&generator))
  }
}

struct SecretSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "text", "source"]
  static let groupMember: String? = "clues_and_terms"
  static let unknownEnum: (member: String, value: JSONValue)? = ("source", "x_oracle")

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> SecretRecord {
    SecretRecord(
      novel: novel, secret: key, text: Gen.text(&generator), subjects: Gen.optionalTexts(&generator), constraintNote: Gen.optionalText(&generator),
      writerNote: Gen.optionalText(&generator), cluesAndTerms: Gen.cluesAndTerms(&generator), revealChapter: Gen.optionalInt(&generator), unlock: Gen.unlock(&generator),
      source: Gen.stored(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: SecretRecord) -> SubjectEdit<SecretRecord> {
    var draft = EditDraft<SecretEdit, SecretRecord>(SecretEdit())
    repeat {
      draft = EditDraft(SecretEdit())
      draft.maybe(&generator, "text", edit: \.text, record: \.text, Gen.text)
      draft.maybe(&generator, "subjects", edit: \.subjects, record: \.subjects, Gen.optionalTexts)
      draft.maybe(&generator, "constraint_note", edit: \.constraintNote, record: \.constraintNote, Gen.optionalText)
      draft.maybe(&generator, "writer_note", edit: \.writerNote, record: \.writerNote, Gen.optionalText)
      draft.maybe(&generator, "clues_and_terms", edit: \.cluesAndTerms, record: \.cluesAndTerms, Gen.cluesAndTerms)
      draft.maybe(&generator, "reveal_chapter", edit: \.revealChapter, record: \.revealChapter, Gen.optionalInt)
      draft.maybe(&generator, "unlock", edit: \.unlock, record: \.unlock, Gen.unlock)
      draft.maybe(&generator, "source", edit: \.source, record: \.source, Gen.stored)
    } while draft.members.isEmpty
    let (novel, secret) = (record.novel, record.secret)
    return draft.subject { edit, transaction throws(StoreError) in try SecretRecord.edit(novel: novel, secret: secret, edit, in: &transaction) }
  }
}

struct EntitySubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "type", "name", "wiki_visibility"]
  static let groupMember: String? = nil
  static let unknownEnum: (member: String, value: JSONValue)? = ("type", "x_vehicle")

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> EntityRecord {
    EntityRecord(
      novel: novel, entity: key, type: Gen.stored(&generator), name: Gen.text(&generator), attributes: Gen.optionalJSON(&generator),
      significance: Gen.optionalStored(&generator), status: Gen.optionalText(&generator), origin: Gen.optionalStored(&generator), notes: Gen.optionalText(&generator),
      motivation: Gen.optionalText(&generator), body: Gen.optionalText(&generator), appearance: Gen.optionalText(&generator), wikiVisibility: Gen.stored(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: EntityRecord) -> SubjectEdit<EntityRecord> {
    var draft = EditDraft<EntityEdit, EntityRecord>(EntityEdit())
    repeat {
      draft = EditDraft(EntityEdit())
      draft.maybe(&generator, "type", edit: \.type, record: \.type, Gen.stored)
      draft.maybe(&generator, "name", edit: \.name, record: \.name, Gen.text)
      draft.maybe(&generator, "attributes", edit: \.attributes, record: \.attributes, Gen.optionalJSON)
      draft.maybe(&generator, "significance", edit: \.significance, record: \.significance, Gen.optionalStored)
      draft.maybe(&generator, "status", edit: \.status, record: \.status, Gen.optionalText)
      draft.maybe(&generator, "origin", edit: \.origin, record: \.origin, Gen.optionalStored)
      draft.maybe(&generator, "notes", edit: \.notes, record: \.notes, Gen.optionalText)
      draft.maybe(&generator, "motivation", edit: \.motivation, record: \.motivation, Gen.optionalText)
      draft.maybe(&generator, "body", edit: \.body, record: \.body, Gen.optionalText)
      draft.maybe(&generator, "appearance", edit: \.appearance, record: \.appearance, Gen.optionalText)
      draft.maybe(&generator, "wiki_visibility", edit: \.wikiVisibility, record: \.wikiVisibility, Gen.stored)
    } while draft.members.isEmpty
    let (novel, entity) = (record.novel, record.entity)
    return draft.subject { edit, transaction throws(StoreError) in try EntityRecord.edit(novel: novel, entity: entity, edit, in: &transaction) }
  }
}

struct CharacterKnowledgeSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "reveal"]
  static let groupMember: String? = "reveal"
  static let unknownEnum: (member: String, value: JSONValue)? = nil

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> CharacterKnowledgeRecord {
    CharacterKnowledgeRecord(novel: novel, fact: key, entity: "entity-" + key, reveal: Gen.reveal(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: CharacterKnowledgeRecord) -> SubjectEdit<CharacterKnowledgeRecord> {
    var draft = EditDraft<CharacterKnowledgeEdit, CharacterKnowledgeRecord>(CharacterKnowledgeEdit())
    repeat {
      draft = EditDraft(CharacterKnowledgeEdit())
      draft.maybe(&generator, "reveal", edit: \.reveal, record: \.reveal, Gen.reveal)
    } while draft.members.isEmpty
    let (novel, fact, entity) = (record.novel, record.fact, record.entity)
    return draft.subject { edit, transaction throws(StoreError) in try CharacterKnowledgeRecord.edit(novel: novel, fact: fact, entity: entity, edit, in: &transaction) }
  }
}
