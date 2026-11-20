import ShadowText
import Testing

@testable import NovelForgeCore

private func ops(_ json: String) throws -> [OrderedJSONObject] { try #require(try OrderedJSON(parsing: json).chatOpsIfPresent) }

private func same(_ left: [OrderedJSONObject], _ right: [OrderedJSONObject]) -> Bool {
  left.map { OrderedJSON.object($0).jsonText } == right.map { OrderedJSON.object($0).jsonText }
}

struct ProseIntentParityTests {
  private static let fixture = Result { try ChatFixture.load("prose-intent.json") }

  @Test func shouldListTheSameOpsAndNotes() throws {
    let fixture = try Self.fixture.get()
    #expect(proseEditOps.map(\.rawValue) == fixture["ops"]?.items.map(\.text))
    #expect(proseEditWithheldNote.jsEquals(try #require(fixture["notes"]?["withheld"]).text))
    #expect(passageEditWithheldNote.jsEquals(try #require(fixture["notes"]?["passage"]).text))
  }

  @Test func shouldJudgeEveryChangeSetAsTheReference() throws {
    var withheldSeen = 0
    var dependentsSeen = 0
    for (position, item) in try #require(try Self.fixture.get()["cases"]).items.enumerated() {
      let changeSet = try #require(item["changeSet"])
      let list = changeSet.chatOps
      #expect(list.map(isProseEditOp) == item["isProse"]?.items.map(\.chatFlag), "isProse \(position)")
      #expect(proseEditIssues(changeSet.chatOpsIfPresent) == item["issues"]?.items.map(\.text), "issues \(position)")
      guard changeSet.chatOpsIfPresent != nil else { continue }
      #expect(proseWithheldNote(list).jsEquals(try #require(item["note"]).text), "note \(position)")
      let result = withoutProseEditOps(list)
      let keptIndices = try #require(item["kept"]).items.map(\.chatCount)
      #expect(same(result.kept, keptIndices.map { list[$0] }), "kept \(position)")
      #expect(result.withheld == item["withheld"]?.chatCount, "withheld \(position)")
      withheldSeen += result.withheld
      dependentsSeen += result.withheld - list.filter(isProseEditOp).count
    }
    #expect(withheldSeen > 50)
    #expect(dependentsSeen > 5)
  }
}

// apps/novel-forge-server/tests/refinement/prose-intent.spec.ts:5
struct ProseIntentSpecTests {
  @Test func shouldFlagEveryProseOpAndNothingElse() throws {
    let issues = proseEditIssues(
      try ops(
        #"[{"op":"brief.update","chapter":1,"body":"Purpose: arrive."},{"op":"draft.update","chapter":1,"body":"Orrin arrived."},{"op":"action.revise_draft","chapter":1,"note":"shorter"},{"op":"draft.rewrite_passage","chapter":1,"passage":"Orrin walked.","replacement":"Orrin ran."}]"#
      ))
    #expect(issues.count == 3)
    #expect(issues[0].hasPrefix("changeSet[1]: draft.update changes the chapter"))
    #expect(issues[1].hasPrefix("changeSet[2]: action.revise_draft"))
    #expect(
      issues[2]
        == "changeSet[3]: draft.rewrite_passage needs Edit prose, which is off — drop it, say in the reply what you would change, and suggest turning on Edit prose; never turn a passage comment into a brief.update."
    )
  }

  @Test func shouldKeepThePlanOpsAndCountWhatItWithheld() throws {
    let result = withoutProseEditOps(try ops(#"[{"op":"draft.remove","chapter":1},{"op":"brief.update","chapter":1}]"#))
    #expect(same(result.kept, try ops(#"[{"op":"brief.update","chapter":1}]"#)) && result.withheld == 1)
  }

  @Test func shouldWithholdAPassageRewriteWithTheApprovalThatLeanedOnIt() throws {
    let result = withoutProseEditOps(
      try ops(
        #"[{"op":"draft.rewrite_passage","chapter":3,"passage":"Orrin walked.","replacement":"Orrin ran."},{"op":"action.approve_draft","chapter":3},{"op":"brief.update","chapter":3}]"#
      ))
    #expect(same(result.kept, try ops(#"[{"op":"brief.update","chapter":3}]"#)) && result.withheld == 2)
  }

  @Test func shouldDropTheActionsThatDependedOnTheWithheldProse() throws {
    let result = withoutProseEditOps(
      try ops(
        #"[{"op":"draft.update","chapter":3,"body":"Orrin climbed."},{"op":"action.judge_draft","chapter":3},{"op":"action.approve_draft","chapter":3},{"op":"action.finalize","upTo":4},{"op":"action.finalize"},{"op":"brief.update","chapter":3},{"op":"action.approve_draft","chapter":2},{"op":"action.finalize","upTo":2}]"#
      ))
    let expected = try ops(#"[{"op":"brief.update","chapter":3},{"op":"action.approve_draft","chapter":2},{"op":"action.finalize","upTo":2}]"#)
    #expect(same(result.kept, expected) && result.withheld == 5)
  }

  @Test func shouldKeepEveryActionWhenNoProseOpWasWithheld() throws {
    let changeSet = try ops(#"[{"op":"action.finalize"},{"op":"action.approve_draft","chapter":3}]"#)
    let result = withoutProseEditOps(changeSet)
    #expect(same(result.kept, changeSet) && result.withheld == 0)
  }

  @Test func shouldSayThePassageWasLeftAsItIsWhenEveryWithheldOpRewroteAPassage() throws {
    let passage = #"{"op":"draft.rewrite_passage","chapter":3,"passage":"Orrin walked.","replacement":"Orrin ran."}"#
    #expect(proseWithheldNote(try ops("[\(passage),\(passage),{\"op\":\"brief.update\",\"chapter\":3}]")) == passageEditWithheldNote)
  }

  @Test func shouldPointAtThePlanWhenAWholeChapterEditOrARevisionWasWithheldToo() throws {
    let passage = #"{"op":"draft.rewrite_passage","chapter":3,"passage":"Orrin walked.","replacement":"Orrin ran."}"#
    #expect(proseWithheldNote(try ops("[\(passage),{\"op\":\"draft.update\",\"chapter\":3,\"body\":\"x\"}]")) == proseEditWithheldNote)
    #expect(proseWithheldNote(try ops(#"[{"op":"action.revise_draft","chapter":3,"note":"shorter"}]"#)) == proseEditWithheldNote)
    #expect(proseWithheldNote([]) == proseEditWithheldNote)
  }
}
