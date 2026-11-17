import Testing

@testable import NovelForgeCore

private let unsafeNumbers = ["1e21", "123456789012345678901234567890", "9007199254740992", "9007199254740993", "1e300"]
private let unsafeNegativeNumbers = ["-9007199254740992", "-1e21"]
private let nonIntegers = ["1.5", "-0.5", "\"3\"", "true", "null", "[3]", "{}"]

private func integerSlots(_ number: String) -> [(label: String, json: String, nullable: Bool)] {
  let anchor = { (field: String) in
    var fields = [
      "draftId": "\"d\"", "revision": "1", "saveSeq": "1", "start": "0", "end": "5", "passageHash": "\"h\"", "paragraph": "0", "contextBefore": "\"\"", "contextAfter": "\"\"",
    ]
    fields[field] = number
    let body = fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
    return #"{"op": "draft.rewrite_passage", "chapter": 1, "passage": "a", "replacement": "b", "anchor": {\#(body)}}"#
  }
  return [
    ("brief.update chapter", #"{"op": "brief.update", "chapter": \#(number)}"#, false),
    ("brief.remove chapter", #"{"op": "brief.remove", "chapter": \#(number)}"#, false),
    ("draft.update chapter", #"{"op": "draft.update", "chapter": \#(number), "title": "t"}"#, false),
    ("draft.rewrite_passage contextIndex", #"{"op": "draft.rewrite_passage", "chapter": 1, "passage": "a", "replacement": "b", "contextIndex": \#(number)}"#, false),
    ("fact.upsert revealChapter", #"{"op": "fact.upsert", "factKey": "f", "revealChapter": \#(number)}"#, true),
    ("promise.create openedChapter", #"{"op": "promise.create", "kind": "thread", "key": "k", "label": "l", "openedChapter": \#(number)}"#, false),
    ("promise.update lastAdvancedChapter", #"{"op": "promise.update", "kind": "thread", "key": "k", "lastAdvancedChapter": \#(number)}"#, false),
    ("promise.set_payoff payoffWindow", #"{"op": "promise.set_payoff", "kind": "thread", "key": "k", "payoffWindow": \#(number)}"#, true),
    ("action.generate_chapter chapter", #"{"op": "action.generate_chapter", "chapter": \#(number)}"#, false),
    ("action.approve_draft revision", #"{"op": "action.approve_draft", "chapter": 1, "revision": \#(number)}"#, false),
    ("action.finalize upTo", #"{"op": "action.finalize", "upTo": \#(number)}"#, false),
    ("action.plan_chapter chapter", #"{"op": "action.plan_chapter", "chapter": \#(number)}"#, false),
    ("anchor start", anchor("start"), false),
    ("anchor paragraph", anchor("paragraph"), false),
    ("anchor saveSeq", anchor("saveSeq"), false),
  ]
}

private func rejected(_ json: String) throws -> Bool {
  !(try csErrors("[\(json)]", options: ChangeSetValidationOptions(entityMaterialization: false))).isEmpty
}

struct ChangeSetSafeIntegerTests {
  @Test func shouldRefuseEveryIntegerSlotThatIsNotASafeInteger() throws {
    for number in unsafeNumbers + unsafeNegativeNumbers {
      for slot in integerSlots(number) { #expect(try rejected(slot.json), "\(slot.label) accepted \(number)") }
    }
  }

  @Test func shouldRefuseEveryIntegerSlotHoldingANonInteger() throws {
    for number in nonIntegers {
      for slot in integerSlots(number) where !(number == "null" && slot.nullable) {
        #expect(try rejected(slot.json), "\(slot.label) accepted \(number)")
      }
    }
  }

  @Test func shouldAcceptTheLargestSafeIntegerAndWholeNumberSpellings() throws {
    for number in ["9007199254740991", "100", "1e2", "3.0"] {
      for slot in integerSlots(number) where slot.label != "anchor start" { #expect(try !rejected(slot.json), "\(slot.label) refused \(number)") }
    }
  }

  @Test func shouldKeepTheLargestSafeChapterExactInTheTypedOperation() throws {
    guard case .briefUpdate(let brief) = try csOp(#"{"op": "brief.update", "chapter": 9007199254740991}"#).operation else {
      Issue.record("not a brief")
      return
    }
    #expect(brief.chapter == 9_007_199_254_740_991)
  }

  @Test func shouldReadNegativeZeroAsChapterZero() throws {
    guard case .briefUpdate(let brief) = try csOp(#"{"op": "brief.update", "chapter": -0}"#).operation else {
      Issue.record("not a brief")
      return
    }
    #expect(brief.chapter == 0)
  }

  @Test func shouldNotLetTwoDifferentHugeChaptersShareOneTypedOperation() throws {
    #expect(throws: ChangeSetError.self) { try csOps(#"[{"op": "brief.update", "chapter": 1e21}]"#) }
    #expect(throws: ChangeSetError.self) { try csOps(#"[{"op": "brief.update", "chapter": 123456789012345678901234567890}]"#) }
  }

  @Test func shouldRefuseAnUnlockChapterThatIsNotASafeInteger() throws {
    for number in unsafeNumbers {
      let errors = try csErrors(#"[{"op": "fact.upsert", "factKey": "f", "unlock": {"all": [{"milestone": "m"}, {"chapter": \#(number)}]}}]"#)
      #expect(errors == ["changeSet[0]: unlock.all[1].chapter must be a safe integer"], "\(number)")
    }
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f", "unlock": {"all": [{"chapter": 9007199254740991}]}}]"#).isEmpty)
  }

  @Test func shouldRefuseASceneWordCountThatIsNotASafeInteger() throws {
    for number in unsafeNumbers {
      let errors = try csErrors(#"[{"op": "brief.update", "chapter": 1, "scenes": [{"summary": "s"}, {"summary": "t", "estimatedWords": \#(number)}]}]"#)
      #expect(errors == ["changeSet[0]: scenes[1].estimatedWords must be a safe integer"], "\(number)")
    }
    #expect(try csErrors(#"[{"op": "brief.update", "chapter": 1, "scenes": [{"summary": "s", "estimatedWords": 9007199254740991}]}]"#).isEmpty)
  }

  @Test func shouldKeepTheReferenceMessageForAnUnsafeRequiredInteger() throws {
    #expect(try csErrors(#"[{"op": "brief.update", "chapter": 1e21}]"#) == ["changeSet[0]: missing or invalid required field 'chapter' (number)"])
    #expect(try csErrors(#"[{"op": "fact.upsert", "factKey": "f", "revealChapter": 1e21}]"#) == ["changeSet[0]: invalid field 'revealChapter' (expected number|null)"])
  }
}

struct ValidatedChangeSetTests {
  @Test func shouldBuildTypedOperationsOnlyFromAValidatedSet() throws {
    let set = try ValidatedChangeSet(csParse(csValidOps))
    #expect(set.ops.count == 4)
    #expect(set.ops == (try csOps(csValidOps)))
  }

  @Test func shouldRefuseToBuildAnythingFromAnInvalidSet() throws {
    for text in ["[]", "{}", "[1]", #"[{"op": "nope"}]"#, #"[{"op": "brief.update", "chapter": 1e21}]"#, #"[{"op": "arc.upsert", "arcKey": "a1"}]"#] {
      #expect(throws: ChangeSetError.self, "\(text)") { try ValidatedChangeSet(csParse(text)) }
    }
  }

  @Test func shouldExposeValidatedRecordsOnlyWhenNothingWasRejected() throws {
    #expect(validateChangeSet(try csParse(csValidOps)).validatedRecords?.count == 4)
    #expect(validateChangeSet(try csParse(#"[{"op": "nope"}]"#)).validatedRecords == nil)
    #expect(validateChangeSet(try csParse(#"{"op": "premise.update"}"#)).validatedRecords == nil)
  }

  @Test func shouldRevalidateStoredOperationsAgainstTheScopeTheyAreReadUnder() throws {
    let stored = try csParse(#"[{"op": "brief.update", "chapter": 2}]"#)
    #expect(throws: ChangeSetError.self) { try ValidatedChangeSet(stored, allowedOps: organiseChangeOps) }
    #expect(try ValidatedChangeSet(stored).ops.count == 1)
  }
}

struct OrganiseScopeTests {
  @Test func shouldPinTheOperationsOrganisingMayWrite() {
    #expect(organiseChangeOps.map(\.rawValue) == ["bible_document.upsert", "bible_document.remove", "entity.upsert", "entity.remove", "organise.rule"])
  }

  @Test func shouldMatchTheReferenceScope() throws {
    #expect(try WireSchemaFixture.load().organise == organiseChangeOps.map(\.rawValue))
  }

  @Test func shouldRefuseEveryOperationOutsideTheOrganiseScope() throws {
    for op in OpType.allCases where !organiseChangeOps.contains(op) {
      let errors = try csErrors(#"[{"op": "\#(op.rawValue)"}]"#, allowed: organiseChangeOps)
      #expect(errors == ["changeSet[0]: op '\(op.rawValue)' is not allowed for this scope"], "\(op.rawValue)")
    }
  }

  @Test func shouldAdmitEveryOrganiseOperationPastTheScopeCheck() throws {
    for op in organiseChangeOps {
      let errors = try csErrors(#"[{"op": "\#(op.rawValue)"}]"#, allowed: organiseChangeOps)
      #expect(!errors.contains { $0.contains("is not allowed for this scope") }, "\(op.rawValue)")
    }
  }

  @Test func shouldKeepEveryOrganiseOperationOutOfTheModelHubScope() {
    #expect(OpType.content.contains(.organiseRule))
    #expect(Set(organiseChangeOps).isSubset(of: Set(OpType.content)))
  }
}
