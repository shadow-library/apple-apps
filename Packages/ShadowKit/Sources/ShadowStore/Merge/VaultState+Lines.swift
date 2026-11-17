import CryptoKit
import Foundation
import ShadowCore

extension VaultState {
  public static let linesFormat = "com.shadow.library.shadowstore.vault-state"
  public static let linesVersion: Int64 = 1

  private static let hexDigits = Array("0123456789abcdef".utf8)

  public func encodedLines() -> [Data] {
    let header: JSONValue = ["format": .string(Self.linesFormat), "type": "header", "version": .int(Self.linesVersion)]
    let entityLines = refs.compactMap { ref in entities[ref].map { $0.line(ref) } }
    let foreignLines = foreign.map { record -> JSONValue in ["record": record.json, "type": "foreign"] }
    let opaqueLines = opaqueLines.map { line -> JSONValue in ["line": .string(line.base64EncodedString()), "type": "opaque"] }
    return ([header] + entityLines + foreignLines + opaqueLines).map(CanonicalJSON.encode)
  }

  public var digest: String {
    let digest = SHA256.hash(data: Data(encodedLines().joined(separator: [UInt8(ascii: "\n")])))
    return String(decoding: digest.flatMap { [Self.hexDigits[Int($0 >> 4)], Self.hexDigits[Int($0 & 0x0F)]] }, as: UTF8.self)
  }

  public init(decodingLines lines: [Data]) throws(VaultStateError) {
    guard let first = lines.first else { throw .missingHeader }
    let header = try Self.decodeLine(first, number: 0)
    guard let members = LineMembers(header, ["format", "type", "version"]), isTag(members.string("type"), "header") else { throw .missingHeader }
    guard isTag(members.string("format"), Self.linesFormat), let version = members["version"]?.intValue else { throw .malformedLine(line: 0) }
    guard version == Self.linesVersion else { throw .unsupportedVersion(version) }
    self.init()
    var lastRef: EntityRef?
    var lastForeign: Data?
    var lastOpaque: Data?
    var droppable = [(number: Int, ref: EntityRef)]()
    for (number, line) in lines.enumerated().dropFirst() {
      let value = try Self.decodeLine(line, number: number)
      guard case .object(let object) = value, let type = object["type"]?.stringValue else { throw .malformedLine(line: number) }
      if isTag(type, "opaque") {
        guard let members = LineMembers(value, ["line", "type"]), let text = members.string("line"), let bytes = Data(base64Encoded: text), isTag(bytes.base64EncodedString(), text)
        else { throw .malformedLine(line: number) }
        if let lastOpaque { guard lastOpaque.lexicographicallyPrecedes(bytes) else { throw .outOfOrder(line: number) } }
        lastOpaque = bytes
        opaque.insert(bytes)
        continue
      }
      guard lastOpaque == nil else { throw .outOfOrder(line: number) }
      if isTag(type, "foreign") {
        guard let members = LineMembers(value, ["record", "type"]), let json = members["record"], let record = try? ChangeRecord(json: json) else {
          throw .malformedLine(line: number)
        }
        if record.kind != .purge, case .purged = entities[record.ref] { throw .malformedLine(line: number) }
        let bytes = record.canonicalBytes()
        if let lastForeign { guard lastForeign.lexicographicallyPrecedes(bytes) else { throw .outOfOrder(line: number) } }
        lastForeign = bytes
        foreignRecords[bytes] = record
        if record.kind != .purge { droppable.append((number, record.ref)) }
        continue
      }
      guard lastForeign == nil else { throw .outOfOrder(line: number) }
      guard let ref = LineMembers.ref(value), let state = EntityState(line: value) else { throw .malformedLine(line: number) }
      if let lastRef { guard lastRef < ref else { throw .outOfOrder(line: number) } }
      lastRef = ref
      entities[ref] = state
    }
    let absorbed = Set(foreignRecords.values.filter(\.absorbsForeign).map(\.ref))
    if let line = droppable.first(where: { absorbed.contains($0.ref) }) { throw .malformedLine(line: line.number) }
  }

  private static func decodeLine(_ line: Data, number: Int) throws(VaultStateError) -> JSONValue {
    do {
      return try CanonicalJSON.decode(line, mode: .canonical)
    } catch {
      throw .invalidJSON(line: number)
    }
  }
}

private func isTag(_ text: String?, _ tag: String) -> Bool {
  text?.utf8.elementsEqual(tag.utf8) ?? false
}

private struct LineMembers {
  private let members: [String: JSONValue]

  init?(_ value: JSONValue, _ names: [String]) {
    guard case .object(let members) = value, members.count == names.count else { return nil }
    guard members.keys.allSatisfy({ key in names.contains { $0.utf8.elementsEqual(key.utf8) } }) else { return nil }
    self.members = members
  }

  subscript(name: String) -> JSONValue? {
    members[name]
  }

  func string(_ name: String) -> String? {
    members[name]?.stringValue
  }

  func clock(_ name: String) -> HLCTimestamp? {
    string(name).flatMap(HLCTimestamp.init)
  }

  static func ref(_ value: JSONValue) -> EntityRef? {
    guard let kind = value["entity"]?.stringValue.flatMap(EntityKind.init), let key = value["key"]?.stringValue.flatMap(EntityKey.init) else { return nil }
    return EntityRef(kind: kind, key: key)
  }
}

