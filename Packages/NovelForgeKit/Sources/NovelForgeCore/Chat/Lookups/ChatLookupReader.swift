import Foundation
import ShadowCore
import ShadowStore
import ShadowText

struct ChatLookupFailure: Error, Equatable {}

/// One consistent read of the vault answering every lookup of a round.
struct ChatLookupReader {
  static let notAvailable = "(not available)"

  let transaction: ReadTransaction
  let novel: UUID
  let now: Date

  func head<Record: HeadReadable>(_: Record.Type, _ ref: EntityRef) throws(ChatLookupFailure) -> (record: Record, revision: String)? {
    let state: EntityState?
    do {
      state = try transaction.stateNamingRevisions(of: ref, scope: .vault)
    } catch {
      throw ChatLookupFailure()
    }
    switch Record.reading(state, of: ref) {
    case .absent: return nil
    case .unreadable: throw ChatLookupFailure()
    case .readable(let entry): return entry.isRemoved ? nil : (entry.record, Self.revisionLabel(state))
    }
  }

  /// The vault keeps no revision counter; a revision reads as how many versions the chain holds, which is the reference's `revision` for a record saved once per version.
  static func revisionLabel(_ state: EntityState?) -> String {
    guard case .revisioned(let revisioned)? = state, let head = revisioned.headRevision, let item = revisioned.revisions[ExactString(head)] else { return "1" }
    return String(item.generation < Int64(Int.max) ? item.generation + 1 : Int64(Int.max))
  }

  static func chapterNumber(_ chapter: Double) -> Int? {
    Int(exactly: chapter)
  }

  func query<Value>(_ body: () throws(StoreError) -> Value) throws(ChatLookupFailure) -> Value {
    do {
      return try body()
    } catch {
      throw ChatLookupFailure()
    }
  }
}

// Postgres jsonb stores object keys by length, then bytes, and the reference prints them back in that order.
enum JSONBText {
  static func object(_ pairs: [(key: String, value: OrderedJSON)]) -> OrderedJSON {
    let sorted = pairs.sorted { left, right in
      let (first, second) = (Array(left.key.utf8), Array(right.key.utf8))
      return first.count == second.count ? first.lexicographicallyPrecedes(second) : first.count < second.count
    }
    return .object(OrderedJSONObject(sorted))
  }

  static func value(_ json: JSONValue) -> OrderedJSON {
    switch json {
    case .null: .null
    case .bool(let flag): .bool(flag)
    case .int(let number): .int(number)
    case .string(let text): .string(text)
    case .array(let items): .array(items.map(value))
    case .object(let fields): object(fields.map { (key: $0.key, value: value($0.value)) })
    }
  }

  static func strings(_ items: [String]) -> OrderedJSON {
    .array(items.map(OrderedJSON.string))
  }
}
