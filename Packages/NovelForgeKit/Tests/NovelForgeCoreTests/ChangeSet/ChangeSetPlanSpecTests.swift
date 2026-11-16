import Foundation
import Testing

@testable import NovelForgeCore

struct ChangeSetPlanFieldsSpecTests {
  @Test func shouldAcceptEveryPlanFieldOnBriefUpdateAndNullWhereverItClearsOne() throws {
    let json = """
      [{"op": "brief.update", "chapter": 4, "direction": "The keeper refuses the bargain.", "contentMode": "unrestricted",
        "scenes": [{"summary": "The tide rises.", "pov": "mira"}, {"summary": "The lamp gutters."}], "claimedMilestones": ["mira_rank_2"], "isEnding": true},
       {"op": "brief.update", "chapter": 4, "direction": null, "contentMode": null, "scenes": null, "claimedMilestones": null, "isEnding": false}]
      """
    #expect(try csErrors(json).isEmpty)
  }

  @Test func shouldRejectMalformedPlanFields() throws {
    let json = """
      [{"op": "brief.update", "chapter": 4, "contentMode": "explicit"}, {"op": "brief.update", "chapter": 4, "isEnding": "yes"},
       {"op": "brief.update", "chapter": 4, "scenes": [{"summary": " ", "pov": "mira", "mood": "grim"}]}, {"op": "brief.update", "chapter": 4, "claimedMilestones": ["mira_rank_2", ""]}]
      """
    #expect(
      try csErrors(json) == [
        "changeSet[0]: contentMode must be one of standard, unrestricted",
        "changeSet[1]: invalid field 'isEnding' (expected boolean)",
        "changeSet[2]: scenes[0] has unexpected field 'mood'",
        "changeSet[2]: scenes[0].summary must be a non-empty string",
        "changeSet[3]: claimedMilestones must hold non-empty milestone keys",
      ])
  }

  @Test func shouldTolerateAStateOnVolumeUpsertWithoutActingOnIt() throws {
    #expect(try csErrors(#"[{"op": "volume.upsert", "volumeKey": "volume_1", "state": "goal_met"}]"#).isEmpty)
    #expect(try csErrors(#"[{"op": "volume.upsert", "volumeKey": "volume_1", "state": "done"}]"#).isEmpty)
  }

  @Test func shouldAcceptAFactUnlockConditionAndCluesAndNullForEither() throws {
    let unlock = #"{"all": [{"milestone": "mira_rank_2"}, {"volume": "volume_2"}, {"chapter": 9}, {"ending": true}]}"#
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "unlock": \#(unlock), "allowedClues": ["the lamp burns cold"]}]"#).isEmpty)
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "unlock": null, "allowedClues": null}]"#).isEmpty)
  }

  @Test func shouldRejectAMalformedUnlockConditionOrClueList() throws {
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "unlock": {"all": [{"chapter": 0}]}}]"#) == ["changeSet[0]: unlock.all[0].chapter must be an integer >= 1"])
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "allowedClues": ["the lamp burns cold", "  "]}]"#) == ["changeSet[0]: allowedClues must hold non-empty strings"])
    #expect(
      try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "allowedClues": "the lamp burns cold"}]"#) == ["changeSet[0]: invalid field 'allowedClues' (expected string[]|null)"])
  }

  @Test func shouldKeepAPluginOffABriefsStructureWhileLettingItWriteThePlansContent() throws {
    let json = """
      [{"op": "brief.update", "chapter": 4, "direction": "The keeper refuses.", "scenes": [{"summary": "The tide rises."}]},
       {"op": "brief.update", "chapter": 4, "contentMode": "unrestricted", "claimedMilestones": ["mira_rank_2"], "isEnding": true}]
      """
    #expect(
      try csPluginErrors(json) == [
        "changeSet[1]: field 'contentMode' is not allowed for this scope",
        "changeSet[1]: field 'claimedMilestones' is not allowed for this scope",
        "changeSet[1]: field 'isEnding' is not allowed for this scope",
      ])
  }

  @Test func shouldShowTheModelTheUnlockShapeAndThePlanFields() {
    let vocabulary = renderOpVocabulary([.briefUpdate, .factUpsert, .volumeUpsert])
    #expect(vocabulary.contains(#""unlock": <object|null, optional>"#))
    #expect(vocabulary.contains(#"{"ending": true}"#))
    #expect(vocabulary.contains(#""isEnding": <boolean, optional>"#))
    #expect(vocabulary.contains(#"its state moves only through "goal met — start next""#))
  }
}

