import ShadowCore
import Testing

@testable import NovelForgeCore

private func values<Value: RawRepresentable & CaseIterable>(_ type: Value.Type) -> [String] where Value.RawValue == String {
  type.allCases.map(\.rawValue)
}

struct VocabularyTests {
  private func expected(_ key: String) throws -> [String] {
    try RuleFixture.load("vocab")[key].orThrow(key).list().strings()
  }

  @Test func shouldMatchTheReferenceHookTypes() throws {
    #expect(values(HookType.self) == (try expected("hookTypes")))
  }

  @Test func shouldMatchTheReferenceChangeSetVocabulary() throws {
    #expect(values(BriefWriteMode.self) == (try expected("briefWriteModes")))
    #expect(values(ContentMode.self) == (try expected("contentModes")))
    #expect(values(BiblePageSection.self) == (try expected("bibleSections")))
    #expect(values(EntityType.self) == (try expected("entityTypes")))
    #expect(values(MilestoneKind.self) == (try expected("milestoneKinds")))
    #expect(values(PromiseKind.self) == (try expected("promiseKinds")))
    #expect(values(PromiseOpStatus.self) == (try expected("promiseStatuses")))
    #expect(values(ValidationScope.self) == (try expected("validationScopes")))
  }

  @Test func shouldMatchTheReferenceDatabaseEnums() throws {
    #expect(values(VolumeState.self) == (try expected("volumeStates")))
    #expect(values(ThreadStatus.self) == (try expected("threadStatuses")))
    #expect(values(MysteryStatus.self) == (try expected("mysteryStatuses")))
    #expect([MilestoneState.open, .planned, .reached].map(\.rawValue) == (try expected("milestoneStates")))
    #expect(values(LedgerEntryKind.self) == (try expected("ledgerKinds")))
    #expect(values(LedgerDecidedBy.self) == (try expected("ledgerDecidedBy")))
    #expect(values(LedgerRejectionScope.self) == (try expected("ledgerRejectionScopes")))
  }

  @Test func shouldAgreeWithTheDatabaseDeclarationsOfTheChangeSetLists() throws {
    #expect(try expected("bibleSections") == expected("dbBibleSections"))
    #expect(try expected("entityTypes") == expected("dbEntityTypes"))
    #expect(try expected("milestoneKinds") == expected("dbMilestoneKinds"))
    #expect(try expected("briefWriteModes") == expected("dbBriefWriteModes"))
  }

  @Test func shouldMatchTheReferenceAuthorSupersedeKindsAndPromiseStatuses() throws {
    #expect(values(AuthorSupersedeKind.self) == (try expected("authorSupersedeKinds")))
    #expect(Set(values(PromiseStatus.self)) == Set(try expected("promiseStatusUnion")))
  }

  @Test func shouldRefuseAValueOutsideAClosedVocabulary() {
    #expect(HookType(rawValue: "cliff_hanger") == nil)
    #expect(VolumeState(rawValue: "Active") == nil)
  }

  @Test func shouldKeepPromiseStatusesAlignedWithTheThreadAndMysteryStatuses() {
    #expect(ThreadStatus.allCases.map(\.promiseStatus.rawValue) == values(ThreadStatus.self))
    #expect(MysteryStatus.allCases.map(\.promiseStatus.rawValue) == values(MysteryStatus.self))
  }
}
