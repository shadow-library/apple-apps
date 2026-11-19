import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias Fixture = ProposalFixture

private func set(_ ref: EntityRef, _ fields: [String: JSONValue], in store: VaultStore) async throws {
  try await SchemaFixture.set(ref, fields, in: store)
}

private func storedCard(_ proposal: ProposalRecord, replacing member: String, with value: JSONValue?) -> JSONValue {
  var members = proposal.card.json.objectValue ?? [:]
  members[member] = value
  return .object(members)
}

private func dismiss(_ ref: EntityRef, as dismissal: ProposalDismissal, in store: VaultStore) async throws -> DecisionOutcome {
  try await store.write { transaction in try ProposalRecord.dismiss(ref, as: dismissal, in: &transaction) }
}

private let malformedCards: [(String, JSONValue?)] = [
  ("card", .array([])), ("novel", .none), ("novel", "6F0C4D1E-0000-4000-8000-000000000001"), ("kind", 7), ("change_set", ["op": "premise.update"]),
  ("change_set", .none), ("baseline", ["premise"]), ("baseline", .none), ("warnings", [1]), ("diagnostics", [["kind": "other"]]), ("supersedes", ["not-a-uuid"]),
  ("session", 3),
]

@Suite("Proposal records", TestTimeLimit.standard)
struct ProposalRecordTests {
  @Test func shouldCreateTheCardWithAPendingDecisionAndNoAppliedObject() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    #expect(proposal.ref == NovelForgeKey.proposal(proposal.id))
    #expect(proposal.ref == ProposalRecord.ref(id: proposal.id))
    let stored = try await SchemaFixture.record(proposal.ref, in: store)
    #expect(Set(stored.fields.keys.map(\.value)) == ["card", "decision"])
    #expect(stored[field: "decision"]?.value == "pending")
    #expect(stored[field: "card"]?.value == proposal.card.json)
    #expect(try await Fixture.read(proposal, in: store) == .readable(RecordEntry(record: proposal, isRemoved: false)))
    #expect(try await store.read { transaction in try ProposalRecord.read(id: proposal.id, in: transaction) }.entry?.record == proposal)
  }

  @Test func shouldStoreEveryCardMemberAndReadTheChangeSetBackAsTheSameOperations() async throws {
    let store = try SchemaFixture.store()
    let original = try csOps(Fixture.changeSet)
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    let card = try #require(try await Fixture.read(proposal, in: store).entry?.record.card)
    #expect(card.ops == original.map(Optional.some))
    #expect(card.problems.isEmpty)
    #expect(card.novel == Fixture.novel && card.session == Fixture.session && card.message == Fixture.message)
    #expect(card.kind == .known(.chat) && card.summary == "Sharpen the premise" && card.run == "run-1")
    #expect(card.baseline == Fixture.baseline)
    #expect(card.baseline["premise"].map { $0.matches(Fixture.state("p0")) } == true)
    #expect(card.warnings == ["“no heir” reads as a removal"])
    #expect(card.diagnostics == [ProposalDiagnostic(kind: .known(.other), message: "“no heir” reads as a removal")])
    #expect(Set(try #require(card.json.objectValue).keys) == Set(ProposalCardMember.allCases.map(\.rawValue)))
  }

  @Test func shouldWriteAbsentOptionalCardMembersAsNullInsideTheCard() async throws {
    let card = try ProposalCard(novel: Fixture.novel, kind: .known(.organise), changeSet: try csOps(#"[{"op": "premise.update", "premise": "p"}]"#), baseline: ArtifactStates())
    let members = try #require(card.json.objectValue)
    #expect(members["session"] == .null && members["message"] == .null && members["summary"] == .null && members["run"] == .null)
    #expect(members["warnings"] == [] && members["diagnostics"] == [] && members["supersedes"] == [] && members["baseline"] == [:])
    #expect(ProposalCard(json: card.json) == card)
  }

  @Test func shouldKeepAWholeNumberSpelledAsAFractionAsTheIntegerTheVaultStores() async throws {
    let store = try SchemaFixture.store()
    let text = #"[{"op": "bible_document.upsert", "section": "world", "slug": "harbour", "frontmatter": {"weight": 3.0, "tags": ["salt"]}}]"#
    let proposal = try Fixture.proposal(card: try Fixture.card(text))
    _ = try await Harness.create(proposal, in: store)
    let read = try #require(try await Fixture.read(proposal, in: store).entry?.record)
    #expect(read == proposal)
    #expect(read.card.changeSet[0].stored["frontmatter"]?["weight"] == 3)
  }

  @Test(arguments: [
    #"[{"op": "bible_document.upsert", "section": "world", "slug": "harbour", "frontmatter": {"weight": 1.5}}]"#,
    #"[{"op": "premise.update", "premise": "p"}, {"op": "bible_document.upsert", "section": "world", "slug": "harbour", "frontmatter": {"n": 1e300}}]"#,
    "[{\"op\": \"bible_document.upsert\", \"section\": \"world\", \"slug\": \"harbour\", \"frontmatter\": {\"caf\\u00e9\": 1, \"cafe\\u0301\": 2}}]",
  ])
  func shouldRefuseACardWhoseOperationTheVaultCannotStoreExactly(_ text: String) throws {
    let ops = try csOps(text, options: ChangeSetValidationOptions(entityMaterialization: false))
    #expect(throws: ProposalRecordError.unstorableOperation(index: ops.count - 1)) {
      try ProposalCard(novel: Fixture.novel, kind: .known(.chat), changeSet: ops, baseline: ArtifactStates())
    }
  }

  @Test func shouldReportAStoredOperationThatNoLongerValidatesAndKeepItsIndexAndForm() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let unknown: JSONValue = ["op": "arc.upsert", "arcKey": "a1"]
    let broken: JSONValue = ["op": "brief.update", "chapter": "three"]
    var stored = try #require(proposal.card.json.objectValue)
    stored["change_set"] = .array([try #require(proposal.card.changeSet.first?.stored), unknown, broken, "not an op"])
    try await set(proposal.ref, ["card": .object(stored), "decision": "pending"], in: store)
    let card = try #require(try await Fixture.read(proposal, in: store).entry?.record.card)
    #expect(card.changeSet.count == 4)
    #expect(card.ops.map { $0 != nil } == [true, false, false, false])
    #expect(card.changeSet[1].problems == ["changeSet[1]: unknown op 'arc.upsert'"])
    #expect(card.changeSet[2].problems.allSatisfy { $0.hasPrefix("changeSet[2]: ") } && !card.changeSet[2].problems.isEmpty)
    #expect(card.changeSet[3].problems == ["changeSet[3]: must be an object"])
    #expect(card.json == .object(stored))
  }

  @Test func shouldReadAProposalWhoseCardHasNotArrivedAsNotYetPresent() async throws {
    let store = try SchemaFixture.store()
    let ref = NovelForgeKey.proposal(UUID())
    try await set(ref, ["decision": "discarded"], in: store)
    #expect(try await Harness.read(ref, as: ProposalRecord.self, in: store) == .absent)
    #expect(try await store.read { transaction in try ProposalRecord.listing(in: transaction) } == RecordListing(entries: [], unreadable: 0))
  }

  @Test(arguments: malformedCards)
  func shouldReadAMalformedCardAsUnreadable(_ member: String, _ value: JSONValue?) async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let card = member == "card" ? value ?? .null : storedCard(proposal, replacing: member, with: value)
    try await set(proposal.ref, ["card": card, "decision": "pending"], in: store)
    #expect(try await Fixture.read(proposal, in: store) == .unreadable(.invalid(field: "card")))
  }

  @Test func shouldReadAMissingDecisionOrAMalformedAppliedObjectAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    try await set(proposal.ref, ["card": proposal.card.json], in: store)
    #expect(try await Fixture.read(proposal, in: store) == .unreadable(.missing(field: "decision")))
    try await set(proposal.ref, ["decision": "applied", "applied": ["automatic": true]], in: store)
    #expect(try await Fixture.read(proposal, in: store) == .unreadable(.invalid(field: "applied")))
    var negative = try #require(Fixture.application(selected: [0], "p1").json.objectValue)
    negative["selected"] = [-1]
    let other = try Fixture.proposal()
    try await set(other.ref, ["card": other.card.json, "decision": "applied", "applied": .object(negative)], in: store)
    #expect(try await Fixture.read(other, in: store) == .unreadable(.invalid(field: "applied")))
  }

  @Test func shouldKeyStatesByTheNFCFormOfTheRefAndFailClosedOnRivalSpellings() async throws {
    let composed = "entity:caf\u{E9}"
    let decomposed = "entity:cafe\u{301}"
    let agreeing = Fixture.states([(composed, Fixture.state("e0")), (decomposed, Fixture.state("e0"))])
    #expect(agreeing.refs == [composed] && agreeing[decomposed] == Fixture.state("e0"))
    let rival = Fixture.states([(composed, Fixture.state("e0")), (decomposed, Fixture.state("e1"))])
    #expect(rival[composed]?.isUnreadable == true)
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let baseline: JSONValue = [decomposed: ["exists": true, "revision": .null, "contentHash": "e0"]]
    try await set(proposal.ref, ["card": storedCard(proposal, replacing: "baseline", with: baseline), "decision": "pending"], in: store)
    let card = try #require(try await Fixture.read(proposal, in: store).entry?.record.card)
    #expect(card.baseline[composed] == Fixture.state("e0") && card.baseline[decomposed] == Fixture.state("e0"))
    #expect(ArtifactStates(json: agreeing.json) == agreeing)
  }

  @Test func shouldFailClosedOnABaselineEntryThatDoesNotDecode() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let baseline: JSONValue = ["premise": "gone", "fact:heir": ["exists": true, "revision": .null, "contentHash": "f0"]]
    try await set(proposal.ref, ["card": storedCard(proposal, replacing: "baseline", with: baseline), "decision": "pending"], in: store)
    let card = try #require(try await Fixture.read(proposal, in: store).entry?.record.card)
    let premise = try #require(card.baseline["premise"])
    #expect(premise.isUnreadable)
    #expect(!premise.matches(premise))
    #expect(card.baseline["fact:heir"].map { $0.matches(Fixture.state("f0")) } == true)
    #expect(card.baseline["volume:vol_1"] == nil)
  }

  @Test func shouldKeepNewerMembersOfTheCardAppliedObjectAndDiagnostics() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    var card = try #require(proposal.card.json.objectValue)
    card["added_later"] = ["tone": "wry"]
    card["diagnostics"] = [["kind": "storyboard", "message": "m", "data": ["scene": 2], "severity": "low"]]
    var applied = try #require(Fixture.application(selected: [0], "p1").json.objectValue)
    applied["undo_window"] = 30
    try await set(proposal.ref, ["card": .object(card), "decision": "applied", "applied": .object(applied)], in: store)
    let read = try #require(try await Fixture.read(proposal, in: store).entry?.record)
    #expect(read.card.unrecognised == ["added_later": ["tone": "wry"]])
    #expect(read.card.diagnostics.first?.kind == .unknown("storyboard"))
    #expect(read.card.diagnostics.first?.unrecognised == ["severity": "low"])
    #expect(read.card.json == .object(card))
    #expect(read.application?.json == .object(applied))
    #expect(read.fields.members == ["card": .object(card), "decision": "applied", "applied": .object(applied)])
  }

  @Test func shouldReadAProposalWrittenByANewerVersion() async throws {
    let store = try Harness.newerVersionStore()
    let proposal = try Fixture.proposal(card: try Fixture.card(kind: .hub))
    _ = try await Harness.create(proposal, in: store)
    try await set(proposal.ref, [Harness.newerMember: "x"], in: store)
    var stored = try #require(proposal.card.json.objectValue)
    stored["kind"] = "storyboard"
    let other = NovelForgeKey.proposal(UUID())
    try await set(other, ["card": .object(stored), "decision": "pending"], in: store)
    #expect(try await Fixture.read(proposal, in: store).entry?.record == proposal)
    #expect(try await Harness.read(other, as: ProposalRecord.self, in: store).entry?.record.card.kind == .unknown("storyboard"))
  }

  @Test func shouldAttributeAnUnreadableCardToItsNovelWhenItNamesOne() async throws {
    let store = try SchemaFixture.store()
    let readable = try Fixture.proposal()
    let broken = try Fixture.proposal()
    let anonymous = try Fixture.proposal()
    _ = try await Harness.create(readable, in: store)
    try await set(broken.ref, ["card": storedCard(broken, replacing: "change_set", with: nil), "decision": "pending"], in: store)
    try await set(anonymous.ref, ["card": storedCard(anonymous, replacing: "novel", with: nil), "decision": "pending"], in: store)
    let listing = try await store.read { transaction in try ProposalRecord.listing(in: transaction) }
    #expect(listing == RecordListing(entries: [RecordEntry(record: readable, isRemoved: false)], unreadable: 1, unattributed: 1))
  }

  @Test func shouldRefuseTheGenericEdit() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    var decision = RecordFields<ProposalField>()
    decision.put(.decision, "applied")
    let fields = decision
    let ref = proposal.ref
    await #expect(throws: StoreError.self) { _ = try await store.write { transaction in try ProposalRecord.edit(ref, fields, in: &transaction) } }
  }

  @Test func shouldOnlyRaiseTheDecisionWhenDismissing() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    guard case .raised = try await dismiss(proposal.ref, as: .discarded, in: store) else {
      Issue.record("discarding a pending proposal writes the decision")
      return
    }
    let before = try await store.pendingChanges(limit: Int.max).count
    #expect(try await dismiss(proposal.ref, as: .superseded, in: store) == .unchanged(.known(.discarded)))
    #expect(try await dismiss(proposal.ref, as: .discarded, in: store) == .unchanged(.known(.discarded)))
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
    #expect(try await Fixture.read(proposal, in: store).entry?.record.decision == .known(.discarded))
  }

  @Test func shouldDismissACardThisDeviceCannotReadButNeverOneThatIsAbsent() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    try await set(proposal.ref, ["card": storedCard(proposal, replacing: "change_set", with: nil), "decision": "pending"], in: store)
    guard case .raised = try await dismiss(proposal.ref, as: .discarded, in: store) else {
      Issue.record("an unreadable card can be set aside")
      return
    }
    #expect(try await SchemaFixture.record(proposal.ref, in: store)[field: "decision"]?.value == "discarded")
    let before = try await store.pendingChanges(limit: Int.max).count
    #expect(try await dismiss(proposal.ref, as: .superseded, in: store) == .unchanged(.known(.discarded)))
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
    await #expect(throws: StoreError.self) { _ = try await dismiss(NovelForgeKey.proposal(UUID()), as: .discarded, in: store) }
  }

  @Test func shouldWriteTheChangesThenTheDecisionAndAppliedObjectInOneApply() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    let before = try await store.pendingChanges(limit: Int.max).count
    guard case .recorded = try await Fixture.apply(proposal, selected: [2, 0], automatic: true, undo: "a", in: store) else {
      Issue.record("a pending proposal is applied")
      return
    }
    let written = try await store.pendingChanges(limit: Int.max).dropFirst(before).map { try JSONDecoder().decode(JSONValue.self, from: $0.line) }
    #expect(written.map { $0["entity"]?.stringValue } == ["nf_proposal_change", "nf_proposal_change", "nf_proposal"])
    let read = try #require(try await Fixture.read(proposal, in: store).entry?.record)
    #expect(read.decision == .known(.applied))
    #expect(read.application == Fixture.application(selected: [0, 2], "p1", automatic: true))
    let expected: [ProposalChangeEntry] = try [Fixture.applied(proposal, 0, undo: "a"), .declined, Fixture.applied(proposal, 2, undo: "a"), .declined]
    #expect(try await Fixture.changes(of: proposal, in: store) == expected)
  }

  @Test func shouldRefuseASecondApply() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    _ = try await Fixture.apply(proposal, selected: [0], undo: "a", in: store)
    let before = try await store.pendingChanges(limit: Int.max).count
    #expect(try await Fixture.apply(proposal, selected: [1], "p2", undo: "b", in: store) == .notPending(.known(.applied)))
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
    #expect(try await Fixture.read(proposal, in: store).entry?.record.application == Fixture.application(selected: [0], "p1"))
  }

  @Test(arguments: [ProposalDismissal.discarded, .superseded])
  func shouldRefuseToApplyADismissedProposal(_ dismissal: ProposalDismissal) async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    _ = try await dismiss(proposal.ref, as: dismissal, in: store)
    let before = try await store.pendingChanges(limit: Int.max).count
    #expect(try await Fixture.apply(proposal, selected: [0], undo: "a", in: store) == .notPending(.known(dismissal.decision)))
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
    #expect(try await Fixture.changes(of: proposal, in: store) == [.notApplied, .notApplied, .notApplied, .notApplied])
  }

  @Test func shouldRefuseAnApplyWhoseChangesDoNotMatchTheCard() async throws {
    let store = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    let other = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: store)
    let ref = proposal.ref
    let refused: [([ProposalChangeRecord], [StoredEnum<OpSource>]?)] = [
      ([], nil), ([try Fixture.change(of: proposal, 4)], nil), ([try Fixture.change(of: proposal, 1), try Fixture.change(of: proposal, 1)], nil),
      ([try Fixture.change(of: other, 1)], nil), ([try Fixture.change(of: proposal, 1)], [.known(.quoted)]),
    ]
    for (changes, sources) in refused {
      await #expect(throws: StoreError.self) {
        _ = try await store.write { transaction in
          try ProposalRecord.recordApply(ref, changes: changes, postState: ArtifactStates(), sources: sources, automatic: false, in: &transaction)
        }
      }
    }
    await #expect(throws: StoreError.self) { _ = try await Fixture.apply(try Fixture.proposal(), selected: [0], undo: "a", in: store) }
    #expect(try await Fixture.read(proposal, in: store).entry?.record.decision == .known(.pending))
  }

  @Test func shouldNeverShowASelectedChangeThatHasNotArrivedAsDeclined() async throws {
    let applier = try SchemaFixture.store()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: applier)
    _ = try await Fixture.apply(proposal, selected: [0, 2], undo: "a", in: applier)
    let lines = try await applier.pendingChanges(limit: Int.max).map(\.line)
    let full: [ProposalChangeEntry] = try [Fixture.applied(proposal, 0, undo: "a"), .declined, Fixture.applied(proposal, 2, undo: "a"), .declined]
    let reader = try SchemaFixture.store()
    for line in lines {
      _ = try await reader.applyRemote([line])
      let decision = try await Fixture.read(proposal, in: reader).entry?.record.decision
      let entries = try await Fixture.changes(of: proposal, in: reader)
      if decision == .known(.applied) {
        #expect(entries == full)
      } else {
        #expect(!entries.contains(.declined) && !entries.contains(.awaiting))
      }
    }
    let skipped = try SchemaFixture.store()
    _ = try await skipped.applyRemote([try #require(lines.first), try #require(lines.last)])
    #expect(try await Fixture.changes(of: proposal, in: skipped) == [.awaiting, .declined, .awaiting, .declined])
  }

  @Test(arguments: [(ProposalDismissal.discarded, true), (.discarded, false), (.superseded, true), (.superseded, false)])
  func shouldLetAnApplyOnAnotherDeviceBeatADismissal(_ dismissal: ProposalDismissal, _ applyLater: Bool) async throws {
    let devices = try Devices()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: devices.first)
    try await devices.exchange()
    if !applyLater { _ = try await Fixture.apply(proposal, selected: [0, 2], undo: "a", in: devices.second) }
    devices.clock.advance()
    _ = try await dismiss(proposal.ref, as: dismissal, in: devices.first)
    devices.clock.advance()
    if applyLater { _ = try await Fixture.apply(proposal, selected: [0, 2], undo: "a", in: devices.second) }
    try await devices.exchange()
    for store in devices.both {
      let read = try #require(try await Fixture.read(proposal, in: store).entry?.record)
      #expect(read.decision == .known(.applied))
      #expect(read.application == Fixture.application(selected: [0, 2], "p1"))
    }
  }

  @Test func shouldSettleTwoDismissalsOnTheHigherOne() async throws {
    let devices = try Devices()
    let proposal = try Fixture.proposal()
    _ = try await Harness.create(proposal, in: devices.first)
    try await devices.exchange()
    _ = try await dismiss(proposal.ref, as: .discarded, in: devices.first)
    devices.clock.advance()
    _ = try await dismiss(proposal.ref, as: .superseded, in: devices.second)
    try await devices.exchange()
    for store in devices.both { #expect(try await Fixture.read(proposal, in: store).entry?.record.decision == .known(.discarded)) }
  }
}
