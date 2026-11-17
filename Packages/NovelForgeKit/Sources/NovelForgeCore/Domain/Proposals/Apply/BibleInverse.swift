import Foundation
import ShadowCore

/// A page as an inverse writes it back (bible-document.handler.ts:17): frontmatter and body exactly as they stood, an empty one `null`.
struct DocumentRestore: Sendable, Equatable {
  let section: BiblePageSection
  let slug: String
  let frontmatter: [String: JSONValue]?
  let body: String?

  init(_ content: PageContent, section: BiblePageSection, slug: String) {
    self.section = section
    self.slug = slug
    frontmatter = content.frontmatter
    body = content.body
  }

  fileprivate init(_ members: InverseMembers) throws(ApplyRefusal) {
    section = try members.required("section") { BiblePageSection(exactly: $0) }
    slug = try members.string("slug")
    frontmatter = try members.nullable("frontmatter", storableObject)
    body = try members.nullableString("body")
  }

  var json: OrderedJSONObject {
    inverseOp(
      .bibleDocumentUpsert,
      [("section", .string(section.rawValue)), ("slug", .string(slug)), ("frontmatter", frontmatter.map { OrderedJSON(.object($0)) } ?? .null), ("body", inverseText(body))])
  }

  // bible-document.handler.ts:16
  static func removal(section: BiblePageSection, slug: String) -> OrderedJSONObject {
    inverseOp(.bibleDocumentRemove, [("section", .string(section.rawValue)), ("slug", .string(slug))])
  }
}

/// An entity's authored fields as an inverse writes them back (entity.handler.ts:15): every one explicit, an empty one `null`.
struct EntityRestore: Sendable, Equatable {
  let entity: String
  let type: StoredEnum<EntityType>
  let name: String
  let status: String?
  let motivation: String?
  let notes: String?
  let body: String?

  init(_ record: EntityRecord, key: String) {
    entity = key
    type = record.type
    name = record.name
    status = record.status
    motivation = record.motivation
    notes = record.notes
    body = record.body
  }

  fileprivate init(_ members: InverseMembers) throws(ApplyRefusal) {
    entity = try members.string("entityKey")
    type = StoredEnum(rawValue: try members.string("type"))
    name = try members.string("name")
    status = try members.nullableString("status")
    motivation = try members.nullableString("motivation")
    notes = try members.nullableString("notes")
    body = try members.nullableString("body")
  }

  var json: OrderedJSONObject {
    inverseOp(
      .entityUpsert,
      [
        ("entityKey", .string(entity)), ("type", .string(type.rawValue)), ("name", .string(name)), ("status", inverseText(status)),
        ("motivation", inverseText(motivation)), ("notes", inverseText(notes)), ("body", inverseText(body)),
      ])
  }

  // entity.handler.ts:14
  static func removal(_ key: String) -> OrderedJSONObject {
    inverseOp(.entityRemove, [("entityKey", .string(key))])
  }
}

enum BibleRestore: Sendable, Equatable {
  case document(DocumentRestore)
  case documentRemoval(section: BiblePageSection, slug: String)
  case entity(EntityRestore)
  case entityRemoval(String)

  init(_ inverse: OrderedJSONObject) throws(ApplyRefusal) {
    let members = InverseMembers(inverse)
    switch members.type {
    case .bibleDocumentUpsert?: self = .document(try DocumentRestore(members))
    case .bibleDocumentRemove?:
      let section = try members.required("section") { BiblePageSection(exactly: $0) }
      self = .documentRemoval(section: section, slug: try members.string("slug"))
    case .entityUpsert?: self = .entity(try EntityRestore(members))
    case .entityRemove?: self = .entityRemoval(try members.string("entityKey"))
    default: throw .malformedInverse
    }
  }
}
