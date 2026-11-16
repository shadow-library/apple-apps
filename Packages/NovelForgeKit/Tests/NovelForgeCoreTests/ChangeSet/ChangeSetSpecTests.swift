import Foundation
import Testing

@testable import NovelForgeCore

struct ChangeSetValidationSpecTests {
  @Test func shouldAcceptAWellFormedChangeSet() throws {
    #expect(try csErrors(csValidOps).isEmpty)
  }

  @Test func shouldRejectNonArraysAndEmptyChangeSets() throws {
    #expect(try csErrors("{}") == ["changeSet must be an array of operations"])
    #expect(try csErrors("[]") == ["changeSet must contain at least one operation"])
  }

  @Test func shouldRejectUnknownOpsAndUnexpectedFields() throws {
    #expect(try csErrors(#"[{"op": "chapter.delete", "chapter": 1}]"#).first?.contains("unknown op 'chapter.delete'") == true)
    #expect(try csErrors(#"[{"op": "volume.remove", "volumeKey": "vol_1", "extra": true}]"#).first?.contains("unexpected field 'extra'") == true)
  }

  @Test func shouldRejectMissingRequiredFieldsAndWrongTypes() throws {
    #expect(try csErrors(#"[{"op": "volume.upsert", "title": "Ascent"}]"#).first?.contains("required field 'volumeKey'") == true)
    #expect(try csErrors(#"[{"op": "brief.update", "chapter": "three"}]"#).first?.contains("required field 'chapter'") == true)
    #expect(try csErrors(#"[{"op": "premise.update", "themes": "revenge"}]"#).first?.contains("invalid field 'themes'") == true)
  }