struct ChangeSetMilestoneSpecTests {
  @Test func shouldAcceptAMilestoneUpsertAndRemovalAndASubjectClearedWithNull() throws {
    let json = """
      [{"op": "milestone.upsert", "milestoneKey": "lamp_rank_4", "label": "Mira reaches the fourth rank", "kind": "rank", "subjectEntityKey": "mira"},
       {"op": "milestone.upsert", "milestoneKey": "tide_turns", "subjectEntityKey": null}, {"op": "milestone.remove", "milestoneKey": "old_rank"}]
      """
    #expect(try csErrors(json).isEmpty)
  }

  @Test func shouldRejectAnUnknownKindABlankLabelAStateTheOpMayNotSetAndAKeyWithSpaces() throws {
    let json = """
      [{"op": "milestone.upsert", "milestoneKey": "lamp_rank_4", "kind": "level"}, {"op": "milestone.upsert", "milestoneKey": "lamp_rank_4", "label": "  "},
       {"op": "milestone.upsert", "milestoneKey": "lamp_rank_4", "state": "reached"}, {"op": "milestone.remove", "milestoneKey": "lamp rank 4"}]
      """
    #expect(
      try csErrors(json) == [
        "changeSet[0]: kind must be one of rank, event, learned_from, custom",
        "changeSet[1]: label must not be blank",
        "changeSet[2]: unexpected field 'state'",
        "changeSet[3]: milestoneKey must be a non-empty key without spaces",
      ])
  }

  @Test func shouldKeepMilestonesOutOfAPluginChangeSet() throws {
    #expect(
      try csPluginErrors(#"[{"op": "milestone.upsert", "milestoneKey": "lamp_rank_4", "label": "Fourth rank"}]"#) == [
        "changeSet[0]: op 'milestone.upsert' is not allowed for this scope"
      ])
  }
}

struct ChangeSetPassageRewriteSpecTests {
  private static let anchor =
    #"{"draftId": "3", "revision": 1, "saveSeq": 0, "start": 10, "end": 32, "passageHash": "abc", "paragraph": 2, "contextBefore": "The salle. ", "contextAfter": " Again."}"#
  private static let malformed = "changeSet[0]: anchor must be {draftId, revision, saveSeq, start, end, passageHash, paragraph, contextBefore, contextAfter} with end after start"

  private func rewrite(_ extra: String = "") -> String {
    #"[{"op": "draft.rewrite_passage", "chapter": 3, "passage": "Corin flexed his hand.", "replacement": "Corin rolled his wrist."\#(extra)}]"#
  }

  @Test func shouldAcceptARewriteWithOrWithoutItsStagedAnchorLabelAndCommentNumber() throws {
    #expect(try csErrors(rewrite()).isEmpty)
    #expect(try csErrors(rewrite(#", "label": "the wrist", "contextIndex": 1, "anchor": \#(Self.anchor)"#)).isEmpty)
  }

  @Test func shouldRefuseABlankPassage() throws {
    #expect(try csErrors(rewrite().replacingOccurrences(of: "Corin flexed his hand.", with: "  ")).contains("changeSet[0]: passage must not be blank"))
  }

  @Test func shouldRefuseACommentNumberBelowOne() throws {
    #expect(try csErrors(rewrite(#", "contextIndex": 0"#)).contains("changeSet[0]: contextIndex must be >= 1"))
  }

