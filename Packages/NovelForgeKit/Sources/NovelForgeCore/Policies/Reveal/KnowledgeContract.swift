import ShadowCore
import ShadowText

public struct KnowledgeReveal: Sendable, Codable {
  public let entityKey: String
  public let factKey: String

  public init(entityKey: String, factKey: String) {
    self.entityKey = entityKey
    self.factKey = factKey
  }
}

extension KnowledgeReveal: Equatable {
  public static func == (left: KnowledgeReveal, right: KnowledgeReveal) -> Bool {
    left.entityKey.jsEquals(right.entityKey) && left.factKey.jsEquals(right.factKey)
  }
}

public struct KnowledgeContract: Sendable, Codable {
  public let pov: [String]
  public let learns: [KnowledgeReveal]

  public init(pov: [String], learns: [KnowledgeReveal]) {
    self.pov = pov
    self.learns = learns
  }
}

extension KnowledgeContract: Equatable {
  public static func == (left: KnowledgeContract, right: KnowledgeContract) -> Bool {
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
