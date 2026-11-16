import Testing

@testable import NovelForgeCore

private func condition(_ terms: OrderedJSON...) -> OrderedJSON {
  object(("all", .array(terms)))
}

struct ValidateUnlockConditionTests {
  @Test func shouldAcceptEachKindOfTermAndNothingElse() {
    let valid = condition(object(("milestone", .string("lamp_rank_4"))), object(("volume", .string("the_tower"))), object(("chapter", .int(1))), object(("ending", .bool(true))))

    #expect(validateUnlockCondition(valid).isEmpty)
    #expect(validateUnlockCondition(condition(object(("epilogue", .bool(true))))) == ["unlock.all[0] must have exactly one of milestone, volume, chapter, ending"])
    #expect(validateUnlockCondition(condition(object(("Milestone", .string("a"))))) == ["unlock.all[0] must have exactly one of milestone, volume, chapter, ending"])
  }

  @Test func shouldRejectATermWithNoKeyOrSeveral() {
    let message = ["unlock.all[0] must have exactly one of milestone, volume, chapter, ending"]

    #expect(validateUnlockCondition(condition(object())) == message)
    #expect(validateUnlockCondition(condition(object(("milestone", .string("a")), ("volume", .string("b"))))) == message)
  }

  @Test func shouldRejectATermThatIsNotAnObject() {
    for term in [OrderedJSON.null, .array([]), .string("milestone"), .int(1), .bool(true)] {
      #expect(validateUnlockCondition(condition(term)) == ["unlock.all[0] must be an object"])
    }
  }

  @Test func shouldRejectAConditionThatIsNotAnObjectOrHasNoTerms() {
    for value in [OrderedJSON.null, .array([]), .string("all"), .int(0)] { #expect(validateUnlockCondition(value) == ["unlock must be an object"]) }
    for value in [object(), object(("all", .array([]))), object(("all", .null)), object(("all", object()))] {
      #expect(validateUnlockCondition(value) == ["unlock.all must be a non-empty array"])
    }
  }

  @Test func shouldNameEveryUnexpectedFieldBeforeLookingAtTheTerms() {
    let value = object(("all", .array([.null])), ("extra", .int(1)), ("All", .int(2)))

    #expect(validateUnlockCondition(value) == ["unlock has unexpected field 'extra'", "unlock has unexpected field 'All'"])
  }

  @Test func shouldIndexEveryBadTermByItsPosition() {
    let value = condition(object(("chapter", .int(2))), object(("chapter", .int(0))), object(("ending", .bool(false))), .null)

    #expect(validateUnlockCondition(value) == ["unlock.all[1].chapter must be an integer >= 1", "unlock.all[2].ending must be true", "unlock.all[3] must be an object"])
  }

  @Test func shouldHoldAChapterToAnIntegerAtLeastOne() {
    for bad in [OrderedJSON.int(0), .int(-4), .double(1.5), .double(0.5), .string("3"), .bool(true), .null] {
      #expect(validateUnlockCondition(condition(object(("chapter", bad)))) == ["unlock.all[0].chapter must be an integer >= 1"])
    }
    #expect(validateUnlockCondition(condition(object(("chapter", .double(100))))).isEmpty)
  }
}
