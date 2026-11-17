import Testing

@testable import NovelForgeCore

private struct Stored: StoredChangeOp {
  let op: ChangeOp?
  let problems: [String]
}

private func stored(_ json: String) throws -> [Stored] {
  try applyOps(json).map { Stored(op: $0, problems: []) }
}

private func present(_ hash: String) -> ArtifactState { ArtifactState(exists: true, revision: nil, contentHash: hash) }

private func states(_ entries: [String: ArtifactState]) -> [JSString: ArtifactState] {
  Dictionary(uniqueKeysWithValues: entries.map { (JSString($0.key), $0.value) })
}

private func steps(_ plan: ApplyPlan) throws -> [ApplyStep] {
  guard case .ready(let steps) = plan else { throw PlanTestError.conflicted }
  return steps
}

private enum PlanTestError: Error {
  case conflicted
}

@Suite("Apply plan")
struct ApplyPlanTests {
  private static let mixed = """
    {"op":"volume.remove","volumeKey":"a"},
    {"op":"milestone.remove","milestoneKey":"m"},
    {"op":"entity.upsert","entityKey":"x","type":"character","name":"X"},
    {"op":"action.finalize"},
    {"op":"volume.remove","volumeKey":"b"},
    {"op":"fact.upsert","factKey":"f","body":"F."},
    {"op":"milestone.remove","milestoneKey":"n"},
    {"op":"organise.rule","rule":"Keep it short.","optionId":"o1"}
    """

  private static let mixedStates = states([
    "volume:a": present("va"), "milestone:m": present("mm"), "entity:x": .missing, "volume:b": present("vb"), "fact:f": present("ff"), "milestone:n": present("mn"),
  ])

  // apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:13-16, proposal-apply.service.ts:173
  @Test func shouldRunRemovalsLastVolumesThenMilestonesThenActions() throws {
    let ops = try stored(Self.mixed)
    let plan = try ApplyPlanner.plan(ops, baseline: Self.mixedStates, current: Self.mixedStates, selection: .whole)
    #expect(try steps(plan).map(\.index) == [2, 5, 7, 0, 4, 1, 6, 3])
    #expect(try steps(plan).last?.disposition == .action(try #require(ops[3].op)))
    #expect(ApplyFrame.applyOrder(ops.map(\.op), [0, 1, 2, 4, 5, 6, 7]) == [2, 5, 7, 0, 4, 1, 6])
    #expect(
      ApplyFrame.removalsLast(["milestone.remove", "volume.remove", "fact.upsert"]) { OpType(rawValue: $0) ?? .organiseRule } == [
        "fact.upsert", "volume.remove", "milestone.remove",
      ])
  }

  @Test func shouldPlanOnlyTheSelectedIndexes() throws {
    let ops = try stored(Self.mixed)
    let plan = try ApplyPlanner.plan(ops, baseline: Self.mixedStates, current: Self.mixedStates, selection: .indexes([6, 2, 2, 0]))
    #expect(try steps(plan).map(\.index) == [2, 0, 6])
    #expect(plan.opResults().map(\.index) == [0, 2, 6])
    #expect(try ApplyPlanner.refs(of: ops, selection: .indexes([3, 7])) == [])
  }

  // proposal-apply.service.ts:241-247
  @Test func shouldRefuseAnEmptyOrOutOfRangeSelection() throws {
    let ops = try stored(Self.mixed)
    for selection in [ApplySelection.indexes([]), .indexes([8]), .indexes([-1]), .indexes([0, 8])] {
      #expect(throws: ApplyError.invalidSelection) { try ApplyPlanner.plan(ops, baseline: Self.mixedStates, current: Self.mixedStates, selection: selection) }
    }
  }

  // proposal-apply.service.ts:148-160, 302-321; the F11a rules: a missing, undecodable or unreadable entry conflicts the whole apply
  @Test func shouldConflictTheWholeApplyOnAnyMismatch() throws {
    let ops = try stored(Self.mixed)
    let cases: [(baseline: ArtifactState?, current: ArtifactState?)] = [
      (present("ff"), present("changed")), (nil, present("ff")), (.unreadable, present("ff")), (present("ff"), .unreadable), (.unreadable, .unreadable), (present("ff"), nil),
      (present("ff"), .missing), (.missing, present("ff")),
    ]
    for (expected, actual) in cases {
      var baseline = Self.mixedStates
      var current = Self.mixedStates
      baseline[JSString("fact:f")] = expected
      current[JSString("fact:f")] = actual
      let plan = try ApplyPlanner.plan(ops, baseline: baseline, current: current, selection: .whole)
      #expect(
        plan == .conflicted([BaselineMismatch(ref: "fact:f", expected: expected, actual: actual, indexes: [5])]), "\(String(describing: expected)) \(String(describing: actual))")
      #expect(plan.opResults().isEmpty)
    }
  }

  @Test func shouldIgnoreAMismatchOnAnUnselectedRef() throws {
    let ops = try stored(Self.mixed)
    var current = Self.mixedStates
    current[JSString("fact:f")] = present("changed")
    let plan = try ApplyPlanner.plan(ops, baseline: Self.mixedStates, current: current, selection: .indexes([2, 3]))
    #expect(try steps(plan).map(\.index) == [2, 3])
  }

  @Test func shouldListEveryIndexThatWritesAConflictedRef() throws {
    let ops = try stored(
      """
      {"op":"entity.upsert","entityKey":"ada","type":"character","notes":"N."},
      {"op":"fact.upsert","factKey":"f","body":"F.","subjects":["ada"]},
      {"op":"entity.upsert","entityKey":"ada","type":"character","status":"hiding"}
      """)
    let baseline = states(["entity:ada": present("a"), "fact:f": .missing])
    let current = states(["entity:ada": present("b"), "fact:f": .missing])
    let plan = try ApplyPlanner.plan(ops, baseline: baseline, current: current, selection: .whole)
    #expect(plan == .conflicted([BaselineMismatch(ref: "entity:ada", expected: present("a"), actual: present("b"), indexes: [0, 2])]))
  }

  // F03: a stored op that no longer validates is skipped with its problems, never thrown and never compared with the baseline
  @Test func shouldSkipAStoredOpThatFailsRevalidationWithItsProblems() throws {
    var ops = try stored(Self.mixed)
    ops[5] = Stored(op: nil, problems: ["changeSet[5].body: must be a string"])
    ops[1] = Stored(op: nil, problems: [])
    let baseline = Self.mixedStates.filter { $0.key != JSString("fact:f") }
    let plan = try ApplyPlanner.plan(ops, baseline: baseline, current: Self.mixedStates, selection: .whole)
    let all = try steps(plan)
    #expect(all.map(\.index) == [2, 7, 0, 4, 6, 3, 1, 5])
    #expect(all.suffix(2).map(\.disposition) == [.skip(problems: ["the stored operation could not be read"]), .skip(problems: ["changeSet[5].body: must be a string"])])
    let results = plan.opResults(sources: [.quoted, nil, .idea])
    #expect(results.first { $0.index == 5 } == OpResult(index: 5, status: .failed, source: nil, error: "changeSet[5].body: must be a string"))
    #expect(results.first { $0.index == 2 } == OpResult(index: 2, status: .applied, source: .idea))
    #expect(results.first { $0.index == 3 } == OpResult(index: 3, status: .pending, source: nil))
    #expect(results.first { $0.index == 0 }?.source == .quoted)
  }

  // proposal-apply.service.ts:73-80, 172-177, 305-317
  @Test func shouldLandAChaptersRewritesAsOneCallAndCompareOnlyTheirDraftsExistence() throws {
    let ops = try stored(
      """
      {"op":"draft.rewrite_passage","chapter":3,"passage":"one","replacement":"uno"},
      {"op":"entity.upsert","entityKey":"x","type":"character","name":"X"},
      {"op":"draft.rewrite_passage","chapter":3,"passage":"two","replacement":"dos"},
      {"op":"draft.rewrite_passage","chapter":4,"passage":"three","replacement":"tres"}
      """)
    let baseline = states(["draft:3": present("d3"), "draft:4": present("d4"), "entity:x": .missing])
    let current = states(["draft:3": present("edited"), "draft:4": present("d4"), "entity:x": .missing])
    let all = try steps(try ApplyPlanner.plan(ops, baseline: baseline, current: current, selection: .whole))
    guard case .draftRewritePassage(let one) = ops[0].op?.operation, case .draftRewritePassage(let two) = ops[2].op?.operation else {
      Issue.record("not rewrites")
      return
    }
    #expect(all[0] == ApplyStep(index: 0, disposition: .run(.passageRewrites(chapter: 3, [one, two]))))
    #expect(all[2] == ApplyStep(index: 2, disposition: .carried(by: 0)))
    #expect(all.map(\.index) == [0, 1, 2, 3])
    for gone in [ArtifactState.missing, .unreadable] {
      let moved = states(["draft:3": gone, "draft:4": present("d4"), "entity:x": .missing])
      #expect(
        try ApplyPlanner.plan(ops, baseline: baseline, current: moved, selection: .whole)
          == .conflicted([BaselineMismatch(ref: "draft:3", expected: present("d3"), actual: gone, indexes: [0, 2])]))
    }
    let undecodable = states(["draft:3": .unreadable, "draft:4": present("d4"), "entity:x": .missing])
    #expect(
      try ApplyPlanner.plan(ops, baseline: undecodable, current: current, selection: .whole)
        == .conflicted([BaselineMismatch(ref: "draft:3", expected: .unreadable, actual: present("edited"), indexes: [0, 2])]))
  }

  @Test func shouldCompareTheContentOfADraftAWholeRewriteAlsoTouches() throws {
    let ops = try stored(
      """
      {"op":"draft.rewrite_passage","chapter":3,"passage":"one","replacement":"uno"},
      {"op":"draft.update","chapter":3,"body":"All new."}
      """)
    let baseline = states(["draft:3": present("d3")])
    #expect(throws: ApplyError.rewriteBesideWholeDraft(chapter: 3)) { try ApplyPlanner.plan(ops, baseline: baseline, current: baseline, selection: .whole) }
    let current = states(["draft:3": present("edited")])
    #expect(
      try ApplyPlanner.plan(ops, baseline: baseline, current: current, selection: .whole)
        == .conflicted([BaselineMismatch(ref: "draft:3", expected: present("d3"), actual: present("edited"), indexes: [0, 1])]))
    let rewriteOnly = try ApplyPlanner.plan(ops, baseline: baseline, current: baseline, selection: .indexes([0]))
    #expect(try steps(rewriteOnly).map(\.index) == [0])
    let removal = try stored(
      """
      {"op":"draft.remove","chapter":3},
      {"op":"draft.rewrite_passage","chapter":3,"passage":"one","replacement":"uno"}
      """)
    #expect(throws: ApplyError.rewriteBesideWholeDraft(chapter: 3)) { try ApplyPlanner.plan(removal, baseline: baseline, current: baseline, selection: .whole) }
  }

  @Test func shouldLookTheBaselineAndCurrentStatesUpInNFC() throws {
    let ops = try stored(#"{"op":"entity.upsert","entityKey":"am\u00e9lie","type":"character","name":"Am\u00e9lie"}"#)
    let decomposed = states(["entity:ame\u{301}lie": present("a")])
    let composed = states(["entity:am\u{e9}lie": present("a")])
    #expect(try steps(try ApplyPlanner.plan(ops, baseline: decomposed, current: composed, selection: .whole)).map(\.index) == [0])
    #expect(
      try ApplyPlanner.plan(ops, baseline: decomposed, current: states(["entity:am\u{e9}lie": present("b")]), selection: .whole)
        == .conflicted([BaselineMismatch(ref: "entity:am\u{e9}lie", expected: present("a"), actual: present("b"), indexes: [0])]))
    let split = Dictionary(uniqueKeysWithValues: [(JSString("entity:ame\u{301}lie"), present("a")), (JSString("entity:am\u{e9}lie"), present("b"))])
    #expect(
      try ApplyPlanner.plan(ops, baseline: split, current: composed, selection: .whole)
        == .conflicted([BaselineMismatch(ref: "entity:am\u{e9}lie", expected: .unreadable, actual: present("a"), indexes: [0])]))
  }

  // content-op-handlers.ts:15-26
  @Test func shouldSendEveryContentOpToItsHandlerFile() {
    let expected: [OpType: ContentHandlerFile] = [
      .premiseUpdate: .story, .volumeUpsert: .story, .volumeRemove: .story, .factUpsert: .story, .factRemove: .story, .milestoneUpsert: .story, .milestoneRemove: .story,
      .promiseCreate: .story, .promiseUpdate: .story, .promiseSetPayoff: .story, .promiseDrop: .story, .bibleDocumentUpsert: .bible, .bibleDocumentRemove: .bible,
      .entityUpsert: .bible, .entityRemove: .bible, .briefUpdate: .plan, .briefRemove: .plan, .draftUpdate: .draft, .draftRemove: .draft,
      .draftRewritePassage: .draft, .organiseRule: .inline,
    ]
    for type in OpType.allCases { #expect(ApplyFrame.handlerFile(for: type) == expected[type], "\(type.rawValue)") }
  }
}
