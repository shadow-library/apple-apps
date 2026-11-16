import Foundation
import ShadowCore

public enum RegistryDescriptionError: ShadowError, Equatable {
  case notCanonical
  case unsupportedFormat
  case malformed(String)

  public var code: String {
    switch self {
    case .notCanonical: "registry_description.not_canonical"
    case .unsupportedFormat: "registry_description.unsupported_format"
    case .malformed: "registry_description.malformed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notCanonical: "The registry description is not canonical JSON."
    case .unsupportedFormat: "The registry description has an unsupported format."
    case .malformed(let reason): "The registry description is malformed: \(reason)."
    }
  }
}

extension SchemaRegistry {
  public static let descriptionFormat = "shadow.schema-registry"
  public static let descriptionFormatVersion: Int64 = 1

  public func canonicalDescription() -> Data {
    CanonicalJSON.encode([
      "format": .string(Self.descriptionFormat), "format_version": .int(Self.descriptionFormatVersion), "kinds": .array(schemas.map(\.descriptionJSON)),
      "version": .int(Int64(version)),
    ])
  }

  /// Every precondition of `EntitySchema` and `SchemaRegistry` is checked first, so a corrupt description throws instead of trapping.
  public init(canonicalDescription: Data) throws(RegistryDescriptionError) {
    let json: JSONValue
    do {
      json = try CanonicalJSON.decode(canonicalDescription, mode: .canonical)
    } catch {
      throw .notCanonical
    }
    let members = try Description.members(json, ["format", "format_version", "kinds", "version"], "registry")
    guard Description.isTag(members["format"]?.stringValue, Self.descriptionFormat), members["format_version"]?.intValue == Self.descriptionFormatVersion else {
      throw .unsupportedFormat
    }
    guard let version = members["version"]?.intValue.flatMap({ Int(exactly: $0) }) else { throw .malformed("the version is not an integer") }
    guard let kinds = members["kinds"]?.arrayValue else { throw .malformed("kinds is not an array") }
    var schemas = [EntitySchema]()
    for entry in kinds {
      let schema = try EntitySchema(description: entry)
      if let last = schemas.last { guard last.kind < schema.kind else { throw .malformed("kinds are not in strictly increasing order") } }
      schemas.append(schema)
    }
    self.init(version: version, entities: schemas)
  }
}

extension EntitySchema {
  fileprivate var descriptionJSON: JSONValue {
    var members: [String: JSONValue] = ["kind": .string(kind.rawValue), "shape": .string(shape.name), "sync_class": .string(syncClass.rawValue)]
    switch shape {
    case .record(let fields):
      members["fields"] = Self.fieldsJSON(fields)
    case .appended:
      break
    case .revisioned(let fields, let marks, let retention):
      members["fields"] = Self.fieldsJSON(fields)
      members["marks"] = .array(marks.map(ExactString.init(_:)).sorted().map { .string($0.value) })
      switch retention {
      case .keepAll: members["retention"] = "all"
      case .keepNewest(let count): members["retention"] = .int(Int64(count))
      }
    }
    return .object(members)
  }

  private static func fieldsJSON(_ fields: [String: FieldRule]) -> JSONValue {
    .array(fields.sorted { ExactString($0.key) < ExactString($1.key) }.map { name, rule in ["name": .string(name), "rule": rule.json] })
  }

  fileprivate init(description value: JSONValue) throws(RegistryDescriptionError) {
    guard let kindText = value["kind"]?.stringValue, let kind = EntityKind(kindText) else { throw .malformed("a kind name is invalid") }
    guard let shapeName = value["shape"]?.stringValue else { throw .malformed("kind \(kind) has no shape") }
    guard let syncText = value["sync_class"]?.stringValue, let syncClass = SyncClass.allCases.first(where: { Description.isTag(syncText, $0.rawValue) }) else {
      throw .malformed("kind \(kind) has an unknown sync class")
    }
    let shape: EntityShape
    if Description.isTag(shapeName, "record") {
      let members = try Description.members(value, ["fields", "kind", "shape", "sync_class"], "kind \(kind)")
      shape = .record(fields: try Self.fields(members["fields"], kind))
    } else if Description.isTag(shapeName, "appended") {
      _ = try Description.members(value, ["kind", "shape", "sync_class"], "kind \(kind)")
      shape = .appended
    } else if Description.isTag(shapeName, "revisioned") {
      let members = try Description.members(value, ["fields", "kind", "marks", "retention", "shape", "sync_class"], "kind \(kind)")
      let fields = try Self.fields(members["fields"], kind)
      guard Self.exactRule(Self.headField, in: fields) == nil else { throw .malformed("kind \(kind) declares a field named head") }
      shape = .revisioned(fields: fields, marks: try Self.marks(members["marks"], fields, kind), retention: try Self.retention(members["retention"], kind))
    } else {
      throw .malformed("kind \(kind) has an unknown shape")
    }
    self.init(kind: kind, shape: shape, syncClass: syncClass)
  }

  private static func fields(_ value: JSONValue?, _ kind: EntityKind) throws(RegistryDescriptionError) -> [String: FieldRule] {
    guard let entries = value?.arrayValue else { throw .malformed("the fields of \(kind) are not an array") }
    var fields = [String: FieldRule]()
    var last: ExactString?
    for entry in entries {
      let members = try Description.members(entry, ["name", "rule"], "a field of \(kind)")
      guard let name = members["name"]?.stringValue, let rule = members["rule"].flatMap(FieldRule.init(json:)) else { throw .malformed("a field of \(kind) is invalid") }
      if let last { guard last < ExactString(name) else { throw .malformed("the fields of \(kind) are not in strictly increasing order") } }
      guard fields[name] == nil else { throw .malformed("the fields of \(kind) repeat a name") }
      last = ExactString(name)
      fields[name] = rule
    }
    return fields
  }

  private static func marks(_ value: JSONValue?, _ fields: [String: FieldRule], _ kind: EntityKind) throws(RegistryDescriptionError) -> [String] {
    guard let entries = value?.arrayValue else { throw .malformed("the marks of \(kind) are not an array") }
    let marks = entries.compactMap(\.stringValue)
    guard marks.count == entries.count else { throw .malformed("a mark of \(kind) is not a string") }
    let exact = marks.map(ExactString.init(_:))
    guard zip(exact, exact.dropFirst()).allSatisfy({ $0 < $1 }) else { throw .malformed("the marks of \(kind) are not in strictly increasing order") }
    for mark in marks where Description.isTag(mark, headField) || exactRule(mark, in: fields) != nil { throw .malformed("mark \(kind).\(mark) is head or a field") }
    return marks
  }

  private static func retention(_ value: JSONValue?, _ kind: EntityKind) throws(RegistryDescriptionError) -> RevisionRetention {
    if Description.isTag(value?.stringValue, "all") { return .keepAll }
    guard let count = value?.intValue.flatMap({ Int(exactly: $0) }), count >= 1 else { throw .malformed("the retention of \(kind) is invalid") }
    return .keepNewest(count)
  }
}

private enum Description {
  static func isTag(_ text: String?, _ tag: String) -> Bool {
    text?.utf8.elementsEqual(tag.utf8) ?? false
  }

  static func members(_ value: JSONValue, _ names: [String], _ what: String) throws(RegistryDescriptionError) -> [String: JSONValue] {
    guard case .object(let members) = value, members.count == names.count, members.keys.allSatisfy({ key in names.contains { isTag(key, $0) } }) else {
      throw .malformed("\(what) does not have exactly the members \(names.joined(separator: ", "))")
    }
    return members
  }
}
