import Testing

@testable import NovelForgeCore

private func options(_ form: Int) -> OpVocabularyOptions {
  OpVocabularyOptions(quotes: form == 3)
}

struct ChangeSetVocabularyParityTests {
  @Test func shouldRenderTheOperationVocabularyExactlyAsTheReferenceDoes() throws {
    let fixture = try ChangeSetVocabularyFixture.load()
    #expect(fixture.ops.count >= 200)
    var mismatches: [Int] = []
    for (index, item) in fixture.ops.enumerated() {
      let ops = item.ops.compactMap { OpType(exactly: $0) }
      if renderOpVocabulary(ops, options(item.option)) != fixture.text(item.lines) { mismatches.append(index) }
    }
    #expect(mismatches.isEmpty, "cases \(mismatches.prefix(5)) of \(mismatches.count) differ")
  }

  @Test func shouldRenderTheActionVocabularyExactlyAsTheReferenceDoes() throws {
    let fixture = try ChangeSetVocabularyFixture.load()
    var mismatches: [Int] = []
    for (index, item) in fixture.actions.enumerated() {
      let actions = item.actions.compactMap { OpType(exactly: $0) }
      if renderActionVocabulary(actions) != fixture.text(item.lines) { mismatches.append(index) }
    }
    #expect(mismatches.isEmpty, "cases \(mismatches.prefix(5)) of \(mismatches.count) differ")
  }

  @Test func shouldMirrorTheReferenceOperationSpecifications() throws {
    let spec = try ChangeSetSpecFixture.load()
    #expect(OpType.allCases.map(\.rawValue) == spec.ops)
    #expect(OpType.actions.map(\.rawValue) == spec.actions)
    #expect(OpType.content.map(\.rawValue) == spec.content)
    #expect(pluginAllowedOps.map(\.rawValue) == spec.pluginAllowed)
    for entry in spec.perOp {
      guard let op = OpType(exactly: entry.op) else {
        Issue.record("missing \(entry.op)")
        continue
      }
      let declared = op.declaredSpec
      #expect(declared.required.map(\.name) == entry.required.map(\.name), "\(entry.op) required")
      #expect(declared.required.map(\.kind.rawValue) == entry.required.map(\.kind), "\(entry.op) required kinds")
      let optional = op.spec.optional
      #expect(optional.map(\.name) == entry.optional.map(\.name), "\(entry.op) optional")
      #expect(optional.map(\.kind.rawValue) == entry.optional.map(\.kind), "\(entry.op) optional kinds")
      #expect(op.spec.description == entry.description, "\(entry.op) description")
      #expect(declaredOpFields(op) == entry.declared, "\(entry.op) declared fields")
      #expect(isActionOp(op) == entry.isAction)
      for form in 0..<4 { #expect(modelHiddenFields(op, options(form)) == entry.hidden[form], "\(entry.op) hidden fields form \(form)") }
    }
  }

  @Test func shouldMirrorTheReferenceVocabulariesOfEveryEnumeration() throws {
    let lists = try ChangeSetSpecFixture.load().lists
    #expect(BiblePageSection.allCases.map(\.rawValue) == lists.sections)
    #expect(EntityType.allCases.map(\.rawValue) == lists.entityTypes)
    #expect(BriefWriteMode.allCases.map(\.rawValue) == lists.writeModes)
    #expect(ContentMode.allCases.map(\.rawValue) == lists.contentModes)
    #expect(MilestoneKind.allCases.map(\.rawValue) == lists.milestoneKinds)
    #expect(PromiseKind.allCases.map(\.rawValue) == lists.promiseKinds)
    #expect(PromiseOpStatus.allCases.map(\.rawValue) == lists.promiseStatuses)
    #expect(ValidationScope.allCases.map(\.rawValue) == lists.scopes)
  }
}

struct ChangeSetRefsParityTests {
  private static func cases() throws -> [ChangeSetRefsCase] {
    try ReferenceFixture.decode(ChangeSetRefsFixture.self, from: "change-set/refs.json").cases
  }

  private static func ops(_ item: ChangeSetRefsCase) throws -> [ChangeOp] {
    try parseChangeSet(csParse(item.text), options: ChangeSetValidationOptions(entityMaterialization: false))
  }

  @Test func shouldDeriveTheReferenceRefsFromSeededSetsOfValidOperations() throws {
    let cases = try Self.cases()
    #expect(cases.count >= 100)
    var mismatches: [String] = []
    for item in cases where !csSameStrings(changeSetRefs(try Self.ops(item)), item.refs) { mismatches.append(item.text) }
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(2))")
  }

  @Test func shouldDeriveTheReferenceDecisionKeysFromSeededSetsOfValidOperations() throws {
    var mismatches: [String] = []
    for item in try Self.cases() where !csSameStrings(actionDecisionKeys(try Self.ops(item)), item.keys) { mismatches.append(item.text) }
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(2))")
  }
}
