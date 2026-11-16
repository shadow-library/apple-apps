import Foundation
import GRDB
import ShadowCore

enum FieldSlot: Int {
  case field = 0
  case head = 1
  case mark = 2
}

enum ForeignRole: Int {
  case droppable = 0
  case purge = 1
  case absorbing = 2

  init(_ record: ChangeRecord) {
    if record.absorbsForeign {
      self = .absorbing
    } else {
      self = record.kind == .purge ? .purge : .droppable
    }
  }
}

enum Stored {
  static func name(_ text: String) -> Data {
    CanonicalJSON.encode(.string(text))
  }

  static func name(from bytes: Data) throws(StoreError) -> String {
    guard case .string(let text) = try json(bytes) else { throw .corruptStore("a stored name is not a JSON string") }
    return text
  }

  static func json(_ bytes: Data) throws(StoreError) -> JSONValue {
    do {
      return try CanonicalJSON.decode(bytes)
    } catch {
      throw .corruptStore("a stored value is not canonical JSON")
    }
  }

  static func clock(_ text: String) throws(StoreError) -> HLCTimestamp {
    guard let clock = HLCTimestamp(text) else { throw .corruptStore("a stored clock is malformed") }
    return clock
  }

  static func object(_ bytes: Data) throws(StoreError) -> [String: JSONValue] {
    guard case .object(let members) = try json(bytes) else { throw .corruptStore("a stored item is not a JSON object") }
    return members
  }

  static func revision(_ bytes: Data) throws(StoreError) -> RevisionItem {
    let members = try object(bytes)
    guard let body = members["body"], let created = members["created"]?.stringValue.flatMap(HLCTimestamp.init), let generation = members["generation"]?.intValue,
      generation >= 0, members.count == 4
    else { throw .corruptStore("a stored revision is malformed") }
    switch members["parent"] {
    case .string(let parent): return RevisionItem(parent: parent, body: body, created: created, generation: generation)
    case .null: return RevisionItem(parent: nil, body: body, created: created, generation: generation)
    default: throw .corruptStore("a stored revision is malformed")
    }
  }

  static func record(_ bytes: Data) throws(StoreError) -> ChangeRecord {
    do {
      return try ChangeRecord(json: json(bytes))
    } catch {
      throw .corruptStore("a stored change record is malformed")
    }
  }
}

extension Row {
  func stored<Value: DatabaseValueConvertible>(_ column: String) throws(StoreError) -> Value {
    do {
      return try decode(Value.self, forColumn: column)
    } catch {
      throw .corruptStore("column \(column) holds an unexpected value")
    }
  }
}

extension Database {
  func storeExecute(_ sql: String, _ arguments: StatementArguments) throws {
    try cachedStatement(sql: sql).execute(arguments: arguments)
  }

  func storeFetchOne(_ sql: String, _ arguments: StatementArguments) throws -> Row? {
    try Row.fetchOne(cachedStatement(sql: sql), arguments: arguments)
  }

  func storeFetchAll(_ sql: String, _ arguments: StatementArguments) throws -> [Row] {
    try Row.fetchAll(cachedStatement(sql: sql), arguments: arguments)
  }
}
