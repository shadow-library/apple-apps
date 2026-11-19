import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

@Suite("Chat session operations", TestTimeLimit.standard)
struct ChatSessionOperationTests {
  @Test func shouldCreateAnUntitledSessionInAutoModeUnlessAModeIsGiven() async throws {
    let store = try await World.store()
    let created = try await store.createChatSession(novel: World.novel)
    #expect(created.mode == .known(.auto) && created.status == .known(.active) && created.title == nil && created.autoTitle == nil && created.novel == World.novel)
    #expect(try await World.record(created.id, in: store) == created)
    let manual = try await store.createChatSession(novel: World.novel, mode: .manual)
    #expect(try await World.record(manual.id, in: store)?.mode == .known(.manual))
  }

  @Test func shouldRefuseToCreateASessionForANovelThatIsNotThere() async throws {
    let store = try await World.store()
    let missing = UUID()
    await #expect(throws: ChatSessionError.novelNotFound(missing)) { try await store.createChatSession(novel: missing) }
  }

  @Test func shouldRenameAndClearTheAuthorsTitleKeepingTheAutomaticName() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    _ = try await Projection.write(store) { transaction in try ChatAutoTitle.nameIfUntitled(session.id, novel: World.novel, title: "Volume 2 pacing", in: &transaction) }
    try await store.renameChatSession(session.id, novel: World.novel, title: "Kaela's vow")
    #expect(try await World.record(session.id, in: store)?.displayTitle == "Kaela's vow")
    try await store.renameChatSession(session.id, novel: World.novel, title: nil)
    let cleared = try await World.record(session.id, in: store)
    #expect(cleared?.title == nil && cleared?.displayTitle == "Volume 2 pacing")
  }

  @Test func shouldRefuseABlankOrTooLongTitle() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    await #expect(throws: ChatSessionError.record(.blankTitle)) { try await store.renameChatSession(session.id, novel: World.novel, title: "  ") }
    await #expect(throws: ChatSessionError.record(.titleTooLong(limit: 500))) {
      try await store.renameChatSession(session.id, novel: World.novel, title: String(repeating: "a", count: 501))
    }
    try await store.renameChatSession(session.id, novel: World.novel, title: String(repeating: "a", count: 500))
  }

  @Test func shouldSwitchModeAndArchiveAndUnarchive() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await store.setChatSessionMode(session.id, novel: World.novel, mode: .manual)
    try await store.archiveChatSession(session.id, novel: World.novel)
    var record = try await World.record(session.id, in: store)
    #expect(record?.mode == .known(.manual) && record?.status == .known(.archived))
    try await store.unarchiveChatSession(session.id, novel: World.novel)
    record = try await World.record(session.id, in: store)
    #expect(record?.status == .known(.active) && record?.mode == .known(.manual))
  }

  @Test func shouldWriteNothingWhenAnOperationLeavesItsFieldAsItIs() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await store.renameChatSession(session.id, novel: World.novel, title: "Heir")
    let before = try await World.changeCount(in: store)
    try await store.renameChatSession(session.id, novel: World.novel, title: "Heir")
    try await store.setChatSessionMode(session.id, novel: World.novel, mode: .auto)
    try await store.unarchiveChatSession(session.id, novel: World.novel)
    #expect(try await World.changeCount(in: store) == before)
  }

  @Test func shouldRefuseEveryOperationOnASessionOfAnotherNovelOrNoneAsNotFound() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.otherNovel)
    let missing = UUID()
    for id in [session.id, missing] {
      await #expect(throws: ChatSessionError.notFound(id)) { try await store.renameChatSession(id, novel: World.novel, title: "x") }
      await #expect(throws: ChatSessionError.notFound(id)) { try await store.setChatSessionMode(id, novel: World.novel, mode: .manual) }
      await #expect(throws: ChatSessionError.notFound(id)) { try await store.archiveChatSession(id, novel: World.novel) }
      await #expect(throws: ChatSessionError.notFound(id)) { try await store.deleteChatSession(id, novel: World.novel) }
    }
  }

  @Test func shouldDeleteByRemovalAndThenTreatTheSessionAsGone() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await ChatWorld.append(try ChatWorld.message(session: session.id), in: store)
    try await store.deleteChatSession(session.id, novel: World.novel)
    #expect(try await World.isRemoved(session.id, in: store))
    let state = try await ChatWorld.state(session.id, in: store)
    #expect(state?.record == .removed && state?.messages == 1)
    await #expect(throws: ChatSessionError.notFound(session.id)) { try await store.deleteChatSession(session.id, novel: World.novel) }
    await #expect(throws: ChatSessionError.notFound(session.id)) { try await store.renameChatSession(session.id, novel: World.novel, title: "x") }
  }

  @Test func shouldKeepTheUnrestrictedLockOfADeletedSession() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await World.unrestrictedReply(session: session.id, in: store)
    try await store.deleteChatSession(session.id, novel: World.novel)
    #expect(try await store.load(ChatSessions.self, World.novel).holdsUnrestrictedText == .available(true))
  }

  @Test func shouldClearThisDevicesTurnsAndExchangesOfTheDeletedSessionOnly() async throws {
    let store = try await World.store()
    let deleted = try await store.createChatSession(novel: World.novel)
    let kept = try await store.createChatSession(novel: World.novel)
    for session in [deleted.id, kept.id] { try await World.leaveLocalState(session: session, in: store) }
    try await store.deleteChatSession(deleted.id, novel: World.novel)
    for table in [LocalTurnStore.turnTable, LocalTurnStore.frameTable, ChatContextExchangeLog.table] {
      #expect(try await World.localRows(table, session: deleted.id, in: store) == 0, "\(table)")
      #expect(try await World.localRows(table, session: kept.id, in: store) == 1, "\(table)")
    }
  }

  @Test func shouldClearEveryLocalChatOfANovelLeavingOtherNovelsAlone() async throws {
    let store = try await World.store()
    let first = try await store.createChatSession(novel: World.novel)
    let removed = try await store.createChatSession(novel: World.novel)
    let other = try await store.createChatSession(novel: World.otherNovel)
    try await World.leaveLocalState(session: first.id, in: store)
    try await World.leaveLocalState(session: removed.id, in: store)
    try await World.leaveLocalState(session: other.id, novel: World.otherNovel, in: store)
    try await store.forgetLocalChats(novel: World.novel)
    for table in [LocalTurnStore.turnTable, LocalTurnStore.frameTable, ChatContextExchangeLog.table] {
      #expect(try await World.localRows(table, session: first.id, in: store) == 0, "\(table)")
      #expect(try await World.localRows(table, session: removed.id, in: store) == 0, "\(table)")
      #expect(try await World.localRows(table, session: other.id, in: store) == 1, "\(table)")
    }
  }

  @Test func shouldForgetNothingWhenNoLocalTableWasEverCreated() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await store.deleteChatSession(session.id, novel: World.novel)
    try await store.forgetLocalChats(novel: World.novel)
    #expect(try await World.isRemoved(session.id, in: store))
  }

  @Test func shouldDeleteAnUnreadableSessionOfThisNovelButRefuseToEditIt() async throws {
    let store = try await World.store()
    let id = UUID()
    let ref = ChatSessionRecord.ref(id)
    _ = try await Projection.write(store) { transaction in try transaction.set(ref, ["novel": World.novel.json, "mode": .int(4), "status": "active", "removed": false]) }
    await #expect(throws: ChatSessionError.unreadable(id)) { try await store.renameChatSession(id, novel: World.novel, title: "x") }
    await #expect(throws: ChatSessionError.notFound(id)) { try await store.deleteChatSession(id, novel: World.otherNovel) }
    try await store.deleteChatSession(id, novel: World.novel)
    #expect(try await ChatWorld.state(id, in: store)?.record == .unreadable)
    await #expect(throws: ChatSessionError.notFound(id)) { try await store.deleteChatSession(id, novel: World.novel) }
  }
}

