import CryptoKit
import Foundation
import ShadowCore

extension VaultState {
  public func records(schema: Int) -> [ChangeRecord] {
    refs.flatMap { ref in entities[ref].map { $0.records(ref, schema: schema) } ?? [] } + foreign
  }
}

extension EntityState {
  func records(_ ref: EntityRef, schema: Int) -> [ChangeRecord] {
    switch self {
    case .record(let state):
      return Self.sets(state.fields, ref, schema)
    case .appended(let state):
      return [.synthesised(.append, ref, clock: state.clock, schema: schema, fields: state.item)]
    case .purged(let state):
      return [.synthesised(.purge, ref, clock: state.clock, schema: schema, fields: [:])]
    case .revisioned(let state):
      return Self.sets(state.fields, ref, schema) + state.revisions.sorted { $0.key < $1.key }.flatMap { id, item in Self.revises(id, item, state, ref, schema) }
    }
  }

  private static func sets(_ fields: [ExactString: FieldState], _ ref: EntityRef, _ schema: Int) -> [ChangeRecord] {
    Dictionary(grouping: fields) { $0.value.clock }.sorted { $0.key < $1.key }.flatMap { clock, group in
      chunks(group.sorted { $0.key < $1.key }).map { .synthesised(.set, ref, clock: clock, schema: schema, fields: $0) }
    }
  }

  private static func chunks(_ fields: [(key: ExactString, value: FieldState)]) -> [[String: JSONValue]] {
    var chunks = [[String: JSONValue]]()
    for (name, field) in fields {
      if let index = chunks.firstIndex(where: { $0[name.value] == nil }) {
        chunks[index][name.value] = field.value
      } else {
        chunks.append([name.value: field.value])
      }
    }
    return chunks
  }

  private static func revises(_ id: ExactString, _ item: RevisionItem, _ state: RevisionedState, _ ref: EntityRef, _ schema: Int) -> [ChangeRecord] {
    let names = { (pointer: FieldState) in pointer.value.stringValue.map(ExactString.init(_:)) == id }
    var byClock = [HLCTimestamp: (head: Bool, marks: [String])]()
    if let head = state.head, names(head) { byClock[head.clock, default: (false, [])].head = true }
    for (mark, pointer) in state.marks.sorted(by: { $0.key < $1.key }) where names(pointer) { byClock[pointer.clock, default: (false, [])].marks.append(mark.value) }
    guard !byClock.isEmpty else { return [.synthesisedRevise(ref, clock: item.created, schema: schema, item: item, head: false, marks: [])] }
    return byClock.sorted { $0.key < $1.key }.map { clock, pointers in
      .synthesisedRevise(ref, clock: clock, schema: schema, item: item, head: pointers.head, marks: pointers.marks)
    }
  }
}

extension ChangeRecord {
  private static let placeholder = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

  static func synthesised(_ kind: ChangeKind, _ ref: EntityRef, clock: HLCTimestamp, schema: Int, fields: [String: JSONValue]) -> ChangeRecord {
    ChangeRecord(id: placeholder, clock: clock, schema: schema, entity: ref.kind, key: ref.key, kind: kind, fields: fields).withDerivedID()
  }

  static func synthesisedRevise(_ ref: EntityRef, clock: HLCTimestamp, schema: Int, item: RevisionItem, head: Bool, marks: [String]) -> ChangeRecord {
    revise(id: placeholder, clock: clock, schema: schema, entity: ref.kind, key: ref.key, item: item, head: head, marks: marks).withDerivedID()
  }

  private func withDerivedID() -> ChangeRecord {
    var members = json.objectValue ?? [:]
    members["id"] = nil
    var bytes = Array(SHA256.hash(data: CanonicalJSON.encode(.object(members))).prefix(16))
    bytes[6] = bytes[6] & 0x0F | 0x80
    bytes[8] = bytes[8] & 0x3F | 0x80
    let uuid = UUID(
      uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    return ChangeRecord(id: uuid, clock: clock, schema: schema, entity: entity, key: key, kind: kind, fields: fields)
  }
}
