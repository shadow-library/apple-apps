import Foundation
import Testing

@testable import NovelForgeCore

struct WritePolicyParityTests {
  private static let fixture = Result { try WritePolicyFixture.load() }

  @Test func shouldHoldTheReferenceTables() throws {
    let tables = try Self.fixture.get().tables
    #expect(Set(OpType.allCases.filter(\.isDirectKind).map(\.rawValue)) == Set(tables.direct))
    #expect(OpType.allCases.compactMap { type in type.alwaysCardRule.map { [type.rawValue, $0.rawValue] } }.sorted { $0[0] < $1[0] } == tables.alwaysCard.sorted { $0[0] < $1[0] })
    let ideaPolicy = OpType.allCases.map { type -> [String] in
      switch type.ideaPolicy {
      case .idea: [type.rawValue, "idea"]
      case .card(let rule): [type.rawValue, rule.rawValue]
      }
    }
    #expect(ideaPolicy.sorted { $0[0] < $1[0] } == tables.ideaPolicy.sorted { $0[0] < $1[0] })
    #expect(OpSource.allCases.map(\.rawValue) == tables.sources)
  }

  @Test func shouldCoverEveryDispositionTheReferenceProduces() throws {
    let cases = try Self.fixture.get().cases
    let dispositions = Set(cases.flatMap(\.dispositions))
    for expected in ["d:quoted", "d:idea", "c:depends_on_card", "c:held_for_review", "c:novel_content", "c:removal", "c:tentative", "c:just_discussing", "c:manual_mode"] {
      #expect(dispositions.contains(expected), "no case produces \(expected)")
    }
    for rule in AlwaysCardRule.allCases where rule != .plannerOnlyField && rule != .notebookDirection {
      #expect(dispositions.contains("c:always_card:\(rule.rawValue)"), "no case produces the always-card rule \(rule.rawValue)")
    }
    #expect(Set(cases.map(\.held)) == Set(WriteHold.allCases.map(\.rawValue)))
  }

  @Test func shouldSplitChangeSetsAsTheReference() throws {
    _ = try #require(WritePolicy.shared)
    for (position, item) in try Self.fixture.get().cases.enumerated() {
      let input = try item.input
      let split = WritePolicy.split(input)
      #expect(split.dispositions.map(\.encoded) == item.dispositions, "case \(position): dispositions")
      #expect(split.held.rawValue == item.held, "case \(position): held")
      #expect(split.sources.map(\.rawValue) == item.sources, "case \(position): sources")
      #expect(split.dispositions.map(\.index) == Array(input.ops.indices), "case \(position): indices")
      #expect(split.ops == input.ops)
      #expect(split.direct == zip(input.ops, split.dispositions).filter { $1.side == .direct }.map(\.0), "case \(position): direct")
      #expect(split.cards == zip(input.ops, split.dispositions).filter { $1.side == .card }.map(\.0), "case \(position): cards")
    }
  }

  @Test func shouldJudgeEachOperationAsTheReference() throws {
    let policy = try #require(WritePolicy.shared)
    for (position, item) in try Self.fixture.get().cases.enumerated() {
      let input = try item.input
      let vocabulary = input.vocabulary ?? input.authorMessage
      #expect(input.ops.count == item.perOp.count)
      for (op, expected) in zip(input.ops, item.perOp) {
        let label = "case \(position) \(op.type.rawValue)"
        let current = input.state.fields(of: changeSetRefs([op]).first)
        #expect(alwaysCardRule(op, input.state)?.rawValue == expected.alwaysCardRule, "\(label): alwaysCardRule")
        #expect(ideaCardRule(op)?.rawValue == expected.ideaCardRule, "\(label): ideaCardRule")
        #expect(isPlannerSide(op) == expected.isPlannerSide, "\(label): isPlannerSide")
        #expect(CodeUnitStrings.equal(opReferences(op), expected.references), "\(label): opReferences \(opReferences(op)) vs \(expected.references)")
        #expect(policy.launders(op, current, vocabulary) == expected.launders, "\(label): launders")
        #expect(policy.exceedsNoveltyBudget(op, current, vocabulary) == expected.exceedsNovelty, "\(label): exceedsNoveltyBudget")
        #expect(policy.exceedsRemovalBudget(op, current) == expected.exceedsRemoval, "\(label): exceedsRemovalBudget")
      }
    }
  }
}