@Suite("Leaving unrestricted", TestTimeLimit.standard)
struct ChatUnrestrictedSwitchTests {
  private func setMode(_ mode: ContentMode, in store: VaultStore) async throws {
    var changes = NovelChanges()
    changes.contentMode = .set(.known(mode))
    let edit = changes
    try await store.writeDomain { transaction throws(DomainError) in try Library.edit(novel: World.novel, edit, in: &transaction) }
  }

  private func mode(in store: VaultStore) async throws -> StoredEnum<ContentMode>? {
    try await store.read { transaction in try NovelRecord.read(id: World.novel, in: transaction).entry?.record.contentMode }
  }

  @Test func shouldLetAnUnrestrictedNovelGoBackToStandardWhileNoChatHoldsUnrestrictedText() async throws {
    let store = try await World.store(mode: .unrestricted)
    let session = try await store.createChatSession(novel: World.novel)
    try await ChatWorld.append(try ChatWorld.message(session: session.id, mode: .standard), in: store)
    try await setMode(.standard, in: store)
    #expect(try await mode(in: store) == .known(.standard))
  }

  @Test func shouldRefuseToLeaveUnrestrictedOnceAChatHoldsUnrestrictedText() async throws {
    let store = try await World.store(mode: .unrestricted)
    let session = try await store.createChatSession(novel: World.novel)
    try await World.unrestrictedReply(session: session.id, in: store)
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: store) }
    try await store.deleteChatSession(session.id, novel: World.novel)
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: store) }
    #expect(try await mode(in: store) == .known(.unrestricted))
    try await setMode(.unrestricted, in: store)
  }

  @Test func shouldTreatALockThisDeviceCannotReadAsHeld() async throws {
    let store = try await World.store(mode: .unrestricted)
    _ = try await store.createChatSession(novel: World.novel)
    try await World.fault(ChatMessageRow.databaseTableName, in: store)
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: store) }
  }

  @Test func shouldLeaveAStandardNovelFreeToBeSetStandardWhateverItsChatsHold() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await World.unrestrictedReply(session: session.id, in: store)
    try await setMode(.standard, in: store)
    try await setMode(.unrestricted, in: store)
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: store) }
  }

  @Test func shouldNotConsultTheChatsOfAnotherNovel() async throws {
    let store = try await World.store(mode: .unrestricted)
    let other = try await store.createChatSession(novel: World.otherNovel)
    try await World.unrestrictedReply(session: other.id, novel: World.otherNovel, in: store)
    try await setMode(.standard, in: store)
    #expect(try await mode(in: store) == .known(.standard))
  }

  @Test func shouldRefuseToLeaveUnrestrictedOnceADraftOrCanonHoldsUnrestrictedText() async throws {
    let isolated = DraftContent(body: "Walled.", source: .known(.generated), generator: .known(.unrestricted), isolated: true)
    let draftStore = try await World.store(mode: .unrestricted)
    _ = try await Projection.write(draftStore) { transaction in try DraftRecord(novel: World.novel, chapter: 1, content: isolated).create(in: &transaction) }
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: draftStore) }

    let canonStore = try await World.store(mode: .unrestricted)
    let canon = Canon(body: "Final.", generator: .known(.unrestricted), isolated: true)
    _ = try await Projection.write(canonStore) { transaction in try FinalChapterRecord(novel: World.novel, chapter: 1, canon: canon).finalize(in: &transaction) }
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: canonStore) }
    #expect(try await mode(in: canonStore) == .known(.unrestricted))
  }

  @Test func shouldTreatAFaultedChapterLockAsHeld() async throws {
    let store = try await World.store(mode: .unrestricted)
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    await #expect(throws: DomainError.unrestrictedLocked) { try await setMode(.standard, in: store) }
  }

  @Test func shouldForgetTheLocalStateOfChatsDeletedOnAnotherDevice() async throws {
    let store = try await World.store()
    let deletedElsewhere = try await store.createChatSession(novel: World.novel)
    let kept = try await store.createChatSession(novel: World.novel)
    let unreadable = UUID()
    let unknown = UUID()
    _ = try await Projection.write(store) { transaction in
      try transaction.set(ChatSessionRecord.ref(unreadable), ["novel": World.novel.json, "mode": .int(4), "status": "active", "removed": true])
    }
    for session in [deletedElsewhere.id, kept.id, unreadable, unknown] { try await World.leaveLocalState(session: session, in: store) }
    _ = try await Projection.write(store) { transaction in try ChatSessionRecord.remove(id: deletedElsewhere.id, in: &transaction) }
    let forgotten = try await store.forgetRemovedLocalChats()
    #expect(Set(forgotten) == [deletedElsewhere.id, unreadable])
    for table in [LocalTurnStore.turnTable, LocalTurnStore.frameTable, ChatContextExchangeLog.table] {
      for session in [deletedElsewhere.id, unreadable] { #expect(try await World.localRows(table, session: session, in: store) == 0, "\(table)") }
      for session in [kept.id, unknown] { #expect(try await World.localRows(table, session: session, in: store) == 1, "\(table)") }
    }
    #expect(try await store.forgetRemovedLocalChats().isEmpty)
  }
}