  @Test func shouldEnforceTheScopeAllowlist() throws {
    let errors = try csErrors(#"[{"op": "volume.upsert", "volumeKey": "vol_1"}]"#, allowed: [.briefUpdate])
    #expect(errors.first?.contains("not allowed for this scope") == true)
  }

  @Test func shouldAcceptClosureHookTypesOnEndingContracts() throws {
    for hookType in ["closure_with_momentum", "earned_rest"] {
      let json = #"[{"op": "brief.update", "chapter": 1, "endingContract": {"hookType": "\#(hookType)", "emotionalBeat": "calm", "openQuestion": "x", "handoffState": "y"}}]"#
      #expect(try csErrors(json).isEmpty)
    }
  }

  @Test func shouldValidateEndingContractsAndBibleSections() throws {
    let contract = #"[{"op": "brief.update", "chapter": 1, "endingContract": {"hookType": "happy_end", "emotionalBeat": "joy", "openQuestion": "x", "handoffState": "y"}}]"#
    #expect(try csErrors(contract).first?.contains("hookType") == true)
    #expect(try csErrors(#"[{"op": "bible_document.remove", "section": "poetry", "slug": "x"}]"#).first?.contains("section must be one of") == true)
  }

  @Test func shouldNormalizePathStyleBibleDocumentRefsLocalModelsEmit() throws {
    let cases: [(input: String, repaired: String)] = [
      (
        #"{"op": "bible_document.upsert", "section": "project/premise", "slug": "project/premise", "body": "x"}"#,
        #"{"op": "bible_document.upsert", "section": "project", "slug": "premise", "body": "x"}"#
      ),
      (#"{"op": "bible_document.remove", "section": "world", "slug": "world/factions"}"#, #"{"op": "bible_document.remove", "section": "world", "slug": "factions"}"#),
      (
        #"{"op": "bible_document.upsert", "section": "doc:plot/ending-vision", "slug": "doc:plot/ending-vision", "body": "x"}"#,
        #"{"op": "bible_document.upsert", "section": "plot", "slug": "ending-vision", "body": "x"}"#
      ),
    ]
    for item in cases {
      let result = validateChangeSet(try csParse("[\(item.input)]"))
      #expect(result.errors.isEmpty)
      #expect(result.value == (try csParse("[\(item.repaired)]")))
    }
    #expect(try csErrors(#"[{"op": "bible_document.remove", "section": "poetry/haiku", "slug": "haiku"}]"#).first?.contains("section must be one of") == true)
  }
}

struct ChangeSetTitleAndHubSpecTests {
  @Test func shouldRefuseATitleOnPremiseUpdateForEveryScope() throws {
    let rename = #"[{"op": "premise.update", "title": "A Name The Chat Chose"}]"#
    #expect(try csErrors(rename) == ["changeSet[0]: unexpected field 'title'"])
    #expect(try csErrors(rename, allowed: [.premiseUpdate, .bibleDocumentUpsert]) == ["changeSet[0]: unexpected field 'title'"])
  }

  @Test func shouldLeaveTheRestOfPremiseUpdateAlone() throws {
    #expect(try csErrors(#"[{"op": "premise.update", "premise": "a clerk audits the dead"}]"#).isEmpty)
  }

  @Test func shouldNotAdvertiseATitleField() {
    let vocabulary = renderOpVocabulary([.premiseUpdate])
    #expect(vocabulary.contains(#""premise": <string, optional>"#))
    #expect(!vocabulary.contains(#""title""#))
  }

  @Test func shouldAcceptWellFormedDraftBriefRemoveAndActionOps() throws {
    let ops = """
      [{"op": "draft.update", "chapter": 4, "body": "rewritten prose"}, {"op": "brief.remove", "chapter": 9}, {"op": "action.generate_chapter", "chapter": 5},
       {"op": "action.revise_draft", "chapter": 4, "note": "tighten the pacing"}, {"op": "action.validate", "scope": "chapter", "chapter": 4}, {"op": "action.finalize", "upTo": 3},
       {"op": "action.advance_volume", "volumeKey": "v1"}, {"op": "action.apply_continuity", "chapter": 4}]
      """
    #expect(try csErrors(ops).isEmpty)
  }

  @Test func shouldRejectMalformedHubOps() throws {
    #expect(try csErrors(#"[{"op": "draft.update", "chapter": 4}]"#).first?.contains("at least one of title, body, summary") == true)
    #expect(try csErrors(#"[{"op": "action.generate_chapter", "chapter": 0}]"#).first?.contains("chapter must be >= 1") == true)
    #expect(try csErrors(#"[{"op": "action.validate", "scope": "volume"}]"#).first?.contains("scope must be one of novel, chapter") == true)
    #expect(try csErrors(#"[{"op": "action.revise_draft", "chapter": 4}]"#).first?.contains("required field 'note'") == true)
    #expect(try csErrors(#"[{"op": "action.audit_bible", "target": "all"}]"#).first?.contains("unexpected field 'target'") == true)
    #expect(try csErrors(#"[{"op": "action.advance_volume"}]"#).first?.contains("required field 'volumeKey'") == true)
    #expect(try csErrors(#"[{"op": "action.apply_continuity"}]"#).first?.contains("required field 'chapter'") == true)
  }

  @Test func shouldClassifyActionOpsAndRenderTheirVocabularyWithPurposes() throws {
    #expect(isActionOp(try csOp(#"{"op": "action.audit_bible"}"#)))
    #expect(!isActionOp(try csOp(#"{"op": "draft.update", "chapter": 1, "body": "x"}"#)))
    let rendered = renderActionVocabulary(OpType.actions)
    for action in OpType.actions { #expect(rendered.contains(#""op": "\#(action.rawValue)""#)) }
    #expect(rendered.contains("never auto-applied"))
  }
}

struct ChangeSetEpistemicSpecTests {
  @Test func shouldAcceptWellFormedFactOpsAndKnowledgeContracts() throws {
    let ops = """
      [{"op": "fact.upsert", "factKey": "heir_is_illegitimate", "body": "the heir is not the duke’s son", "subjects": ["heir"], "constraintNote": "never let the duke look at him twice",
        "terms": ["bastard", "birth ledger"], "revealChapter": 41},
       {"op": "fact.remove", "factKey": "stale_secret"},
       {"op": "brief.update", "chapter": 41, "knowledgeContract": {"pov": ["heir"], "learns": [{"entityKey": "heir", "factKey": "heir_is_illegitimate"}]}},
       {"op": "brief.update", "chapter": 42, "knowledgeContract": {"pov": ["heir", "duchess"]}},
       {"op": "brief.update", "chapter": 43, "knowledgeContract": null}]
      """
    #expect(try csErrors(ops).isEmpty)
  }

  @Test func shouldAcceptAnExplicitNullRevealChapterAsDistinctFromOmittingIt() throws {
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "revealChapter": null}]"#).isEmpty)
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1"}]"#).isEmpty)
    let nulled = try csOp(#"{"op": "fact.upsert", "factKey": "f1", "revealChapter": null}"#)
    let omitted = try csOp(#"{"op": "fact.upsert", "factKey": "f1"}"#)
    #expect(nulled != omitted)
  }

  @Test func shouldRejectMalformedFactOps() throws {
    #expect(try csErrors(#"[{"op": "fact.upsert"}]"#).first?.contains("required field 'factKey'") == true)
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "terms": "bastard"}]"#).first?.contains("invalid field 'terms'") == true)
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "revealChapter": 0}]"#).first?.contains("revealChapter must be >= 1") == true)
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "revealChapter": "soon"}]"#).first?.contains("invalid field 'revealChapter' (expected number|null)") == true)
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f1", "source": "brief_reveal"}]"#).first?.contains("unexpected field 'source'") == true)
    #expect(try csErrors(#"[{"op": "fact.remove", "factKey": "f1", "entityKey": "heir"}]"#).first?.contains("unexpected field 'entityKey'") == true)
  }

  @Test func shouldRejectMalformedKnowledgeContracts() throws {
    func first(_ contract: String) throws -> String? {
      try csErrors(#"[{"op": "brief.update", "chapter": 1, "knowledgeContract": \#(contract)}]"#).first
    }
    #expect(try first(#""heir""#)?.contains("invalid field 'knowledgeContract' (expected object|null)") == true)
    #expect(try first(#"{"learns": []}"#)?.contains("knowledgeContract.pov must be a non-empty array") == true)
    #expect(try first(#"{"pov": []}"#)?.contains("knowledgeContract.pov must be a non-empty array") == true)
    #expect(try first(#"{"pov": [""]}"#)?.contains("knowledgeContract.pov must be a non-empty array") == true)
    #expect(try first(#"{"pov": ["heir"], "learns": {}}"#)?.contains("knowledgeContract.learns must be an array") == true)
    #expect(try first(#"{"pov": ["heir"], "learns": [{"entityKey": "heir"}]}"#)?.contains("learns[0].factKey must be a non-empty string") == true)
    #expect(try first(#"{"pov": ["heir"], "learns": [{"entityKey": "heir", "factKey": "f1", "chapter": 3}]}"#)?.contains("learns[0]: unexpected field 'chapter'") == true)
    #expect(try first(#"{"pov": ["heir"], "reveals": []}"#)?.contains("unexpected field 'knowledgeContract.reveals'") == true)
  }

  @Test func shouldRenderTheFactAndKnowledgeContractVocabularyOnlyForTheScopesThatAllowThem() {
    let rendered = renderOpVocabulary([.factUpsert, .factRemove, .briefUpdate])
    #expect(rendered.contains(#""op": "fact.upsert", "factKey": <string, required>"#))
    #expect(rendered.contains(#""revealChapter": <number|null, optional>"#))
    #expect(rendered.contains(#""pov": <non-empty array of entity keys>"#))
    #expect(rendered.contains("NEVER in bible prose"))
    #expect(rendered.contains("the reveal schedule IS the plot"))
    #expect(rendered.contains("pass null to undate the fact — an undated fact without an unlock stays hidden and no plan may reveal it"))
    #expect(!renderOpVocabulary([.volumeUpsert]).contains("knowledgeContract"))
    #expect(!renderOpVocabulary([.briefUpdate]).contains("spoiler ledger"))
  }

  @Test func shouldAcceptTheStartedEmptyMarkOnAPlanAndNeverShowItToAModel() throws {
    #expect(try csErrors(#"[{"op": "brief.update", "chapter": 4, "body": "", "startedEmpty": true}]"#).isEmpty)
    #expect(try !csErrors(#"[{"op": "volume.upsert", "volumeKey": "v1", "startedEmpty": true}]"#).isEmpty)
    #expect(!renderOpVocabulary([.briefUpdate]).contains("startedEmpty"))
  }

  @Test func shouldAcceptARationaleOnContentActionAndScopeRestrictedOpsAlike() throws {
    let ops = """
      [{"op": "premise.update", "premise": "sharper", "rationale": "the pitch buried the hook"}, {"op": "brief.update", "chapter": 3, "body": "a brief", "rationale": "the chapter had no brief"},
       {"op": "action.generate_chapter", "chapter": 2, "rationale": "the plan is ready"}]
      """
    #expect(try csErrors(ops).isEmpty)
    #expect(try csErrors(#"[{"op": "brief.update", "chapter": 3, "rationale": "why"}]"#, allowed: [.briefUpdate]).isEmpty)
  }

  @Test func shouldRejectARationaleThatIsNotAString() throws {
    #expect(try csErrors(#"[{"op": "fact.remove", "factKey": "f1", "rationale": 3}]"#).first?.contains("invalid field 'rationale'") == true)
  }

  @Test func shouldAdvertiseTheRationaleFieldOnceForEveryOpItRenders() {
    let rendered = renderOpVocabulary([.factUpsert, .briefUpdate])
    #expect(rendered.components(separatedBy: #""rationale": <string, optional>"#).count - 1 == 2)
    #expect(rendered.contains("never written into the story itself"))
    #expect(renderActionVocabulary([.actionAuditBible]).contains(#""rationale": <string, optional>"#))
  }
}

