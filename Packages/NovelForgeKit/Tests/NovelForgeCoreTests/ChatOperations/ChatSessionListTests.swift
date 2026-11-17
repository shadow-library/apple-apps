import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

private func list(_ filter: ChatSessionFilter, startedOnly: Bool = false, in store: VaultStore) async throws -> [UUID]? {
  try await store.load(ChatSessionList.self, ChatSessionListQuery(novel: World.novel, filter: filter, startedOnly: startedOnly)).sessions.value?.map(\.state.session)
}

@Suite("Chat session list", .timeLimit(.minutes(2)))
struct ChatSessionListTests {
  @Test func shouldListActiveAndArchivedChatsApartMostRecentlyUpdatedFirstAndNeverADeletedOne() async throws {
    let store = try await World.store()
    let first = try await store.createChatSession(novel: World.novel)
    let archived = try await store.createChatSession(novel: World.novel)
    let deleted = try await store.createChatSession(novel: World.novel)
    let latest = try await store.createChatSession(novel: World.novel)
    _ = try await store.createChatSession(novel: World.otherNovel)
    try await store.archiveChatSession(archived.id, novel: World.novel)
    try await store.deleteChatSession(deleted.id, novel: World.novel)
    try await store.renameChatSession(latest.id, novel: World.novel, title: "Latest")
    #expect(try await list(.active, in: store) == [latest.id, first.id])
    #expect(try await list(.archived, in: store) == [archived.id])
    #expect(try await list(.all, in: store) == [latest.id, archived.id, first.id])
  }

  @Test func shouldListOnlyChatsTheAuthorPostedInWhenAsked() async throws {
    let store = try await World.store()
    let posted = try await store.createChatSession(novel: World.novel)
    let replied = try await store.createChatSession(novel: World.novel)
    _ = try await store.createChatSession(novel: World.novel)
    try await ChatWorld.append(try ChatWorld.message(session: posted.id), in: store)
    try await ChatWorld.append(try ChatWorld.message(session: replied.id, role: .assistant, content: "A card brought in."), in: store)
    #expect(try await list(.all, startedOnly: true, in: store) == [posted.id])
  }

  @Test func shouldListAChatWhoseRecordCannotBeReadAmongTheActiveOnes() async throws {
    let store = try await World.store()
    let id = UUID()
    _ = try await Projection.write(store) { transaction in try transaction.set(ChatSessionRecord.ref(id), ["novel": World.novel.json, "mode": .int(4), "status": "archived"]) }
    #expect(try await list(.active, in: store) == [id])
    #expect(try await list(.archived, in: store) == [])
  }
}
