import CryptoKit
import Foundation

private func sha256Hex(_ text: String) -> String {
  SHA256.hash(data: Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func canonicalized(_ value: OrderedJSON) -> OrderedJSON {
  switch value {
  case .array(let items): .array(items.map(canonicalized))
  case .object(let object): .object(OrderedJSONObject(object.keys.jsSorted().compactMap { key in object[key].map { (key: key, value: canonicalized($0)) } }))
  case .null, .bool, .int, .double, .string: value
  }
}

// packages/sdk/src/publishing/content-hash.ts:20
func computeContentHash(_ content: OrderedJSONObject) -> String {
  sha256Hex(canonicalized(.object(content)).jsonText)
}

// apps/novel-forge-server/src/common/content-hash.ts:9
func computeBibleDocHash(frontmatter: OrderedJSON?, body: OrderedJSON?) -> String {
  sha256Hex("{\"frontmatter\":\((frontmatter ?? .null).jsonText),\"body\":\((body ?? .null).jsonText)}")
}

private let volumeHashFields = ["volumeKey", "ordinal", "title", "objective", "body"]
private let briefHashFields = [
  "chapter", "volumeKey", "title", "body", "contextRefs", "pov", "endingContract", "knowledgeContract", "chapterPurpose", "readerValue", "repetitionRisks", "guidance",
]
private let volumeDefaultedHashFields: [(key: String, fallback: OrderedJSON)] = [("state", .string("not_started"))]
private let briefDefaultedHashFields: [(key: String, fallback: OrderedJSON)] = [
  ("direction", .null), ("contentMode", .null), ("scenes", .null), ("claimedMilestones", .null), ("isEnding", .bool(false)),
]

private func strictlyEquals(_ left: OrderedJSON, _ right: OrderedJSON) -> Bool {
  switch (left, right) {
  case (.null, .null): true
  case (.bool(let a), .bool(let b)): a == b
  case (.string(let a), .string(let b)): a.jsEquals(b)
  default: false
  }
}

private func present(_ record: OrderedJSONObject, _ field: String) -> OrderedJSON? {
  guard let value = record[field], value != .null else { return nil }
  return value
}

// apps/novel-forge-server/src/common/content-hash.ts:38
private func pickAndHash(_ record: OrderedJSONObject, fields: [String], defaulted: [(key: String, fallback: OrderedJSON)]) -> String {
  var picked = fields.map { (key: $0, value: present(record, $0) ?? .null) }
  for (field, fallback) in defaulted {
    let value = present(record, field) ?? fallback
    if !strictlyEquals(value, fallback) { picked.append((key: field, value: value)) }
  }
  return computeContentHash(OrderedJSONObject(picked))
}

// apps/novel-forge-server/src/common/content-hash.ts:47
func volumeContentHash(_ volume: OrderedJSONObject) -> String {
  pickAndHash(volume, fields: volumeHashFields, defaulted: volumeDefaultedHashFields)
}

// apps/novel-forge-server/src/common/content-hash.ts:51
func briefContentHash(_ brief: OrderedJSONObject) -> String {
  pickAndHash(brief, fields: briefHashFields, defaulted: briefDefaultedHashFields)
}
