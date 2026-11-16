import Foundation
import Testing

@testable import NovelForgeCore

private struct ContractCase: Decodable {
  let input: OrderedJSON
  let pov: [String]?
  let learns: [[String]]
  let learned: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    input = try container.decode(FixtureJSON.self).value
    struct Parsed: Decodable {
      let pov: [String]
      let learns: [[String]]

      init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        pov = try container.decode([String].self)
        learns = try container.decode([[String]].self)
      }
    }
    let parsed = try container.decodeOptional(Parsed.self)
    pov = parsed?.pov
    learns = parsed?.learns ?? []
    learned = try container.decode([String].self)
  }
}

private struct ContractFixture: Decodable {
  let contracts: [ContractCase]
}

struct ContractParityTests {
  private static func load() throws -> [ContractCase] {
    try ReferenceFixture.decode(ContractFixture.self, from: "reveal/contract.json").contracts
  }

  @Test func shouldCarryAtLeastThreeHundredCases() throws {
    let cases = try Self.load()
    #expect(cases.count >= 300)
    #expect(cases.contains { $0.pov == nil } && cases.contains { $0.pov != nil })
  }

  @Test func shouldParseEveryFixtureContractAsTheReferenceDoes() throws {
    let mismatches = try Self.load().enumerated().filter { _, reference in
      guard let parsed = parseKnowledgeContract(reference.input) else { return reference.pov != nil }
      guard let pov = reference.pov else { return true }
      let learns = parsed.learns.map { [$0.entityKey, $0.factKey] }
      return !sameStrings(parsed.pov, pov) || learns.count != reference.learns.count || !zip(learns, reference.learns).allSatisfy { sameStrings($0, $1) }
    }.map(\.offset)
    #expect(mismatches.isEmpty, "contract differs for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldListTheLearnedFactKeysOfEveryFixtureContractAsTheReferenceDoes() throws {
    let mismatches = try Self.load().enumerated().filter { !sameStrings(learnedFactKeys($1.input), $1.learned) }.map(\.offset)
    #expect(mismatches.isEmpty, "learned keys differ for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }
}
