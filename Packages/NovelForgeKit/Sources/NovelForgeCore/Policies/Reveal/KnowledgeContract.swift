import ShadowCore

struct KnowledgeReveal: Sendable, Codable {
  let entityKey: String
  let factKey: String
}

extension KnowledgeReveal: Equatable {
  static func == (left: KnowledgeReveal, right: KnowledgeReveal) -> Bool {
    left.entityKey.jsEquals(right.entityKey) && left.factKey.jsEquals(right.factKey)
  }
}

struct KnowledgeContract: Sendable, Codable {
  let pov: [String]
  let learns: [KnowledgeReveal]
}

extension KnowledgeContract: Equatable {
  static func == (left: KnowledgeContract, right: KnowledgeContract) -> Bool {
    left.learns == right.learns && left.pov.count == right.pov.count && zip(left.pov, right.pov).allSatisfy { $0.jsEquals($1) }
  }
}

// platform/apps/novel-forge-server/src/common/knowledge-contract.ts:13
func parseKnowledgeContract(_ raw: OrderedJSON) -> KnowledgeContract? {
  guard case .object(let contract) = raw else { return nil }
  let pov = (contract["pov"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
  guard !pov.isEmpty else { return nil }
  let learns = (contract["learns"]?.arrayValue ?? []).compactMap { entry -> KnowledgeReveal? in
    guard let reveal = entry.objectValue, let entityKey = reveal["entityKey"]?.stringValue, let factKey = reveal["factKey"]?.stringValue else { return nil }
    return KnowledgeReveal(entityKey: entityKey, factKey: factKey)
  }
  return KnowledgeContract(pov: pov, learns: learns)
}
