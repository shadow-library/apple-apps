import CryptoKit
import Foundation
import ShadowCore

/// A writer creating a new revision uses the entity's `nextGeneration`; a re-assertion copies the stored item unchanged.
public struct RevisionItem: Sendable, Equatable {
  private static let hexDigits = Array("0123456789abcdef".utf8)

  public let parent: String?
  public let body: JSONValue
  public let created: HLCTimestamp
  public let generation: Int64

  public init(parent: String?, body: JSONValue, created: HLCTimestamp, generation: Int64) {
    precondition(generation >= 0, "Revision generation must not be negative")
    self.parent = parent
    self.body = body
    self.created = created
    self.generation = generation
  }

  public var json: JSONValue {
    ["body": body, "created": .string(created.description), "generation": .int(generation), "parent": parent.map(JSONValue.string) ?? .null]
  }

  public var canonicalBytes: Data { CanonicalJSON.encode(json) }

  public var id: String {
    var text = Array("v:".utf8)
    for byte in SHA256.hash(data: canonicalBytes).prefix(20) { text.append(contentsOf: [Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0x0F)]]) }
    return String(decoding: text, as: UTF8.self)
  }

  public static func == (lhs: RevisionItem, rhs: RevisionItem) -> Bool {
    lhs.canonicalBytes == rhs.canonicalBytes
  }
}

extension ChangeRecord {
  public static func revise(
    id: UUID, clock: HLCTimestamp, schema: Int, entity: EntityKind, key: EntityKey, item: RevisionItem, head: Bool = true, marks: [String] = []
  ) -> ChangeRecord {
    var fields = item.json.objectValue ?? [:]
    fields["revision"] = .string(item.id)
    fields["head"] = .bool(head)
    if !marks.isEmpty { fields["marks"] = .array(marks.map(JSONValue.string)) }
    return ChangeRecord(id: id, clock: clock, schema: schema, entity: entity, key: key, kind: .revise, fields: fields)
  }
}
