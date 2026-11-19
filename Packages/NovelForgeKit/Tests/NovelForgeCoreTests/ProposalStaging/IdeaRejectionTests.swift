import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias World = StagingWorld

// apps/novel-forge-server/tests/refinement/idea-rejection.service.spec.ts:11-13
private let kael = #"{"op":"entity.upsert","entityKey":"kael","type":"character","name":"Kael","motivation":"He wants the lamp."}"#
private let secret = #"{"op":"fact.upsert","factKey":"kael_betrayal","body":"Kael sold the keeper out."}"#
private let rule = #"{"op":"organise.rule","rule":"No magic at sea.","optionId":"r1"}"#

private func card(_ book: ChapterBook) async throws -> ProposalRecord {
  try await book.stage(kael, #"{"op":"action.audit_bible"}"#, rule, secret, session: nil, kind: .chat).proposal
}

private func kaelIdea() throws -> String {
  try #require(IdeaIdentity.shared).ideaId(of: try #require(try World.changeSet(kael).ops.first))
}

extension ChapterBook {
  @discardableResult
  fileprivate func reject(_ proposal: UUID, _ index: Int, _ scope: LedgerRejectionScope, why: String? = nil) async throws -> NotebookEntryRecord {
    try await store.rejectIdea(proposal: proposal, opIndex: index, scope: scope, why: why, novel: novel)
  }

  fileprivate func ledger() async throws -> NotebookLedger {
    let novel = novel
    return try await store.read { try NotebookLedger.load(novel: novel, in: $0) }
  }

  fileprivate func active(_ ideaId: String) async throws -> [NotebookEntry] {
    try await ledger().active(matching: NotebookFilter(topics: [NotebookTopics.idea(ideaId)]))
  }

  /// The Notebook entries the chat context shows (ChatContextLedger, F19b), lapsed rejections dropped.
  fileprivate func chatNotebook() async throws -> [ChatPackLedgerEntry] {
    let novel = novel
    return try await store.read { transaction in
      let volumes = try StoryStructure.load(novel, in: transaction).volumes.value?.items
      return try ChatContextLedger.notebook(novel: novel, volumes: volumes, in: transaction).entries
    }
  }

  fileprivate func volumes(_ keys: String...) async throws {
    let novel = novel
    try await run { transaction in
      for key in keys { try Volumes.create(novel: novel, volume: key, title: key, in: &transaction) }
    }
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-rejection.service.ts:36-82
@Suite("Idea rejections", TestTimeLimit.standard)
struct IdeaRejectionTests {
  // idea-rejection.service.spec.ts:45
  @Test func shouldRecordNeverWithNoAnchorUnderTheIdeaTopicAndALabelThatNamesTheRecord() async throws {
    let book = try await World.book()
    let proposal = try await card(book)
    let entry = try await book.reject(proposal.id, 0, .never, why: "The keeper has no rival.")
    let ideaId = try kaelIdea()
    #expect(entry.topic == "idea.\(ideaId)")
    #expect(entry.statement == "Kael (character): He wants the lamp.")
    #expect(entry.why == "The keeper has no rival.")
    #expect(entry.entryKind == .known(.rejected) && entry.decidedBy == .known(.author))
    #expect(entry.idea == ideaId && entry.rejectionScope == .known(.never) && entry.rejectionAnchor == nil)
    #expect(try await book.active(ideaId).map(\.id) == [entry.id])
  }

  // idea-rejection.service.spec.ts:63
  @Test func shouldAnchorNotNowToTheActiveVolumeAndNotThisVersionToTheRecordAsItStands() async throws {
    let book = try await World.book()
    let novel = book.novel
    let proposal = try await card(book)
    #expect(try await book.reject(proposal.id, 0, .notNow).rejectionAnchor == ["volumeKey": .null])
    try await book.volumes("volume_1", "volume_2")
    _ = try await book.run { try Volumes.markGoalMet(novel: novel, volume: "volume_1", in: &$0) }
    #expect(try await book.reject(proposal.id, 0, .notNow).rejectionAnchor == ["volumeKey": "volume_2"])
    try await book.run { try ChapterWrites.entity(novel: novel, "kael", in: &$0) }
    let state = try #require(try await book.states(["entity:kael"])[JSString("entity:kael")])
    let anchored = try await book.reject(proposal.id, 0, .notThisVersion).rejectionAnchor
    let expected: JSONValue = ["states": ["entity:kael": ["exists": true, "revision": .null, "contentHash": .string(try #require(state.contentHash))]]]
    #expect(anchored == expected)
    let missing = try await book.stage(#"{"op":"entity.upsert","entityKey":"ivo","type":"character","name":"Ivo"}"#, session: nil).proposal
    let absent: JSONValue = ["states": ["entity:ivo": ["exists": false, "revision": .null, "contentHash": .null]]]
    #expect(try await book.reject(missing.id, 0, .notThisVersion).rejectionAnchor == absent)
  }

  // A version rejection binds the version the author sees: this device's working copy of a draft it names is committed first, as an approval's is
  @Test func shouldCommitTheWorkingCopyOfADraftAVersionRejectionAnchorsTo() async throws {
    let book = try await World.workspace()
    let proposal = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, session: nil).proposal
    let edited = "Dawn.\n\n\(StagingText.body)"
    try await book.save(3, edited, summary: "It turns.", base: try await book.head(3))
    let revisions = try await book.revisionCount(3)
    let anchored = try await book.reject(proposal.id, 0, .notThisVersion).rejectionAnchor
    #expect(try await book.revisionCount(3) == revisions + 1)
    #expect(try await book.workingCopy(3) == nil)
    #expect(try await book.draftContent(3)?.body == edited)
    let state = try #require(try await book.states(["draft:3"])[JSString("draft:3")])
    let expected: JSONValue = ["states": ["draft:3": ["exists": true, "revision": .null, "contentHash": .string(try #require(state.contentHash))]]]
    #expect(anchored == expected)
  }

  // idea-rejections.ts:27 as ChatContextLedger judges it against committed states: a rejection over an unsaved copy stays in scope
  @Test func shouldKeepAVersionRejectionTakenOverAnUnsavedCopyInScope() async throws {
    let book = try await World.workspace()
    let proposal = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, session: nil).proposal
    try await book.save(3, "Dawn.\n\n\(StagingText.body)", summary: "It turns.", base: try await book.head(3))
    let entry = try await book.reject(proposal.id, 0, .notThisVersion)
    #expect(try await book.chatNotebook().map(\.ideaId) == [entry.idea])
  }

  // idea-rejection.service.spec.ts:82
  @Test func shouldReplaceAnEarlierScopeForTheSameIdeaRatherThanStackASecondEntry() async throws {
    let book = try await World.book()
    let proposal = try await card(book)
    let first = try await book.reject(proposal.id, 0, .never)
    let second = try await book.reject(proposal.id, 0, .notNow)
    #expect(second.supersedes == first.id)
    let active = try await book.active(try kaelIdea())
    #expect(active.map(\.id) == [second.id])
    #expect(active.first?.record.rejectionScope == .known(.notNow))
    #expect(try await book.ledger().entry(first.id)?.status == .superseded)
  }

  // idea-rejection.service.spec.ts:91
  @Test func shouldKeepASecretOutOfTheLabel() async throws {
    let book = try await World.book()
    #expect(try await book.reject(try await card(book).id, 3, .never).statement == "Secret kael_betrayal")
  }

  // idea-rejection.service.spec.ts:99
  @Test func shouldRefuseAMissingOpAnActionAndAVersionScopeForAChangeThatTouchesNoRecord() async throws {
    let book = try await World.book()
    let proposal = try await card(book)
    await #expect(throws: IdeaRejectionError.noChange(opIndex: 9)) { try await book.reject(proposal.id, 9, .never) }
    await #expect(throws: IdeaRejectionError.noChange(opIndex: -1)) { try await book.reject(proposal.id, -1, .never) }
    await #expect(throws: IdeaRejectionError.notAnIdea) { try await book.reject(proposal.id, 1, .never) }
    await #expect(throws: IdeaRejectionError.touchesNoRecord) { try await book.reject(proposal.id, 2, .notThisVersion) }
    let missing = UUID()
    await #expect(throws: IdeaRejectionError.proposalNotFound(missing)) { try await book.reject(missing, 0, .never) }
    await #expect(throws: IdeaRejectionError.notebook(.tooLong(field: "why", limit: 4000))) {
      try await book.reject(proposal.id, 0, .never, why: String(repeating: "x", count: 4001))
    }
    #expect(try await book.ledger().entries.isEmpty)
  }

  // A version anchor on a record this device cannot read would lapse as soon as it can be read; the rejection is refused instead
  @Test func shouldRefuseAVersionScopeOnARecordThisDeviceCannotRead() async throws {
    let book = try await World.book()
    let novel = book.novel
    let proposal = try await card(book)
    let entity = NovelForgeKey.entityKey(novel: novel, entity: "kael")
    try await book.run { transaction in _ = try transaction.set(entity.ref, ["natural_key": entity.stored, "removed": .bool(false)]) }
    await #expect(throws: IdeaRejectionError.recordUnreadable("entity:kael")) { try await book.reject(proposal.id, 0, .notThisVersion) }
    let volume = NovelForgeKey.volumeKey(novel: novel, volume: "broken")
    try await book.run { transaction in _ = try transaction.set(volume.ref, ["natural_key": volume.stored, "removed": .bool(false)]) }
    await #expect(throws: IdeaRejectionError.volumesUnreadable) { try await book.reject(proposal.id, 0, .notNow) }
  }

  // idea-rejection.service.ts:68
  @Test func shouldWithdrawTheRejectionOfAnIdeaTheAuthorAdopted() async throws {
    let book = try await World.book()
    let novel = book.novel
    let proposal = try await card(book)
    let entry = try await book.reject(proposal.id, 0, .never)
    let op = try #require(try World.changeSet(kael).ops.first)
    let withdrawn = try await book.run { try NotebookIdeaRejections.withdrawRejection(of: op, reason: "Brought back.", novel: novel, in: &$0) }
    #expect(withdrawn.map(\.entry) == [entry.id])
    #expect(try await book.active(try kaelIdea()).isEmpty)
    #expect(try await book.run { try NotebookIdeaRejections.withdrawRejection(of: op, reason: "Again.", novel: novel, in: &$0) }.isEmpty)
  }

  // idea-rejections.ts:76 as the chat context reads the Notebook (F19b): a rejection steers the model until its scope lapses
  @Test func shouldLandInTheNotebookAndLapseAsWithoutLapsedRejectionsJudgesIt() async throws {
    let book = try await World.book()
    let novel = book.novel
    try await book.volumes("volume_1", "volume_2")
    try await book.run { try ChapterWrites.entity(novel: novel, "kael", in: &$0) }
    let proposal = try await card(book)
    let now = try await book.reject(proposal.id, 0, .notNow)
    let ideaIds = { () async throws -> [String?] in try await book.chatNotebook().map(\.ideaId) }
    #expect(try await ideaIds() == [now.idea])
    _ = try await book.run { try Volumes.markGoalMet(novel: novel, volume: "volume_1", in: &$0) }
    #expect(try await ideaIds().isEmpty)

    let version = try await book.reject(proposal.id, 0, .notThisVersion)
    #expect(try await book.chatNotebook().map(\.rejectionScope) == [.notThisVersion])
    try await book.run { try Entities.edit(novel: novel, entity: "kael", EntityDetails(notes: "Limps."), in: &$0) }
    #expect(try await ideaIds().isEmpty)

    let never = try await book.reject(proposal.id, 3, .never)
    #expect(try await ideaIds() == [never.idea])
    #expect(version.idea != never.idea)
  }
}
