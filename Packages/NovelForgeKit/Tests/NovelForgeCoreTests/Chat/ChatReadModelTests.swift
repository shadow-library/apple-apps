import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatWorld

private func session(with count: Int, in store: VaultStore) async throws -> [ChatMessageRecord] {
  try await World.createSession(in: store)
  var messages = [ChatMessageRecord]()
  for index in 0..<count {
    let message = try World.message(role: index.isMultiple(of: 2) ? .user : .assistant, content: "Turn \(index)", mode: .standard)
    try await World.append(message, in: store)
    messages.append(message)
  }
  return messages
}

private func fault(_ table: String, _ key: String, in store: VaultStore) async throws {
  _ = try await store.write { transaction in
    try transaction.database.execute(sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES (?, ?, 1, 'broken')", arguments: [table, key])
  }
}

@Suite("Chat read models", .timeLimit(.minutes(2)))
struct ChatReadModelTests {
  @Test func shouldPageTheTranscriptNewestFirstAndReturnEachPageOldestFirst() async throws {
    let (_, store) = try World.store()
    let messages = try await session(with: 7, in: store)
    let latest = try #require(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.session, limit: 3)).page.value)
    #expect(latest.messages.map(\.position) == [5, 6, 7] && latest.total == 7 && latest.hasEarlier)
    #expect(latest.messages.compactMap(\.record) == Array(messages.suffix(3)))
    let earlier = try #require(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.session, before: 5, limit: 10)).page.value)
    #expect(earlier.messages.map(\.position) == [1, 2, 3, 4] && !earlier.hasEarlier)
    #expect(earlier.messages.map(\.row.id) == messages.prefix(4).map(\.id))
    let all = try #require(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.session)).page.value)
    #expect(all.messages.count == 7)
    #expect(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.session)).state.value??.messages == 7)
  }

  @Test func shouldShowAnUnreadableMessageInItsPlaceWithNoRecord() async throws {
    let (_, store) = try World.store()
    _ = try await session(with: 1, in: store)
    let ref = NovelForgeKey.chatMessage(UUID())
    try await World.appendRaw(ref, World.item(["role": "assistant"]), in: store)
    let page = try #require(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.session)).page.value)
    #expect(page.messages.map { $0.record == nil } == [false, true])
    #expect(page.messages.last?.row.ref == ref && page.messages.last?.row.isReadable == false)
  }

  @Test func shouldReadTheWindowAsTheStandingSummaryAndEveryMessageItLeavesOut() async throws {
    let (_, store) = try World.store()
    let messages = try await session(with: 5, in: store)
    #expect(try await store.load(ChatWindow.self, World.session).window.value??.messages.count == 5)
    let summary = try World.summary(covering: [messages[0].id, messages[1].id, messages[3].id], mode: .unrestricted)
    try await World.append(summary, in: store)
    let window = try #require(try await store.load(ChatWindow.self, World.session).window.value ?? nil)
    #expect(window.summary?.record == summary)
    #expect(window.messages.compactMap(\.record) == [messages[2], messages[4]])
    #expect(try await store.load(ChatWindow.self, World.session).lock.value??.item == summary.ref)
    #expect(try await store.load(ChatWindow.self, SchemaFixture.proposal).window == .available(nil))
    #expect(try await store.load(ChatWindow.self, SchemaFixture.proposal).lock == .available(nil))
  }

  @Test func shouldListSessionsMostRecentlyUpdatedFirstAndSayWhetherAnyHoldsUnrestrictedText() async throws {
    let (_, store) = try World.store()
    for id in World.sessions { try await World.createSession(id, in: store) }
    try await World.createSession(SchemaFixture.proposal, novel: World.otherNovel, in: store)
    try await World.append(try World.message(session: World.sessions[0]), in: store)
    let sessions = try await store.load(ChatSessions.self, World.novel)
    #expect(sessions.sessions.value?.map(\.state.session) == [World.sessions[0], World.sessions[2], World.sessions[1]])
    #expect(sessions.sessions.value?.allSatisfy { $0.record?.novel == World.novel } == true)
    #expect(sessions.holdsUnrestrictedText == .available(false))

    try await World.append(try World.message(session: World.sessions[1], mode: .unrestricted), in: store)
    _ = try await Projection.write(store) { transaction in try ChatSessionRecord.remove(id: World.sessions[1], in: &transaction) }
    let after = try await store.load(ChatSessions.self, World.novel)
    #expect(after.sessions.value?.first?.state.record == .removed)
    #expect(after.holdsUnrestrictedText == .available(true))
    #expect(try await store.load(ChatSessions.self, World.otherNovel).holdsUnrestrictedText == .available(false))
  }

  @Test func shouldBlockAReadOfASessionWhoseRowsAreFaultedAndReportOthersAsEntries() async throws {
    let (_, store) = try World.store()
    _ = try await session(with: 2, in: store)
    try await fault(ChatTranscriptRow.databaseTableName, ProjectionFaults.key(NovelForgeKey.chatSession(World.session)), in: store)
    #expect(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.session)).page.isUnavailable)
    #expect(try await store.load(ChatWindow.self, World.session).window.isUnavailable)
    let other = try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.sessions[1]))
    #expect(other.page.value?.messages.isEmpty == true && other.faults.map(\.scope) == [.entry])
    #expect(try await store.load(ChatSessions.self, World.novel).faults.map(\.scope) == [])

    #expect(try await store.load(ChatSessions.self, World.novel).holdsUnrestrictedText == .available(false))
    #expect(try await store.load(ChatWindow.self, World.sessions[1]).lock == .available(nil))

    try await fault(ChatSessionState.databaseTableName, ProjectionFaults.wholeDerivation, in: store)
    #expect(try await store.load(ChatSessions.self, World.novel).sessions.isUnavailable)
    #expect(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: World.sessions[1])).page.isUnavailable)
  }

  @Test func shouldNotSayWhetherTextIsUnrestrictedWhileAnyChatRowIsFaulted() async throws {
    for table in [ChatMessageRow.databaseTableName, ChatSummaryRow.databaseTableName, ChatSessionState.databaseTableName] {
      let (_, store) = try World.store()
      let messages = try await session(with: 1, in: store)
      try await fault(table, ProjectionFaults.key(NovelForgeKey.chatMessage(UUID())), in: store)
      let sessions = try await store.load(ChatSessions.self, World.novel)
      #expect(sessions.sessions.value?.map(\.state.session) == [World.session], "\(table)")
      #expect(sessions.holdsUnrestrictedText.isUnavailable, "\(table)")
      let window = try await store.load(ChatWindow.self, World.session)
      #expect(window.window.value??.messages.compactMap(\.record) == messages, "\(table)")
      #expect(window.lock.isUnavailable, "\(table)")
    }
  }
}
