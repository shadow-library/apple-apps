import Foundation

// apps/novel-forge-server/src/modules/refinement/proposal-current.ts:4
struct ProposalOpCurrent: Sendable, Equatable {
  let index: Int
  let exists: Bool
  let values: OrderedJSONObject
  var isUnreadable = false
}

// proposal-current.ts:10
private let currentOps: Set<OpType> = [.premiseUpdate, .bibleDocumentUpsert, .entityUpsert, .factUpsert, .volumeUpsert, .milestoneUpsert, .promiseCreate, .promiseUpdate]

// proposal-current.ts:21
private let nonContentKeys: Set<JSString> = [
  "op", "entityKey", "section", "slug", "key", "factKey", "volumeKey", "milestoneKey", "rationale", "quote", "startedEmpty", "ideaId",
]

// proposal-current.ts:23
func currentRefs(_ changeSet: [ChangeOp]) -> [String] {
  changeSetRefs(changeSet.filter { currentOps.contains($0.type) })
}

// proposal-current.ts:27
private func currentValues(_ op: ChangeOp, _ record: OrderedJSONObject) -> OrderedJSONObject {
  if op.type == .bibleDocumentUpsert {
    return OrderedJSONObject([(key: "frontmatter", value: record["frontmatter"] ?? .null), (key: "body", value: record["body"] ?? .null)])
  }
  let promise = op.type == .promiseCreate || op.type == .promiseUpdate
  let carried = op.fields.keys.filter { key in !nonContentKeys.contains(JSString(key)) && !(promise && key.jsEquals("kind")) && record[key] != nil }
  return OrderedJSONObject(carried.compactMap { key in record[key].map { (key: key, value: $0) } })
}

// proposal-current.ts:34
func proposalCurrent(_ changeSet: [ChangeOp], records: CurrentRecords) -> [ProposalOpCurrent] {
  changeSet.enumerated().compactMap { index, op in
    guard currentOps.contains(op.type) else { return nil }
    switch changeSetRefs([op]).first.flatMap({ records[$0] }) {
    case nil: return ProposalOpCurrent(index: index, exists: false, values: OrderedJSONObject([]))
    case .unreadable?: return ProposalOpCurrent(index: index, exists: true, values: OrderedJSONObject([]), isUnreadable: true)
    case .fields(let record)?: return ProposalOpCurrent(index: index, exists: true, values: currentValues(op, record))
    }
  }
}
