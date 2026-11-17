import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

private let opening = "Kaela's vow contradicts chapter three — can we fix it?"

private func title(_ text: String) -> [ScriptedModelProvider.Step] {
  ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(.object(["title": .string(text)])), as: UTF8.self))
}

private func turn(_ mode: ContentMode = .standard) -> ChatAutoTitleTurn {
  ChatAutoTitleTurn(pace: .steady, contentMode: mode, consent: CompactionWorld.consent)
}

/// A session holding `messages` author messages, in order; returns their ids.
private func session(_ contents: [String] = [opening], in store: VaultStore) async throws -> (session: UUID, messages: [UUID]) {
  let session = try await store.createChatSession(novel: World.novel)
  var ids = [UUID]()
  for content in contents {
    let message = try ChatWorld.message(session: session.id, content: content)
    try await ChatWorld.append(message, in: store)
    ids.append(message.id)
  }
  return (session.id, ids)
}

private func name(
  _ session: UUID, message: UUID, turn: ChatAutoTitleTurn = turn(), store: VaultStore, provider: ScriptedModelProvider
) async throws -> ChatAutoTitleOutcome {
  let router = try await CompactionWorld.router(provider, store: store)
  return try await store.nameChatSession(session, novel: World.novel, opening: message, turn: turn, router: router)
}

