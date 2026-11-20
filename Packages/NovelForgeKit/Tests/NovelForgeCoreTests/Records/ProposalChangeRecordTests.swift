import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias Fixture = ProposalFixture

private func set(_ ref: EntityRef, _ fields: [String: JSONValue], in store: VaultStore) async throws {
  try await SchemaFixture.set(ref, fields, in: store)
}

private func recordUndo(_ change: ProposalChangeRecord, leaving hash: String, in store: VaultStore) async throws {
  let ref = change.ref
  let undone = Fixture.states([("premise", Fixture.state(hash))])
  _ = try await store.write { transaction in try ProposalChangeRecord.recordUndo(ref, undoneState: undone, in: &transaction) }
}

private func recordRedo(_ change: ProposalChangeRecord, in store: VaultStore) async throws {
  let ref = change.ref
  _ = try await store.write { transaction in try ProposalChangeRecord.recordRedo(ref, in: &transaction) }
}

private func settle(_ change: ProposalChangeRecord, _ result: ProposalChangeResult, in store: VaultStore) async throws -> ActionSettlement {
  let ref = change.ref
  return try await store.write { transaction in try ProposalChangeRecord.settleAction(ref, result: result, in: &transaction) }
}

private func stored(_ change: ProposalChangeRecord, replacing member: String, with value: JSONValue) -> [String: JSONValue] {
  var members = change.storedMembers
  members[member] = value
  return members
}

private let malformedChanges: [(String, JSONValue)] = [
  ("undo", .array([])), ("undo", ["prior_state": [:], "post_state": [:]]), ("undo", ["inverse": "premise.update", "prior_state": [:], "post_state": [:]]),
  ("undo", ["inverse": ["op": "premise.update"], "prior_state": [], "post_state": [:]]), ("undo", ["inverse": ["op": "premise.update"], "prior_state": [:]]),
  ("result", "failed"), ("result", ["error": 4]), ("undone_state", ["premise", "gone"]), ("status", 1),
]

