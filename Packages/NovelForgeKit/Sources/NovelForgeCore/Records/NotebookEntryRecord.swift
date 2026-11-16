import Foundation
import ShadowCore
import ShadowStore

extension NotebookEntryMember: FieldName {}

enum NotebookLinksMember: String, CaseIterable, FieldName {
  case pages
  case entities
  case facts
  case volumes
  case chapters
}

enum NotebookPageLinkMember: String, CaseIterable, FieldName {
  case section
  case slug
}

// apps/novel-forge-server/src/database/schemas/ledger.ts:17
public struct NotebookPageLink: Sendable, Equatable {
  public var section: StoredPageSection
  public var slug: String

  public init(section: StoredPageSection, slug: String) {
    self.section = section
    self.slug = slug
  }
}

extension NotebookPageLink: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<NotebookPageLinkMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      let section: String = try reader.required(.section)
      self.init(section: StoredPageSection(rawValue: section), slug: try reader.required(.slug))
    } catch {
      return nil
    }
  }

  public var json: JSONValue {
    var fields = RecordFields<NotebookPageLinkMember>()
    fields.put(.section, section.rawValue)
    fields.put(.slug, slug)
    return fields.json
  }
}

// apps/novel-forge-server/src/database/schemas/ledger.ts:35
public struct NotebookLinks: Sendable, Equatable {
  public var pages: [NotebookPageLink]?
  public var entities: [String]?
  public var facts: [String]?
  public var volumes: [String]?
  public var chapters: [Int]?
  public private(set) var unrecognised: [String: JSONValue]

  public init(pages: [NotebookPageLink]? = nil, entities: [String]? = nil, facts: [String]? = nil, volumes: [String]? = nil, chapters: [Int]? = nil) {
    self.pages = pages
    self.entities = entities
    self.facts = facts
    self.volumes = volumes
    self.chapters = chapters
    unrecognised = [:]
  }
}

extension NotebookLinks: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<NotebookLinksMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        pages: try reader.optional(.pages), entities: try reader.optional(.entities), facts: try reader.optional(.facts), volumes: try reader.optional(.volumes),
        chapters: try reader.optional(.chapters))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<NotebookLinksMember>()
    fields.put(.pages, pages)
    fields.put(.entities, entities)
    fields.put(.facts, facts)
    fields.put(.volumes, volumes)
    fields.put(.chapters, chapters)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/database/schemas/ledger.ts:48; superseded and withdrawn are derived from the entries and withdrawals that follow
public struct NotebookEntryRecord: AppendedRecord {
  public static let kind = NovelForgeKind.notebookEntry
  public static let novelMember = NotebookEntryMember.novel

  public let id: UUID
  public let novel: UUID
  public let entryKind: StoredEnum<LedgerEntryKind>
  public let topic: String
  public let statement: String
  public let why: String?
  public let rejectedAlternatives: [String]
  public let writerLine: String?
  public let decidedBy: StoredEnum<LedgerDecidedBy>
  public let stepKey: String?
  public let payload: JSONValue?
  public let links: NotebookLinks
  public let supersedes: UUID?
  public let idea: String?
  public let rejectionScope: StoredEnum<LedgerRejectionScope>?
  public let rejectionAnchor: JSONValue?
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    id: UUID = UUID(), novel: UUID, entryKind: StoredEnum<LedgerEntryKind>, topic: String, statement: String, why: String? = nil, rejectedAlternatives: [String] = [],
    writerLine: String? = nil, decidedBy: StoredEnum<LedgerDecidedBy> = .known(.author), stepKey: String? = nil, payload: JSONValue? = nil, links: NotebookLinks = NotebookLinks(),
    supersedes: UUID? = nil, idea: String? = nil, rejectionScope: StoredEnum<LedgerRejectionScope>? = nil, rejectionAnchor: JSONValue? = nil
  ) {
    self.id = id
    self.novel = novel
    self.entryKind = entryKind
    self.topic = topic
    self.statement = statement
    self.why = why
    self.rejectedAlternatives = rejectedAlternatives
    self.writerLine = writerLine
    self.decidedBy = decidedBy
    self.stepKey = stepKey
    self.payload = payload
    self.links = links
    self.supersedes = supersedes
    self.idea = idea
    self.rejectionScope = rejectionScope
    self.rejectionAnchor = rejectionAnchor
    unrecognised = [:]
  }

  public init(id: UUID, reading reader: FieldReader<NotebookEntryMember>) throws(UnreadableReason) {
    self.init(
      id: id, novel: try reader.required(.novel), entryKind: try reader.required(.kind), topic: try reader.required(.topic), statement: try reader.required(.statement),
      why: try reader.optional(.why), rejectedAlternatives: try reader.required(.rejectedAlternatives), writerLine: try reader.optional(.writerLine),
      decidedBy: try reader.required(.decidedBy), stepKey: try reader.optional(.stepKey), payload: try reader.optional(.payload), links: try reader.required(.links),
      supersedes: try reader.optional(.supersedes), idea: try reader.optional(.idea), rejectionScope: try reader.optional(.rejectionScope),
      rejectionAnchor: try reader.optional(.rejectionAnchor))
    unrecognised = reader.unrecognised
  }

  public var members: RecordFields<NotebookEntryMember> {
    var fields = RecordFields<NotebookEntryMember>()
    fields.put(.novel, novel)
    fields.put(.kind, entryKind)
    fields.put(.topic, topic)
    fields.put(.statement, statement)
    fields.put(.why, why)
    fields.put(.rejectedAlternatives, rejectedAlternatives)
    fields.put(.writerLine, writerLine)
    fields.put(.decidedBy, decidedBy)
    fields.put(.stepKey, stepKey)
    fields.put(.payload, payload)
    fields.put(.links, links)
    fields.put(.supersedes, supersedes)
    fields.put(.idea, idea)
    fields.put(.rejectionScope, rejectionScope)
    fields.put(.rejectionAnchor, rejectionAnchor)
    return fields
  }
}
