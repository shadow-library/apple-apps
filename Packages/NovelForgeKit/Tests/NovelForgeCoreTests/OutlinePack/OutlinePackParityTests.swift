import Foundation
import Testing

@testable import NovelForgeCore

struct OutlinePackParityTests {
  private static let fixture = OutlinePackFixture.shared

  private static func same(_ actual: String?, _ expected: String?, _ label: String) {
    #expect(actual == expected, "\(label)\n--- actual\n\(actual ?? "nil")\n--- expected\n\(expected ?? "nil")")
  }

  @Test func shouldAssembleEachPackAsForOutlineDoes() async throws {
    for scenario in try Self.fixture.get().scenarios where scenario.spec.mode == "pack" {
      let spec = scenario.spec
      let store = try await OutlinePackWorld.build(spec)
      let pack = try await store.outlinePack(novel: OutlinePackWorld.novel, request: spec.request)
      let expected = scenario.expected
      #expect(pack.sections.map(\.key) == expected.sections?.map(\.key), "\(spec.name): sections")
      for (section, wanted) in zip(pack.sections, expected.sections ?? []) { Self.same(section.rendered, wanted.rendered, "\(spec.name) \(wanted.key)") }
      for (section, wanted) in zip(pack.sections, expected.sections ?? []) {
        #expect(section == wanted, "\(spec.name) \(wanted.key): fields")
      }
      #expect(pack.omitted == expected.omitted, "\(spec.name): omitted")
      #expect(pack.usedTokens == expected.usedTokens, "\(spec.name): used")
      #expect(pack.budgetTokens == expected.budgetTokens, "\(spec.name): budget")
      Self.same(pack.rendered, expected.rendered, "\(spec.name): rendered")
    }
  }

  @Test func shouldAssembleEachPlanContextAsThePlanCallReadsIt() async throws {
    for scenario in try Self.fixture.get().scenarios where scenario.spec.mode == "plan" {
      let spec = scenario.spec
      let store = try await OutlinePackWorld.build(spec)
      let context = try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: spec.chapter, budgetTokens: spec.budgetTokens ?? OutlinePack.budget)
      let expected = scenario.expected
      Self.same(context.catalog, expected.catalog, "\(spec.name): catalog")
      Self.same(renderObligations(context.obligations), expected.obligations, "\(spec.name): obligations")
      Self.same(context.milestones, expected.milestones, "\(spec.name): milestones")
      Self.same(context.claims.isEnding ? chapterPlanEnding : chapterPlanNotEnding, expected.endingNote, "\(spec.name): ending")
    }
  }

  @Test func shouldKeepTheReferenceBudgets() throws {
    let fixture = try Self.fixture.get()
    #expect(fixture.budget == OutlinePack.budget)
    #expect(fixture.timelineCap == OutlinePack.timelineCap)
  }

  @Test func shouldCoverTheWorldsThePlanTaskNames() throws {
    let names = try Self.fixture.get().scenarios.map(\.spec.name)
    for needed in ["first chapter", "mid volume", "volume end", "no milestones and an unplanned chapter", "many threads under budget pressure"] {
      #expect(names.contains(needed), "\(needed)")
    }
  }
}