extension EntityState {
  func line(_ ref: EntityRef) -> JSONValue {
    var members: [String: JSONValue] = ["entity": .string(ref.kind.rawValue), "key": .string(ref.key.rawValue), "type": .string(shapeName)]
    switch self {
    case .record(let state):
      members["fields"] = Self.fieldLines(state.fields)
    case .appended(let state):
      members["clock"] = .string(state.clock.description)
      members["item"] = .object(state.item)
    case .revisioned(let state):
      members["fields"] = Self.fieldLines(state.fields)
      members["head"] = state.head.map { ["clock": .string($0.clock.description), "value": $0.value] } ?? .null
      members["marks"] = .array(
        state.marks.sorted { $0.key < $1.key }.map { name, mark in ["clock": .string(mark.clock.description), "name": .string(name.value), "value": mark.value] })
      members["revisions"] = .array(
        state.revisions.sorted { $0.key < $1.key }.map { id, revision in
          var entry = revision.json.objectValue ?? [:]
          entry["id"] = .string(id.value)
          return .object(entry)
        })
    case .purged(let state):
      members["clock"] = .string(state.clock.description)
    }
    return .object(members)
  }

  init?(line value: JSONValue) {
    guard let type = value["type"]?.stringValue, let shape = ["record", "appended", "revisioned", "purged"].first(where: { isTag(type, $0) }) else { return nil }
    switch shape {
    case "record":
      guard let members = LineMembers(value, ["entity", "fields", "key", "type"]), let fields = Self.fields(members["fields"]), !fields.isEmpty else { return nil }
      self = .record(RecordState(fields: fields))
    case "appended":
      guard let members = LineMembers(value, ["clock", "entity", "item", "key", "type"]), let clock = members.clock("clock"),
        let item = members["item"]?.objectValue
      else { return nil }
      self = .appended(AppendedState(item: item, clock: clock))
    case "revisioned":
      guard let members = LineMembers(value, ["entity", "fields", "head", "key", "marks", "revisions", "type"]), let fields = Self.fields(members["fields"]),
        let revisions = Self.revisions(members["revisions"]), let marks = Self.marks(members["marks"]), let head = Self.pointer(members["head"])
      else { return nil }
      let state = RevisionedState(fields: fields, head: head, marks: marks, revisions: revisions)
      guard !state.isEmpty, state.namedRevisions.isSubset(of: revisions.keys) else { return nil }
      self = .revisioned(state)
    case "purged":
      guard let members = LineMembers(value, ["clock", "entity", "key", "type"]), let clock = members.clock("clock") else { return nil }
      self = .purged(PurgedState(clock: clock))
    default:
      return nil
    }
  }

  private static func fieldLines(_ fields: [ExactString: FieldState]) -> JSONValue {
    .array(
      fields.sorted { $0.key < $1.key }.map { name, field in
        ["clock": .string(field.clock.description), "name": .string(name.value), "rule": field.rule.json, "value": field.value]
      })
  }

  private static func fields(_ value: JSONValue?) -> [ExactString: FieldState]? {
    guard let entries = value?.arrayValue else { return nil }
    var fields = [ExactString: FieldState]()
    var last: ExactString?
    for entry in entries {
      guard let members = LineMembers(entry, ["clock", "name", "rule", "value"]), let name = members.string("name").map(ExactString.init(_:)), let clock = members.clock("clock"),
        let rule = members["rule"].flatMap(FieldRule.init(json:)), let fieldValue = members["value"], rule.admits(fieldValue)
      else { return nil }
      if let last { guard last < name else { return nil } }
      last = name
      fields[name] = FieldState(value: fieldValue, clock: clock, rule: rule)
    }
    return fields
  }

  private static func revisions(_ value: JSONValue?) -> [ExactString: RevisionItem]? {
    guard let entries = value?.arrayValue else { return nil }
    var revisions = [ExactString: RevisionItem]()
    var last: ExactString?
    for entry in entries {
      guard let members = LineMembers(entry, ["body", "created", "generation", "id", "parent"]), let id = members.string("id").map(ExactString.init(_:)),
        let created = members.clock("created"),
        let generation = members["generation"]?.intValue, generation >= 0,
        let body = members["body"]
      else { return nil }
      if let last { guard last < id else { return nil } }
      let parent: String?
      switch members["parent"] {
      case .string(let text): parent = text
      case .null: parent = nil
      default: return nil
      }
      let item = RevisionItem(parent: parent, body: body, created: created, generation: generation)
      guard ExactString(item.id) == id else { return nil }
      last = id
      revisions[id] = item
    }
    return revisions
  }

  private static func pointer(_ value: JSONValue?) -> FieldState?? {
    guard let value else { return nil }
    if case .null = value { return .some(nil) }
    guard let members = LineMembers(value, ["clock", "value"]), let clock = members.clock("clock"), let revision = members.string("value") else { return nil }
    return FieldState(value: .string(revision), clock: clock, rule: .register)
  }

  private static func marks(_ value: JSONValue?) -> [ExactString: FieldState]? {
    guard let entries = value?.arrayValue else { return nil }
    var marks = [ExactString: FieldState]()
    var last: ExactString?
    for entry in entries {
      guard let members = LineMembers(entry, ["clock", "name", "value"]), let name = members.string("name").map(ExactString.init(_:)), let clock = members.clock("clock"),
        let revision = members.string("value"), !name.value.utf8.elementsEqual(EntitySchema.headField.utf8)
      else { return nil }
      if let last { guard last < name else { return nil } }
      last = name
      marks[name] = FieldState(value: .string(revision), clock: clock, rule: .register)
    }
    return marks
  }
}
