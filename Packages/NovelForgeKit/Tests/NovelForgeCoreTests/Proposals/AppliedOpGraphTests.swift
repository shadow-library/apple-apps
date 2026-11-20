import ShadowText
import Testing

@testable import NovelForgeCore

// apps/novel-forge-server/tests/refinement/op-undo.spec.ts:6-12
private let specOps = """
  {"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara"},
  {"op":"fact.upsert","factKey":"mara-debt","body":"Mara owes the guild.","subjects":["mara"]},
  {"op":"entity.upsert","entityKey":"ada","type":"character","notes":"Ada keeps the slip."},
  {"op":"entity.upsert","entityKey":"ada","type":"character","status":"hiding"},
  {"op":"milestone.upsert","milestoneKey":"mara-leaves","label":"Mara leaves","subjectEntityKey":"mara"}
  """
private let all = [0, 1, 2, 3, 4]

@Suite("Applied op graph")
struct AppliedOpGraphTests {
  // op-undo.spec.ts:15-17
  private func graph() throws -> AppliedOpGraph {
    AppliedOpGraph(ops: try applyOps(specOps), existing: ["entity:ada"], order: all)
  }

  // op-undo.spec.ts:20-22
  @Test func shouldListEveryAppliedChangeNamingARecordTheUndoneChangeCreatedLatestFirst() throws {
    #expect(try graph().dependents(0, applied: all) == [4, 1])
  }

  // op-undo.spec.ts:24-27
  @Test func shouldListALaterChangeToTheSameRecordAsADependentOfAnEarlierOne() throws {
    #expect(try graph().dependents(2, applied: all) == [3])
    #expect(try graph().dependents(3, applied: all) == [])
  }

  // op-undo.spec.ts:29-31
  @Test func shouldListNoDependentsForAChangeNothingElseReliesOn() throws {
    #expect(try graph().dependents(1, applied: all) == [])
  }

  // op-undo.spec.ts:33-35
  @Test func shouldIgnoreDependentsAlreadyUndone() throws {
    #expect(try graph().dependents(0, applied: [0, 2, 3]) == [])
  }

  // op-undo.spec.ts:37-41
  @Test func shouldNeedBackWhatAChangeReliesOnAndAnEarlierChangeToItsRecordBeforeRedoingIt() throws {
    #expect(try graph().prerequisites(4, undone: [0, 4], applied: [1, 2, 3]) == [0])
    #expect(try graph().prerequisites(3, undone: [2, 3], applied: [0, 1, 4]) == [2])
    #expect(try graph().prerequisites(2, undone: [2, 3], applied: [0, 1, 4]) == [])
  }

  @Test func shouldCountARefTheBaselineRecordsAsExistingEvenWhenUnreadable() throws {
    let ops = try applyOps(specOps)
    let unreadable = AppliedOpGraph(ops: ops, baseline: ArtifactStates([JSString("entity:mara"): .unreadable, JSString("entity:ada"): .missing]), order: all)
    #expect(unreadable.dependents(0, applied: all) == [])
    #expect(unreadable.dependents(2, applied: all) == [3])
    let missing = AppliedOpGraph(ops: ops, baseline: ArtifactStates([JSString("entity:mara"): .missing]), order: all)
    #expect(missing.dependents(0, applied: all) == [4, 1])
  }

  @Test func shouldReadTheBaselineAsTheVaultKeysItInNFC() throws {
    let ops = try applyOps(
      """
      {"op":"entity.upsert","entityKey":"am\u{e9}lie","type":"character","name":"Am\u{e9}lie"},
      {"op":"fact.upsert","factKey":"debt","body":"She owes.","subjects":["am\u{e9}lie"]}
      """)
    let decomposed = JSString("entity:ame\u{301}lie")
    let present = ArtifactStates([decomposed: ArtifactState(exists: true, revision: nil, contentHash: "h")])
    #expect(AppliedOpGraph(ops: ops, baseline: present, order: [0, 1]).dependents(0, applied: [0, 1]) == [])
    #expect(AppliedOpGraph(ops: ops, baseline: ArtifactStates([decomposed: .missing]), order: [0, 1]).dependents(0, applied: [0, 1]) == [1])
  }

  @Test func shouldNeverListAnIndexWhoseStoredOpDoesNotValidate() throws {
    let parsed = try applyOps(specOps)
    let ops: [ChangeOp?] = [parsed[0], nil, parsed[2], parsed[3], parsed[4]]
    let graph = AppliedOpGraph(ops: ops, existing: ["entity:ada"], order: [0, 2, 3, 4])
    #expect(graph.dependents(0, applied: all) == [4])
    #expect(graph.dependents(1, applied: all) == [])
    #expect(graph.prerequisites(4, undone: [0, 1, 4], applied: [2, 3]) == [0])
  }

  @Test func shouldOrderByTheRunNotTheIndexWhenRemovalsRanLast() throws {
    let ops = try applyOps(
      """
      {"op":"milestone.remove","milestoneKey":"m"},
      {"op":"milestone.upsert","milestoneKey":"m","label":"M"}
      """)
    let order = ApplyFrame.applyOrder(ops, [0, 1])
    #expect(order == [1, 0])
    let graph = AppliedOpGraph(ops: ops, existing: ["milestone:m"], order: order)
    #expect(graph.dependents(1, applied: [0, 1]) == [0])
    #expect(graph.dependents(0, applied: [0, 1]) == [])
  }
}
