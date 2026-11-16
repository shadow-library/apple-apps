import Foundation
import ShadowCore
import ShadowStore

public protocol RevisionBody: JSONRepresentable, Equatable {}

public enum DocumentField: FieldName, Hashable, Sendable {
  public static var allCases: [DocumentField] { [] }

  public init?(rawValue: String) { nil }

  public var rawValue: String {
    switch self {}
  }
}

public enum NoMark: FieldName, Hashable, Sendable {
  public static var allCases: [NoMark] { [] }

  public init?(rawValue: String) { nil }

  public var rawValue: String {
    switch self {}
  }
}

public enum BodyReading<Body: Sendable & Equatable>: Sendable, Equatable {
  case readable(Body)
  case unreadable(UnreadableReason)

  public var body: Body? {
    guard case .readable(let body) = self else { return nil }
    return body
  }
}

public struct RevisionEntry<Body: Sendable & Equatable>: Sendable, Equatable {
  public let id: String
  public let parent: String?
  public let generation: Int64
  public let created: HLCTimestamp
  public let body: BodyReading<Body>
}

public struct RevisionHistory<Body: Sendable & Equatable, Mark: FieldName & Hashable & Sendable>: Sendable, Equatable {
  public let head: String?
  public let revisions: [RevisionEntry<Body>]
  public let marks: [Mark: String]

  public var headEntry: RevisionEntry<Body>? {
    guard let head else { return nil }
    return revisions.first { $0.id == head }
  }
}

public enum HistoryReading<Body: Sendable & Equatable, Mark: FieldName & Hashable & Sendable>: Sendable, Equatable {
  case absent
  case readable(RevisionHistory<Body, Mark>)
  case unreadable(UnreadableReason)

  public var history: RevisionHistory<Body, Mark>? {
    guard case .readable(let history) = self else { return nil }
    return history
  }
}

public struct Revised: Sendable {
  public let record: ChangeRecord
  public let revision: String
}

public protocol RevisionedRecord: KeyedRecord {
  associatedtype Body: RevisionBody
  associatedtype Mark: FieldName & Hashable & Sendable = NoMark
}

extension RevisionedRecord {
  static func revise(_ ref: EntityRef, body: Body, marks: [Mark] = [], in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    guard NovelForgeKind(ref.kind) == kind else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is not a \(kind.rawValue) entity") }
    guard case .revisioned(let state)? = try transaction.state(of: ref, scope: .vault), state[field: CommonField.naturalKey.rawValue] != nil else {
      throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) was never created")
    }
    let revised = try transaction.revise(ref, body: body.json, marks: marks.map(\.rawValue))
    return Revised(record: revised.record, revision: revised.revision)
  }

  static func mark(_ ref: EntityRef, revision: String, as marks: [Mark], in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    guard NovelForgeKind(ref.kind) == kind else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is not a \(kind.rawValue) entity") }
    guard !marks.isEmpty else { throw .invalidChange("marking \(ref.kind.rawValue)/\(ref.key.rawValue) names no mark") }
    return try transaction.reassert(ref, revision: revision, head: false, marks: marks.map(\.rawValue))
  }

  static func history<Transaction: StateReading & ~Copyable>(of ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> HistoryReading<Body, Mark> {
    history(of: try transaction.state(of: ref, scope: .vault), at: ref)
  }

  static func history(of state: EntityState?, at ref: EntityRef) -> HistoryReading<Body, Mark> {
    guard let state else { return .absent }
    guard NovelForgeKind(ref.kind) == kind else { return .unreadable(.identity(ref)) }
    switch state {
    case .purged: return .absent
    case .record, .appended: return .unreadable(.wrongShape)
    case .revisioned(let revisioned): return .readable(history(of: revisioned))
    }
  }

  private static func history(of state: RevisionedState) -> RevisionHistory<Body, Mark> {
    let items = state.revisions.values.sorted { ($0.generation, $0.created, $0.id) > ($1.generation, $1.created, $1.id) }
    let entries = items.map { item in
      RevisionEntry(id: item.id, parent: item.parent, generation: item.generation, created: item.created, body: bodyReading(item.body))
    }
    var marks = [Mark: String]()
    for mark in Mark.allCases {
      guard let revision = state[mark: mark.rawValue]?.value.stringValue else { continue }
      marks[mark] = revision
    }
    return RevisionHistory(head: state.headRevision, revisions: entries, marks: marks)
  }

  private static func bodyReading(_ json: JSONValue) -> BodyReading<Body> {
    guard let body = Body(json: json) else { return .unreadable(.invalid(field: revisionHeadMember)) }
    return .readable(body)
  }
}

public protocol DocumentRecord: RevisionedRecord where Field == DocumentField {
  var content: Body { get }
}

extension DocumentRecord {
  public var fields: RecordFields<DocumentField> { RecordFields() }

  public func create(in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    let created = try transaction.set(ref, storedMembers)
    _ = try transaction.revise(ref, body: content.json)
    return created
  }

  public static func isPending(_ state: EntityState) -> Bool {
    guard case .revisioned(let revisioned) = state else { return false }
    if revisioned.head == nil && revisioned.revisions.isEmpty { return true }
    return revisioned[field: CommonField.naturalKey.rawValue] == nil
  }
}

extension DocumentRecord where Self: RemovableRecord {
  public func restore(in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref, storedMembers)
  }
}