@Suite("Chat auto-title", .timeLimit(.minutes(2)))
struct ChatAutoTitleTests {
  @Test func shouldNameAnUntitledSessionFromItsOpeningMessageOnce() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(in: store)
    let provider = ScriptedModelProvider(calls: [title("  Kaela's contradicted vow ")])
    guard case .named(let named, let callIDs) = try await name(id, message: messages[0], store: store, provider: provider) else {
      Issue.record("not named")
      return
    }
    #expect(named == "Kaela's contradicted vow" && callIDs.count == 1)
    let record = try await World.record(id, in: store)
    #expect(record?.autoTitle == "Kaela's contradicted vow" && record?.title == nil)
    #expect(provider.requests.first?.messages.first?.text.contains("The author's opening message:\n\(opening)") == true)
    #expect(try await name(id, message: messages[0], store: store, provider: provider) == .skipped)
    #expect(provider.requests.count == 1)
  }

  @Test func shouldNeverAskForANameWhenTheAuthorHasTitledTheSession() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(in: store)
    try await store.renameChatSession(id, novel: World.novel, title: "Mine")
    let provider = ScriptedModelProvider(calls: [title("Theirs")])
    #expect(try await name(id, message: messages[0], store: store, provider: provider) == .skipped)
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldNameOnlyFromTheOpeningAuthorMessage() async throws {
    let store = try await World.store()
    let (id, messages) = try await session([opening, "And then tighten chapter four, please."], in: store)
    let provider = ScriptedModelProvider(calls: [title("Theirs")])
    #expect(try await name(id, message: messages[1], store: store, provider: provider) == .skipped)
    let reply = try ChatWorld.message(session: id, role: .assistant, content: "A reply long enough to name the chat.")
    try await ChatWorld.append(reply, in: store)
    #expect(try await name(id, message: reply.id, store: store, provider: provider) == .skipped)
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldLeaveAShortOpeningUntitled() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(["  fix this now  "], in: store)
    let provider = ScriptedModelProvider(calls: [title("Fix")])
    #expect("fix this now".jsLength < ChatAutoTitle.minimumCharacters)
    #expect(try await name(id, message: messages[0], store: store, provider: provider) == .skipped)
    let (exact, fifteen) = try await session(["123456789012345"], in: store)
    #expect(try await name(exact, message: fifteen[0], store: store, provider: ScriptedModelProvider(calls: [title("Digits")])) != .skipped)
  }

  @Test func shouldSkipADeletedSessionOrOneOfAnotherNovel() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(in: store)
    let provider = ScriptedModelProvider(calls: [title("Theirs")])
    let router = try await CompactionWorld.router(provider, store: store)
    #expect(try await store.nameChatSession(id, novel: World.otherNovel, opening: messages[0], turn: turn(), router: router) == .skipped)
    try await store.deleteChatSession(id, novel: World.novel)
    #expect(try await name(id, message: messages[0], store: store, provider: provider) == .skipped)
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldNotCoverARenameMadeWhileTheModelRan() async throws {
    let store = try await World.store()
    let (id, _) = try await session(in: store)
    try await store.renameChatSession(id, novel: World.novel, title: "Mine")
    let written = try await Projection.write(store) { transaction in try ChatAutoTitle.nameIfUntitled(id, novel: World.novel, title: "Theirs", in: &transaction) }
    #expect(!written)
    let record = try await World.record(id, in: store)
    #expect(record?.autoTitle == nil && record?.displayTitle == "Mine")
  }

  @Test func shouldWriteNothingForABlankName() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(in: store)
    let provider = ScriptedModelProvider(calls: [title("   ")])
    guard case .kept(let callIDs) = try await name(id, message: messages[0], store: store, provider: provider) else {
      Issue.record("a blank name was written")
      return
    }
    #expect(callIDs.count == 1)
    #expect(try await World.record(id, in: store)?.autoTitle == nil)
  }

  @Test func shouldRefuseToSendAnUnrestrictedOpeningThatCrossesTheHardLine() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(["the schoolgirl looked sexy in the doorway"], in: store)
    let provider = ScriptedModelProvider(calls: [title("Theirs")])
    guard case .refused(_, let callIDs) = try await name(id, message: messages[0], turn: turn(.unrestricted), store: store, provider: provider) else {
      Issue.record("not refused")
      return
    }
    #expect(callIDs.isEmpty && provider.requests.isEmpty)
    #expect(try await World.record(id, in: store)?.autoTitle == nil)
  }

  @Test func shouldReportAFailedCallWithItsCallIDs() async throws {
    let store = try await World.store()
    let (id, messages) = try await session(in: store)
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("not json"), ScriptedModelProvider.reply("still not json")])
    await #expect {
      try await name(id, message: messages[0], store: store, provider: provider)
    } throws: { error in
      guard case .model(_, let callIDs) = error as? ChatAutoTitleError else { return false }
      return !callIDs.isEmpty
    }
    #expect(try await World.record(id, in: store)?.autoTitle == nil)
  }

  @Test func shouldNotNameASessionWhoseFirstMessageIsNotTheAuthors() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    try await ChatWorld.append(try ChatWorld.message(session: session.id, role: .assistant, content: "A card brought into this chat."), in: store)
    let message = try ChatWorld.message(session: session.id, content: opening)
    try await ChatWorld.append(message, in: store)
    let provider = ScriptedModelProvider(calls: [title("Theirs")])
    #expect(try await name(session.id, message: message.id, store: store, provider: provider) == .skipped)
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldSendTheHardLineSystemLineOnceForAnUnrestrictedName() async throws {
    let store = try await World.store(mode: .unrestricted)
    let (id, messages) = try await session(in: store)
    let provider = ScriptedModelProvider(calls: [title("Kaela's vow")])
    guard case .named = try await name(id, message: messages[0], turn: turn(.unrestricted), store: store, provider: provider) else {
      Issue.record("not named")
      return
    }
    let system = try #require(provider.requests.first).system.map(\.text)
    #expect(system.filter { $0 == hardLineSystemLine }.count == 1 && system.first == hardLineSystemLine)
  }

  @Test func shouldRefuseAnUnrestrictedNameThatCrossesTheHardLine() async throws {
    let store = try await World.store(mode: .unrestricted)
    let (id, messages) = try await session(in: store)
    let provider = ScriptedModelProvider(calls: [title("a child, orgasm")])
    guard case .refused(_, let callIDs) = try await name(id, message: messages[0], turn: turn(.unrestricted), store: store, provider: provider) else {
      Issue.record("not refused")
      return
    }
    #expect(callIDs.count == 1)
    #expect(try await World.record(id, in: store)?.autoTitle == nil)
  }
}
