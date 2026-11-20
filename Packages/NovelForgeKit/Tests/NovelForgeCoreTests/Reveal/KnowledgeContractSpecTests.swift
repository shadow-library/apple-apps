import Foundation
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

struct KnowledgeContractSpecTests {
  @Test func shouldEchoAStoredKnowledgeContractInItsNarrowedShape() {
    let stored = object(
      ("pov", .array([.string("amara_veil")])),
      (
        "learns",
        .array([
          object(("entityKey", .string("amara_veil")), ("factKey", .string("rook_holds_the_slip"))),
          object(("entityKey", .string("amara_veil"))),
        ])
      ),
      ("extra", .bool(true))
    )

    #expect(parseKnowledgeContract(stored) == KnowledgeContract(pov: ["amara_veil"], learns: [KnowledgeReveal(entityKey: "amara_veil", factKey: "rook_holds_the_slip")]))
  }

  @Test func shouldAnswerNilForAStoredContractThatNamesNoPointOfViewEntity() {
    #expect(parseKnowledgeContract(object(("pov", .array([])), ("learns", .array([])))) == nil)
  }

  @Test func shouldKeepAContractWithNoLearns() {
    #expect(parseKnowledgeContract(object(("pov", .array([.string("amara_veil")])), ("learns", .array([])))) == KnowledgeContract(pov: ["amara_veil"], learns: []))
  }

  @Test func shouldAcceptFreeFormLearnKeys() {
    let stored = object(
      ("pov", .array([.string("amara-veil")])),
      ("learns", .array([object(("entityKey", .string("amara-veil")), ("factKey", .string("Rook holds the slip")))]))
    )

    #expect(parseKnowledgeContract(stored)?.learns.first?.factKey == "Rook holds the slip")
  }

  @Test func shouldRoundTripThroughJSONValue() throws {
    let contract = KnowledgeContract(pov: ["mira"], learns: [KnowledgeReveal(entityKey: "mira", factKey: "f")])
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(contract))

    #expect(value == .object(["pov": .array([.string("mira")]), "learns": .array([.object(["entityKey": .string("mira"), "factKey": .string("f")])])]))
    #expect(try JSONDecoder().decode(KnowledgeContract.self, from: JSONEncoder().encode(value)) == contract)
  }
}