  @Test func shouldRefuseAnAnchorThatIsNotOne() throws {
    let anchors = [
      Self.anchor.replacingOccurrences(of: #""end": 32"#, with: #""end": 4"#),
      Self.anchor.replacingOccurrences(of: #""draftId": "3", "#, with: ""),
      Self.anchor.replacingOccurrences(of: #", "contextAfter": " Again.""#, with: ""),
    ]
    for anchor in anchors { #expect(try csErrors(rewrite(#", "anchor": \#(anchor)"#)).contains(Self.malformed)) }
  }

  @Test func shouldTouchTheChaptersDraftAndShowTheModelThePassageNeverTheAnchorNorAQuote() throws {
    let vocabulary = renderOpVocabulary([.draftRewritePassage], OpVocabularyOptions(quotes: true))
    #expect(
      vocabulary.contains(
        #"{"op": "draft.rewrite_passage", "chapter": <number, required>, "passage": <string, required>, "replacement": <string, required>, "label": <string, optional>, "contextIndex": <number, optional>, "rationale": <string, optional>}"#
      ))
  }

  @Test func shouldRefuseDraftUpdatesAndPromiseOpsCarryingFieldsOnlyTheRevertEngineCarries() throws {
    for (field, value) in [("isolated", "false"), ("generator", #""standard""#)] {
      #expect(try csErrors(#"[{"op": "draft.update", "chapter": 4, "body": "The ferry leaves.", "\#(field)": \#(value)}]"#).contains("changeSet[0]: unexpected field '\(field)'"))
    }
    let promises = [
      ("hardDelete", #"{"op": "promise.drop", "kind": "thread", "key": "ledger", "hardDelete": true}"#),
      ("restoreStatus", #"{"op": "promise.update", "kind": "thread", "key": "ledger", "restoreStatus": "dropped"}"#),
      ("restoreLastAdvancedChapter", #"{"op": "promise.update", "kind": "thread", "key": "ledger", "restoreLastAdvancedChapter": 3}"#),
      ("restoreLabel", #"{"op": "promise.update", "kind": "thread", "key": "ledger", "restoreLabel": null}"#),
      ("restoreChapterColumn", #"{"op": "promise.update", "kind": "thread", "key": "ledger", "restoreChapterColumn": 5}"#),
    ]
    for (field, op) in promises { #expect(try csErrors("[\(op)]").contains("changeSet[0]: unexpected field '\(field)'")) }
  }
}

struct ChangeSetRemovedVocabularySpecTests {
  @Test func shouldRefuseTheRemovedPlanningVocabularyAsUnknownOps() throws {
    let removed = [
      #"{"op": "arc.upsert", "arcKey": "a1", "volumeKey": "v1"}"#, #"{"op": "arc.remove", "arcKey": "a1"}"#,
      #"{"op": "action.plan_volumes", "volumeCount": 2, "chaptersPerVolume": 10}"#,
      #"{"op": "action.plan_arcs", "volumeKey": "v1"}"#, #"{"op": "action.outline_arc", "arcKey": "a1"}"#, #"{"op": "action.approve_volume_plan"}"#,
      #"{"op": "action.approve_arcs", "volumeKey": "v1"}"#, #"{"op": "action.generate_chapters", "count": 2}"#,
    ]
    for op in removed { #expect(try csErrors("[\(op)]").first?.contains("unknown op") == true) }
  }

  @Test func shouldRefuseAVolumeUpsertThatSetsAFieldSinceAVolumeIsOnlyAGoal() throws {
    for field in ["conflict", "payoff", "targetChapterCount", "cast", "startChapter"] {
      #expect(try csErrors(#"[{"op": "volume.upsert", "volumeKey": "v1", "\#(field)": 1}]"#).contains("changeSet[0]: unexpected field '\(field)'"))
    }
  }

  @Test func shouldRefuseAnArcKeyOnABrief() throws {
    #expect(try csErrors(#"[{"op": "brief.update", "chapter": 3, "arcKey": "a1"}]"#).contains("changeSet[0]: unexpected field 'arcKey'"))
  }

  @Test func shouldKeepAPluginFromMovingABriefToAnotherVolume() throws {
    #expect(try csPluginErrors(#"[{"op": "brief.update", "chapter": 3, "volumeKey": "v2"}]"#).contains("changeSet[0]: field 'volumeKey' is not allowed for this scope"))
    #expect(try csPluginErrors(#"[{"op": "brief.update", "chapter": 3, "body": "x"}]"#).isEmpty)
  }
}