struct ChangeSetRefsSpecTests {
  @Test func shouldDeriveDeduplicatedArtifactRefs() throws {
    let ops = try csOps(csValidOps) + [csOp(#"{"op": "volume.remove", "volumeKey": "vol_1"}"#)]
    #expect(changeSetRefs(ops) == ["premise", "doc:project/reader-promise", "volume:vol_1", "chapter:3"])
  }

  @Test func shouldMapDraftOpsToDraftRefsAndActionsToNone() throws {
    let ops = try csOps(
      #"[{"op": "draft.update", "chapter": 4, "body": "x"}, {"op": "brief.remove", "chapter": 9}, {"op": "action.generate_chapter", "chapter": 5}, {"op": "action.audit_bible"}]"#)
    #expect(changeSetRefs(ops) == ["draft:4", "chapter:9"])
  }

  @Test func shouldMapFactOpsToFactRefs() throws {
    let ops = try csOps(
      #"[{"op": "fact.upsert", "factKey": "heir_is_illegitimate", "body": "x"}, {"op": "fact.remove", "factKey": "heir_is_illegitimate"}, {"op": "fact.remove", "factKey": "stale_secret"}]"#
    )
    #expect(changeSetRefs(ops) == ["fact:heir_is_illegitimate", "fact:stale_secret"])
  }

  @Test func shouldKeyAPlanOncePerChatAndEveryOtherActionByItsTarget() throws {
    let ops = try csOps(
      """
      [{"op": "action.plan_chapter", "chapter": 2}, {"op": "action.approve_draft", "chapter": 3}, {"op": "action.advance_volume", "volumeKey": "v1"}, {"op": "action.audit_bible"},
       {"op": "fact.upsert", "factKey": "f1", "revealChapter": null}]
      """)
    #expect(actionDecisionKeys(ops) == ["action.plan_chapter", "action.approve_draft:3", "action.advance_volume:v1", "action.audit_bible"])
  }

  @Test func shouldReadDeclaredFieldsAndGiveNothingForOnesTheOpLacks() throws {
    let fields = opFields(try csOp(#"{"op": "volume.remove", "volumeKey": "vol_1"}"#))
    #expect(fields["volumeKey"] == .string("vol_1"))
    #expect(fields["objective"] == nil)
  }

  @Test func shouldMapMilestoneRemovalToAMilestoneRef() throws {
    #expect(changeSetRefs(try csOps(#"[{"op": "milestone.remove", "milestoneKey": "lamp_rank_4"}]"#)) == ["milestone:lamp_rank_4"])
  }

  @Test func shouldMapPassageRewritesToTheChaptersDraft() throws {
    let rewrite = try csOp(#"{"op": "draft.rewrite_passage", "chapter": 3, "passage": "Corin flexed his hand.", "replacement": "Corin rolled his wrist."}"#)
    #expect(changeSetRefs([rewrite]) == ["draft:3"])
  }
}

struct ChangeSetParseSpecTests {
  @Test func shouldReturnTheSameOpsWhenTheChangeSetIsWellFormed() throws {
    #expect(try csOps(csValidOps).count == 4)
  }

  @Test func shouldThrowTheRejectionForWhateverValidateChangeSetRejects() throws {
    for raw in ["{}", "[]", #"[{"op": "chapter.delete", "chapter": 1}]"#, #"[{"op": "volume.remove", "volumeKey": "vol_1", "extra": true}]"#, "[null]"] {
      #expect(try !csErrors(raw).isEmpty)
      #expect(throws: ChangeSetError.self) { try csOps(raw) }
    }
  }

  @Test func shouldEnforceTheAllowedOpsAndTheEntityMaterializationOptionItIsGiven() throws {
    #expect(throws: ChangeSetError.self) { try csOps(csValidOps, allowed: [.premiseUpdate]) }
    let prose = #"[{"op": "bible_document.upsert", "section": "power", "slug": "system-and-limits", "body": "A long backstory."}]"#
    #expect(try !csErrors(prose).isEmpty)
    #expect(throws: ChangeSetError.self) { try csOps(prose) }
    #expect(try csOps(prose, options: ChangeSetValidationOptions(entityMaterialization: false)).count == 1)
  }

  @Test func shouldTreatAMissingOrEmptyOptionalChangeSetAsNoOps() throws {
    #expect(try parseOptionalChangeSet(nil).isEmpty)
    #expect(try parseOptionalChangeSet(.null).isEmpty)
    #expect(try parseOptionalChangeSet(csParse("[]")).isEmpty)
  }

  @Test func shouldValidateANonEmptyOptionalChangeSet() throws {
    #expect(try parseOptionalChangeSet(csParse(csValidOps)).count == 4)
    let invalid = try csParse(#"[{"op": "nope"}]"#)
    #expect(throws: ChangeSetError.self) { try parseOptionalChangeSet(invalid) }
  }
}
