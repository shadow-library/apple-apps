import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("ChatNovelModel", TestTimeLimit.standard)
struct ChatNovelModelTests {
  @Test("should start a chat from its first message and open it")
  func shouldStartAChatFromItsFirstMessage() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Hello.")])
    let model = ChatNovelModel(context: world.context, engine: world.engine)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the chats load") { model.state.value != nil }
    #expect(model.current == nil)
    #expect(model.novelTitle == "Ashfall")

    model.draft = "Who is Mara?"
    await model.startDraft()

    let session = try #require(model.current)
    #expect(model.draft.isEmpty)
    let opened = model.session(session)
    #expect(opened === model.session(session))
    let reading = Task { await opened.observe() }
    defer { reading.cancel() }
    try await ChatWait.until("the reply lands") { opened.lastReply?.content == "Hello." }
    try await ChatWait.until("History lists the chat") { model.state.value?.active.sessions.value?.map(\.state.session) == [session] }
  }

  @Test("should rename, archive, unarchive and delete a chat")
  func shouldRenameArchiveUnarchiveAndDeleteAChat() async throws {
    let world = try await ChatWorld.make()
    let model = ChatNovelModel(context: world.context, engine: world.engine)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    let older = try await world.session()
    let session = try await world.session()
    try await ChatWait.until("the chats load") { model.overviews.count == 2 }
    model.open(session)
    #expect(model.current == session)

    model.beginRename(session)
    model.renameText = "  Harbour plot  "
    await model.commitRename()
    try await ChatWait.until("the title changes") { model.title(of: session) == "Harbour plot" }

    model.beginRename(session)
    #expect(model.renameText == "Harbour plot")
    model.renameText = "   "
    await model.commitRename()
    try await ChatWait.until("the title clears") { model.title(of: session) == String(localized: "New chat", table: "Chat") }

    await model.setArchived(session, true)
    try await ChatWait.until("the chat is archived") { model.isArchived(session) }
    #expect(model.current == session)
    await model.setArchived(session, false)
    try await ChatWait.until("the chat is active again") { !model.isArchived(session) }
    #expect(model.current == session)

    model.deleting = session
    await model.confirmDelete()
    try await ChatWait.until("the chat is gone") { model.overview(of: session) == nil }
    #expect(model.current == older)
    #expect(model.failure == nil)
  }

  @Test("should open the opening composer for a new chat and fall back to the newest active chat")
  func shouldOpenTheOpeningComposerForANewChat() async throws {
    let world = try await ChatWorld.make()
    let model = ChatNovelModel(context: world.context, engine: world.engine)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    let session = try await world.session()
    try await ChatWait.until("the chats load") { model.current == session }

    model.newChat()
    #expect(model.current == nil)
    model.open(UUID())
    #expect(model.current == session)
  }

  @Test("should report a session operation on a deleted chat")
  func shouldReportAnOperationOnADeletedChat() async throws {
    let world = try await ChatWorld.make()
    let model = ChatNovelModel(context: world.context, engine: world.engine)
    let session = try await world.session()
    try await world.store.deleteChatSession(session, novel: world.novel)

    await model.setArchived(session, true)

    #expect(model.failure?.error.detail == "CHT_001")
  }
}
