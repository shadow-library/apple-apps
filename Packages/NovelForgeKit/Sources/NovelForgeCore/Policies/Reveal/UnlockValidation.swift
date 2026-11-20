import ShadowText

private let termKeys = ["milestone", "volume", "chapter", "ending"]

private func isBlankKey(_ value: OrderedJSON?) -> Bool {
  guard case .string(let text)? = value else { return true }
  return text.jsTrim().isEmpty
}

private func isChapterNumber(_ value: OrderedJSON?) -> Bool {
  switch value {
  case .int(let number)?: number >= 1
  case .double(let number)?: number.jsIsInteger && number >= 1
  default: false
  }
}

private func termError(_ term: OrderedJSON, index: Int) -> String? {
  let at = "unlock.all[\(index)]"
  guard case .object(let record) = term else { return "\(at) must be an object" }
  let keys = record.keys
  guard keys.count == 1, let key = keys.first, termKeys.contains(where: { $0.jsEquals(key) }) else {
    return "\(at) must have exactly one of \(termKeys.joined(separator: ", "))"
  }
  switch key {
  case "milestone" where isBlankKey(record["milestone"]): return "\(at).milestone must be a non-empty key"
  case "volume" where isBlankKey(record["volume"]): return "\(at).volume must be a non-empty key"
  case "chapter" where !isChapterNumber(record["chapter"]): return "\(at).chapter must be an integer >= 1"
  case "ending" where record["ending"] != .bool(true): return "\(at).ending must be true"
  default: return nil
  }
}

// platform/apps/novel-forge-server/src/common/unlock-condition.ts:24
func validateUnlockCondition(_ value: OrderedJSON) -> [String] {
  guard case .object(let record) = value else { return ["unlock must be an object"] }
  let unexpected = record.keys.filter { !$0.jsEquals("all") }
  if !unexpected.isEmpty { return unexpected.map { "unlock has unexpected field '\($0)'" } }
  guard let terms = record["all"]?.arrayValue, !terms.isEmpty else { return ["unlock.all must be a non-empty array"] }
  return terms.enumerated().compactMap { termError($1, index: $0) }
}

// platform/apps/novel-forge-server/src/common/unlock-condition.ts:33
func isUnlockCondition(_ value: OrderedJSON) -> Bool {
  validateUnlockCondition(value).isEmpty
}
