import Foundation
import ShadowCore

/// An entity as an export of another store held it: a record's merged fields, an appended item, or a revisioned entity's fields with its head and kept
/// revisions. Clocks are not carried, so an import stamps its changes anew.
public enum ImportedEntity: Sendable, Equatable {
  case record(EntityRef, fields: [String: JSONValue])
  case appended(EntityRef, item: [String: JSONValue])
  case revisioned(EntityRef, fields: [String: JSONValue], head: String?, revisions: [ImportedRevision])

  public var ref: EntityRef {
    switch self {
    case .record(let ref, _), .appended(let ref, _), .revisioned(let ref, _, _, _): ref
    }
  }
}

/// A revision's id hashes its `created` clock, so one exported without it is written with a new clock under a new id, which its children's `parent` and
/// the head follow.
public struct ImportedRevision: Sendable, Equatable {
  public let id: String
  public let parent: String?
  public let body: JSONValue
  public let generation: Int64
  public let created: HLCTimestamp?

  public init(id: String, parent: String?, body: JSONValue, generation: Int64, created: HLCTimestamp?) {
    self.id = id
    self.parent = parent
    self.body = body
    self.generation = generation
    self.created = created
  }
}

extension SchemaRegistry {
  /// Why the registry cannot take the entity as given, checked before anything is written; nil when it can.
  public func importRefusal(of entity: ImportedEntity) -> String? {
    let ref = entity.ref
    guard let schema = self[ref.kind] else { return "kind \(ref.kind) is not declared" }
    switch (entity, schema.shape) {
    case (.record(_, let fields), .record):
      guard !fields.isEmpty else { return "\(ref.kind)/\(ref.key) holds no field" }
      return Self.fieldRefusal(fields, of: schema)
    case (.appended, .appended):
      return nil
    case (.revisioned(_, let fields, let head, let revisions), .revisioned):
      guard !fields.isEmpty || !revisions.isEmpty else { return "\(ref.kind)/\(ref.key) holds neither a field nor a revision" }
      return Self.fieldRefusal(fields, of: schema) ?? Self.revisionRefusal(head: head, revisions: revisions, of: ref)
    default:
      return "\(ref.kind)/\(ref.key) is not shaped as its kind is declared"
    }
  }

  private static func fieldRefusal(_ fields: [String: JSONValue], of schema: EntitySchema) -> String? {
    for (name, value) in fields.sorted(by: { ExactString($0.key) < ExactString($1.key) }) {
      guard let rule = schema.rule(forField: name) else { return "field \(schema.kind).\(name) is not declared" }
      guard rule.admits(value) else { return "field \(schema.kind).\(name) holds a value that \(rule.summary) does not admit" }
    }
    return nil
  }

  private static func revisionRefusal(head: String?, revisions: [ImportedRevision], of ref: EntityRef) -> String? {
    let ids = revisions.map { ExactString($0.id) }
    guard Set(ids).count == ids.count else { return "\(ref.kind)/\(ref.key) names a revision twice" }
    if let head, !ids.contains(ExactString(head)) { return "the head of \(ref.kind)/\(ref.key) names no revision it holds" }
    let kept = revisions.count { $0.created != nil }
    guard kept == 0 || kept == revisions.count else { return "\(ref.kind)/\(ref.key) mixes revisions with and without their creation clock" }
    for revision in revisions {
      guard revision.generation >= 0 else { return "a revision of \(ref.kind)/\(ref.key) has a negative generation" }
      guard let created = revision.created else { continue }
      let item = RevisionItem(parent: revision.parent, body: revision.body, created: created, generation: revision.generation)
      guard ExactString(item.id) == ExactString(revision.id) else { return "revision \(revision.id) of \(ref.kind)/\(ref.key) does not match its id" }
    }
    return nil
  }
}
