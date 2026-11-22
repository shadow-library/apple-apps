import Foundation
import ShadowCore

public enum FieldRule: Hashable, Sendable {
  case register
  case monotone(order: [String])
  case firstWriterWins
}

public enum SyncClass: String, Sendable, Codable, CaseIterable {
  case general
  case activity
  case health
}

public enum RevisionRetention: Hashable, Sendable {
  case keepAll
  case keepNewest(Int)
}

public enum EntityShape: Hashable, Sendable {
  case record(fields: [String: FieldRule])
  case appended
  case revisioned(fields: [String: FieldRule], marks: [String], retention: RevisionRetention)
}

public struct EntitySchema: Hashable, Sendable {
  public static let headField = "head"

  public let kind: EntityKind
  public let shape: EntityShape
  public let syncClass: SyncClass

  public init(kind: EntityKind, shape: EntityShape, syncClass: SyncClass) {
    for (name, rule) in shape.fields {
      guard case .monotone(let order) = rule else { continue }
      precondition(Set(order.map(ExactString.init(_:))).count == order.count, "Monotone order of \(kind).\(name) repeats a value")
    }
    if case .revisioned(let fields, let marks, let retention) = shape {
      precondition(Self.exactRule(Self.headField, in: fields) == nil, "Revisioned \(kind) may not declare a field named head")
      if case .keepNewest(let count) = retention { precondition(count >= 1, "Retention of \(kind) must keep at least one revision") }
      for (index, mark) in marks.enumerated() {
        precondition(!mark.utf8.elementsEqual(Self.headField.utf8), "Mark of \(kind) may not be named head")
        precondition(Self.exactRule(mark, in: fields) == nil, "Mark \(mark) of \(kind) is also a field")
        precondition(!marks[..<index].contains { $0.utf8.elementsEqual(mark.utf8) }, "Mark \(mark) of \(kind) is declared twice")
      }
    }
    self.kind = kind
    self.shape = shape
    self.syncClass = syncClass
  }

  public func rule(forField name: String) -> FieldRule? {
    switch shape {
    case .record(let fields): return Self.exactRule(name, in: fields)
    case .revisioned(let fields, _, _): return Self.exactRule(name, in: fields)
    case .appended: return nil
    }
  }

  public func declaresMark(_ name: String) -> Bool {
    guard case .revisioned(_, let marks, _) = shape else { return false }
    return marks.contains { $0.utf8.elementsEqual(name.utf8) }
  }

  static func exactRule(_ name: String, in fields: [String: FieldRule]) -> FieldRule? {
    fields.first { $0.key.utf8.elementsEqual(name.utf8) }?.value
  }
}

public struct SchemaRegistry: Sendable {
  public let version: Int

  private let entities: [EntityKind: EntitySchema]

  public init(version: Int, entities: [EntitySchema]) {
    self.version = version
    self.entities = Dictionary(entities.map { ($0.kind, $0) }) { first, _ in preconditionFailure("Entity kind \(first.kind) is declared twice") }
  }

  public subscript(kind: EntityKind) -> EntitySchema? {
    entities[kind]
  }

  public var syncClasses: Set<SyncClass> {
    Set(entities.values.map(\.syncClass))
  }

  public var schemas: [EntitySchema] {
    entities.values.sorted { $0.kind < $1.kind }
  }
}

extension EntityShape {
  var fields: [String: FieldRule] {
    switch self {
    case .record(let fields), .revisioned(let fields, _, _): fields
    case .appended: [:]
    }
  }

  var marks: [String] {
    guard case .revisioned(_, let marks, _) = self else { return [] }
    return marks
  }

  var name: String {
    switch self {
    case .record: "record"
    case .appended: "appended"
    case .revisioned: "revisioned"
    }
  }
}

extension FieldRule {
  var json: JSONValue {
    switch self {
    case .register: ["kind": "register"]
    case .firstWriterWins: ["kind": "first_writer_wins"]
    case .monotone(let order): ["kind": "monotone", "order": .array(order.map(JSONValue.string))]
    }
  }

  var canonicalBytes: Data { CanonicalJSON.encode(json) }

  var summary: String {
    switch self {
    case .register: "register"
    case .firstWriterWins: "first writer wins"
    case .monotone(let order): "monotone [\(order.joined(separator: ", "))]"
    }
  }

  init?(json: JSONValue) {
    guard case .object(let members) = json, let kind = members["kind"]?.stringValue else { return nil }
    let tag = { (name: String) in kind.utf8.elementsEqual(name.utf8) }
    if tag("register"), members.count == 1 {
      self = .register
    } else if tag("first_writer_wins"), members.count == 1 {
      self = .firstWriterWins
    } else if tag("monotone"), members.count == 2, let order = members["order"]?.arrayValue {
      let names = order.compactMap(\.stringValue)
      guard names.count == order.count, Set(names.map(ExactString.init(_:))).count == names.count else { return nil }
      self = .monotone(order: names)
    } else {
      return nil
    }
  }

  func rank(of value: JSONValue) -> Int? {
    guard case .monotone(let order) = self, let text = value.stringValue else { return nil }
    return order.firstIndex { $0.utf8.elementsEqual(text.utf8) }
  }

  func admits(_ value: JSONValue) -> Bool {
    guard case .monotone = self else { return true }
    return rank(of: value) != nil
  }

  func isExtended(by newer: FieldRule) -> Bool {
    guard case .monotone(let old) = self, case .monotone = newer else { return false }
    let oldRanks = old.indices.filter { rank(of: .string(old[$0])) == $0 }
    let newRanks = oldRanks.compactMap { newer.rank(of: .string(old[$0])) }
    return newRanks.count == oldRanks.count && zip(newRanks, newRanks.dropFirst()).allSatisfy { $0 < $1 }
  }
}