@Suite("Proposal change records", TestTimeLimit.standard)
struct ProposalChangeRecordTests {
  @Test func shouldCreateAChangeWithItsKeyStatusAndUndoAndNoFirstWriterValueAsNull() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let change = try Fixture.change(of: proposal, 2, undo: try Fixture.undo("p1"))
    _ = try await Harness.create(change, in: store)
    #expect(change.ref == change.key.ref)
    #expect(change.ref == (try ProposalChangeRecord.ref(novel: Fixture.novel, proposal: proposal.id, index: 2)))
    #expect(change.key.components == .proposalChange(proposal: proposal.id, index: 2))
    let record = try await SchemaFixture.record(change.ref, in: store)
    #expect(Set(record.fields.keys.map(\.value)) == ["natural_key", "status", "undo"])
    #expect(record[field: "status"]?.value == "applied")
    #expect(try await Fixture.readChange(change, in: store) == .readable(RecordEntry(record: change, isRemoved: false)))
  }

  @Test func shouldCreateAPendingActionWithoutUndoAndAFailedOneWithItsResult() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let pending = try Fixture.change(of: proposal, 3, status: .pending)
    let failed = try Fixture.change(of: proposal, 1, status: .failed, result: ProposalChangeResult(error: "skipped — a previous action failed"))
    _ = try await Harness.create(pending, in: store)
    _ = try await Harness.create(failed, in: store)
    #expect(Set(try await SchemaFixture.record(pending.ref, in: store).fields.keys.map(\.value)) == ["natural_key", "status"])
    #expect(Set(try await SchemaFixture.record(failed.ref, in: store).fields.keys.map(\.value)) == ["natural_key", "status", "result"])
    #expect(try await Fixture.readChange(pending, in: store).entry?.record == pending)
    #expect(try await Fixture.readChange(failed, in: store).entry?.record == failed)
    #expect(pending.actionOutcome == .known(.pending) && failed.actionOutcome == .known(.failed))
  }

  @Test func shouldRefuseANegativeIndex() throws {
    let proposal = try Fixture.proposal()
    #expect(throws: NovelForgeKeyError.opIndexOutOfRange(-1)) { try Fixture.change(of: proposal, -1) }
  }

  @Test func shouldRefuseAnInverseTheVaultCannotStoreOrThatIsNoOperation() throws {
    for text in [#"{"op": "bible_document.upsert", "frontmatter": {"w": 0.5}}"#, #"{"premise": "p"}"#, #"{"op": 3}"#] {
      let inverse = try #require(try csParse(text).objectValue)
      #expect(throws: ProposalRecordError.unstorableInverse, "\(text)") {
        try ProposalChangeUndo(inverse: inverse, priorState: ArtifactStates(), postState: ArtifactStates())
      }
    }
  }

  @Test func shouldKeepAnInverseThatOperationSpecsWouldRefuse() async throws {
    let store = try SchemaFixture.store()
    let inverse = try #require(try csParse(#"{"op": "premise.update", "premise": null, "themes": null}"#).objectValue)
    let undo = try ProposalChangeUndo(inverse: inverse, priorState: Fixture.states([("premise", .missing)]), postState: Fixture.states([("premise", Fixture.state("p1"))]))
    let change = try Fixture.change(of: try Fixture.proposal(), 0, undo: undo)
    _ = try await Harness.create(change, in: store)
    let read = try #require(try await Fixture.readChange(change, in: store).entry?.record)
    #expect(read.undo?.inverse == ["op": "premise.update", "premise": .null, "themes": .null])
    #expect(read.undo?.priorState["premise"] == .missing)
    #expect(read.undo?.postState["premise"].map { $0.matches(Fixture.state("p1")) } == true)
  }

  @Test func shouldReadAChangeWhoseKeyHasNotArrivedAsNotYetPresent() async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0)
    try await set(change.ref, ["status": "reverted", "undone_state": [:]], in: store)
    #expect(try await Fixture.readChange(change, in: store) == .absent)
  }

  @Test(arguments: malformedChanges)
  func shouldReadAMalformedChangeAsUnreadable(_ field: String, _ value: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0, undo: try Fixture.undo("p1"))
    try await set(change.ref, stored(change, replacing: field, with: value), in: store)
    #expect(try await Fixture.readChange(change, in: store) == .unreadable(.invalid(field: field)))
  }

  @Test func shouldFailClosedOnAStateEntryThatDoesNotDecode() async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0)
    let undo: JSONValue = ["inverse": ["op": "premise.update"], "prior_state": ["premise": ["exists": "yes"]], "post_state": ["premise": 3]]
    try await set(change.ref, stored(change, replacing: "undo", with: undo), in: store)
    let read = try #require(try await Fixture.readChange(change, in: store).entry?.record.undo)
    #expect(read.priorState["premise"]?.isUnreadable == true)
    #expect(read.postState["premise"]?.isUnreadable == true)
    #expect(read.postState["premise"].map { $0.matches(.unreadable) } == false)
  }

  @Test func shouldKeepNewerMembersAndStatusesOfAChange() async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0)
    var undo = try #require(try Fixture.undo("p1").json.objectValue)
    undo["notebook_entry"] = "n-1"
    var result = try #require(ProposalChangeResult(note: "kept", result: ["chapter": 2]).json.objectValue)
    result["duration"] = 12
    try await set(change.ref, ["natural_key": change.key.stored, "status": "parked", "undo": .object(undo), "result": .object(result)], in: store)
    let read = try #require(try await Fixture.readChange(change, in: store).entry?.record)
    #expect(read.status == .unknown("parked"))
    #expect(read.undo?.unrecognised == ["notebook_entry": "n-1"])
    #expect(read.result?.unrecognised == ["duration": 12])
    #expect(read.result?.result == ["chapter": 2])
    #expect(read.actionOutcome == .known(.applied))
    #expect(read.fields.members == ["status": "parked", "undo": .object(undo), "result": .object(result)])
  }

  @Test func shouldUndoAndRedoThroughTheStatusRegisterAndKeepTheUndoneState() async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0, undo: try Fixture.undo("p1"))
    _ = try await Harness.create(change, in: store)
    try await recordUndo(change, leaving: "p0", in: store)
    let undone = try #require(try await Fixture.readChange(change, in: store).entry?.record)
    #expect(undone.status == .known(.reverted))
    #expect(undone.undoneState == Fixture.states([("premise", Fixture.state("p0"))]))
    #expect(undone.undo == change.undo)
    try await recordRedo(change, in: store)
    let redone = try #require(try await Fixture.readChange(change, in: store).entry?.record)
    #expect(redone.status == .known(.applied))
    #expect(redone.undoneState == undone.undoneState)
  }

  @Test func shouldRefuseToUndoRedoOrSettleAChangeThatIsNotReadable() async throws {
    let store = try SchemaFixture.store()
    let missing = try Fixture.change(of: try Fixture.proposal(), 0)
    await #expect(throws: StoreError.self) { try await recordUndo(missing, leaving: "p0", in: store) }
    await #expect(throws: StoreError.self) { try await recordRedo(missing, in: store) }
    await #expect(throws: StoreError.self) { _ = try await settle(missing, ProposalChangeResult(), in: store) }
    try await set(missing.ref, stored(missing, replacing: "undo", with: "broken"), in: store)
    await #expect(throws: StoreError.self) { try await recordRedo(missing, in: store) }
    #expect(try await SchemaFixture.record(missing.ref, in: store)[field: "status"]?.value == "applied")
  }

  @Test func shouldRefuseToUndoOrRedoAChangeThatRecordsNoUndo() async throws {
    let store = try SchemaFixture.store()
    let action = try Fixture.change(of: try Fixture.proposal(), 3, status: .pending)
    _ = try await Harness.create(action, in: store)
    let before = try await store.pendingChanges(limit: Int.max).count
    await #expect(throws: StoreError.self) { try await recordUndo(action, leaving: "p0", in: store) }
    await #expect(throws: StoreError.self) { try await recordRedo(action, in: store) }
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
  }

  @Test func shouldRefuseTheGenericEdit() async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0)
    _ = try await Harness.create(change, in: store)
    var status = RecordFields<ProposalChangeField>()
    status.put(.status, "reverted")
    let fields = status
    let ref = change.ref
    await #expect(throws: StoreError.self) { _ = try await store.write { transaction in try ProposalChangeRecord.edit(ref, fields, in: &transaction) } }
  }

  @Test(arguments: [(ProposalChangeResult(result: ["approval": "a-1"]), ProposalChangeStatus.applied), (ProposalChangeResult(error: "no draft"), .failed)])
  func shouldSettleAPendingActionOnceByItsResult(_ result: ProposalChangeResult, _ outcome: ProposalChangeStatus) async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 3, status: .pending)
    _ = try await Harness.create(change, in: store)
    guard case .settled = try await settle(change, result, in: store) else {
      Issue.record("a pending action settles")
      return
    }
    let before = try await store.pendingChanges(limit: Int.max).count
    #expect(try await settle(change, ProposalChangeResult(error: "late"), in: store) == .alreadySettled(.known(outcome)))
    #expect(try await settle(change, ProposalChangeResult(), in: store) == .alreadySettled(.known(outcome)))
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
    let read = try #require(try await Fixture.readChange(change, in: store).entry?.record)
    #expect(read.status == .known(outcome) && read.actionOutcome == .known(outcome))
    #expect(read.result == result)
  }

  @Test func shouldNeverSettleAChangeThatIsNoPendingAction() async throws {
    let store = try SchemaFixture.store()
    let change = try Fixture.change(of: try Fixture.proposal(), 0, undo: try Fixture.undo("p1"))
    _ = try await Harness.create(change, in: store)
    #expect(try await settle(change, ProposalChangeResult(error: "x"), in: store) == .alreadySettled(.known(.applied)))
    #expect(try await Fixture.readChange(change, in: store).entry?.record.result == nil)
  }

  @Test func shouldKeepASettledActionSettledWhenALaterApplierWritesItPending() async throws {
    let devices = try Devices()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: devices.first)
    try await devices.exchange()
    let action = try Fixture.change(of: proposal, 3, status: .pending)
    _ = try await Fixture.apply(proposal, selected: [3], undo: "a", in: devices.first)
    devices.clock.advance()
    _ = try await settle(action, ProposalChangeResult(result: ["approval": "a-1"]), in: devices.first)
    devices.clock.advance()
    _ = try await Fixture.apply(proposal, selected: [3], undo: "b", in: devices.second)
    try await devices.exchange()
    for store in devices.both {
      let read = try #require(try await Fixture.readChange(action, in: store).entry?.record)
      #expect(read.status == .known(.pending))
      #expect(read.actionOutcome == .known(.applied))
      #expect(try await settle(action, ProposalChangeResult(error: "again"), in: store) == .alreadySettled(.known(.applied)))
    }
  }

  @Test func shouldListEachIndexAsRecordedDeclinedOrNotApplied() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    #expect(try await Fixture.changes(of: proposal, in: store) == [.notApplied, .notApplied, .notApplied, .notApplied])
    _ = try await Fixture.apply(proposal, selected: [0, 3], undo: "a", in: store)
    let broken = try Fixture.change(of: proposal, 1)
    try await set(broken.ref, stored(broken, replacing: "result", with: "oops"), in: store)
    let expected: [ProposalChangeEntry] = try [Fixture.applied(proposal, 0, undo: "a"), .unreadable(.invalid(field: "result")), .declined, Fixture.applied(proposal, 3, undo: "a")]
    #expect(try await Fixture.changes(of: proposal, in: store) == expected)
  }

  @Test func shouldNeverListAChangeOfAnIndexTheCardDoesNotHave() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    _ = try await Fixture.apply(proposal, selected: [0], undo: "a", in: store)
    _ = try await Harness.create(try Fixture.change(of: proposal, 9), in: store)
    #expect(try await Fixture.changes(of: proposal, in: store).count == 4)
  }

  @Test func shouldRecordTheUnionOfTwoDevicesApplyingDifferentSelections() async throws {
    let devices = try Devices()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: devices.first)
    try await devices.exchange()
    _ = try await Fixture.apply(proposal, selected: [0, 1], automatic: true, undo: "a", in: devices.first)
    devices.clock.advance()
    _ = try await Fixture.apply(proposal, selected: [1, 2], "p2", undo: "b", in: devices.second)
    try await devices.exchange()
    let expected: [ProposalChangeEntry] = try [
      Fixture.applied(proposal, 0, undo: "a"), Fixture.applied(proposal, 1, undo: "a"), Fixture.applied(proposal, 2, undo: "b"), .declined,
    ]
    for store in devices.both {
      #expect(try await Fixture.read(proposal, in: store).entry?.record.application == Fixture.application(selected: [0, 1], "p1", automatic: true))
      #expect(try await Fixture.changes(of: proposal, in: store) == expected)
    }
  }

  @Test(arguments: [true, false])
  func shouldLetTheLaterOfAConcurrentUndoAndRedoStand(_ redoLater: Bool) async throws {
    let devices = try Devices()
    let change = try Fixture.change(of: try Fixture.proposal(), 0, undo: try Fixture.undo("p1"))
    _ = try await Harness.create(change, in: devices.first)
    try await recordUndo(change, leaving: "p0", in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    if redoLater {
      try await recordUndo(change, leaving: "p9", in: devices.first)
      devices.clock.advance()
      try await recordRedo(change, in: devices.second)
    } else {
      try await recordRedo(change, in: devices.second)
      devices.clock.advance()
      try await recordUndo(change, leaving: "p9", in: devices.first)
    }
    try await devices.exchange()
    for store in devices.both {
      let read = try #require(try await Fixture.readChange(change, in: store).entry?.record)
      #expect(read.status == .known(redoLater ? .applied : .reverted))
      #expect(read.undoneState == Fixture.states([("premise", Fixture.state("p9"))]))
      #expect(read.undo == change.undo)
    }
  }
}
