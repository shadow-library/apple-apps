import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("ChatComposer", TestTimeLimit.standard)
struct ChatComposerTests {
  private static let prose = "😀 Mara keeps the harbour keys.\n\nShe never sleeps."

  private func drafted(_ world: ChatWorld, prose: String = prose) async throws -> ChatPassageSource {
    let reader = ReaderModel(context: world.context)
    #expect(await reader.startNext() == 1)
    _ = try await reader.service.importDraft(chapter: 1, prose: prose, base: nil)
    return try #require(try await source(world))
  }

  private func source(_ world: ChatWorld) async throws -> ChatPassageSource? {
    let novel = world.novel
    return try await world.store.read { transaction in try ChatPassageSource.load(novel: novel, chapter: 1, in: transaction) }
  }

  private func chip(_ source: ChatPassageSource, quote: String, comment: String = "") throws -> ChatPassageChip {
    let selection = try source.select((source.body as NSString).range(of: quote)).get()
    return ChatPassageChip(source, selection, comment: comment)
  }

  private func saved(after gate: AsyncStream<Void>) -> (ChatSessionMode) async -> Bool {
    { _ in
      for await _ in gate {}
      return true
    }
  }

  private func userMessage(_ model: ChatSessionModel) throws -> ChatMessageRecord {
    try #require(model.messages.first { $0.record?.role == .known(.user) }?.record)
  }

  @Test("should send the mode, Think deeper and Edit prose with the message and reset only the reply options")
  func shouldSendTheComposerChoicesWithTheMessage() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Noted.")])
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    model.replyOffer = ChatReplyOffer(thinkDeeper: true, unrestricted: false)
    model.composer.justDiscussing = true
    model.composer.proseEdits = true
    model.composer.replyOptions.thinkDeeper = true
    model.draft = "Who is Mara?"

    await model.sendDraft()

    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Noted." }
    let sent = try userMessage(model)
    #expect(sent.deeper == true)
    #expect(sent.justDiscussing == true)
    #expect(sent.proseEdits == true)
    #expect(sent.pace == .known(.balanced))
    #expect(sent.contentMode == .known(.standard))
    #expect(model.composer.replyOptions == ChatReplyOptions())
    #expect(model.composer.justDiscussing && model.composer.proseEdits)
  }

  @Test("should send an option only while the novel still offers it")
  func shouldSendAnOptionOnlyWhileOffered() {
    let composer = ChatComposerState()
    composer.replyOptions = ChatReplyOptions(thinkDeeper: true, unrestricted: true)

    #expect(composer.choices(offer: .none) == ChatTurnChoices())
    #expect(composer.choices(offer: ChatReplyOffer(thinkDeeper: true, unrestricted: true)) == ChatTurnChoices(thinksDeeper: true, contentMode: .unrestricted))
  }

  @Test("should hide Unrestricted while unrestricted writing is unavailable, and Think deeper on a performant novel")
  func shouldHideUnrestrictedWhileUnavailable() throws {
    let standard = NovelRecord(id: UUID(), name: "Ashfall")
    let performant = NovelRecord(id: UUID(), name: "Ashfall", costTier: .known(.performant))
    let unrestricted = NovelRecord(id: UUID(), name: "Ashfall", contentMode: .known(.unrestricted))

    #expect(!UnrestrictedWriting.isAvailable)
    #expect(ChatReplyOffer(novel: standard) == ChatReplyOffer(thinkDeeper: true, unrestricted: false))
    #expect(ChatReplyOffer(novel: standard, unrestrictedAvailable: true) == ChatReplyOffer(thinkDeeper: true, unrestricted: true))
    #expect(ChatReplyOffer(novel: unrestricted, unrestrictedAvailable: true) == ChatReplyOffer(thinkDeeper: true, unrestricted: false))
    #expect(ChatReplyOffer(novel: performant, unrestrictedAvailable: true) == ChatReplyOffer(thinkDeeper: false, unrestricted: true))
    #expect(ChatReplyOffer(novel: nil, unrestrictedAvailable: true).isEmpty)
  }

  @Test("should keep the message and comments and turn Unrestricted off when the engine refuses it")
  func shouldKeepTheMessageWhenUnrestrictedIsRefused() async throws {
    let world = try await ChatWorld.make()
    let source = try await drafted(world)
    let model = world.model(of: try await world.session())
    model.replyOffer = ChatReplyOffer(thinkDeeper: true, unrestricted: true)
    model.composer.replyOptions.unrestricted = true
    #expect(model.composer.add(try chip(source, quote: "harbour keys")) == .added)
    model.draft = "Darker?"

    await model.sendDraft()

    #expect(model.notice?.error.detail == ChatTurnError.unrestrictedUnavailable.code)
    #expect(model.draft == "Darker?")
    #expect(model.composer.chips.map(\.passage.quote) == ["harbour keys"])
    #expect(!model.composer.replyOptions.unrestricted)
  }

  @Test("should keep the mode menu shut while a message is being sent, a turn runs, the chat is locked or a mode saves")
  func shouldKeepTheModeMenuShutWhileBusy() async throws {
    let composer = ChatComposerState()
    #expect(composer.canChangeMode(isLocked: false, isRunning: false, isSending: false))
    #expect(!composer.canChangeMode(isLocked: false, isRunning: false, isSending: true))
    #expect(!composer.canChangeMode(isLocked: false, isRunning: true, isSending: false))
    #expect(!composer.canChangeMode(isLocked: true, isRunning: false, isSending: false))

    let (gate, open) = AsyncStream<Void>.makeStream()
    let saving = Task { await composer.choose(.askFirst, current: .auto, save: saved(after: gate)) }
    try await ChatWait.until("the mode saves") { composer.switching == .manual }
    #expect(!composer.canChangeMode(isLocked: false, isRunning: false, isSending: false))
    open.finish()
    await saving.value
    #expect(composer.switching == nil)
  }

  @Test("should hold a send while the chat's mode is being saved")
  func shouldHoldASendWhileTheModeSaves() async throws {
    let world = try await ChatWorld.make()
    let model = world.model(of: try await world.session())
    model.draft = "Who is Mara?"
    #expect(model.canSendDraft)

    let (gate, open) = AsyncStream<Void>.makeStream()
    let saving = Task { await model.composer.choose(.askFirst, current: .auto, save: saved(after: gate)) }
    try await ChatWait.until("the mode saves") { model.composer.switching != nil }
    #expect(!model.canSendDraft)
    await model.sendDraft()
    #expect(model.messages.isEmpty && model.draft == "Who is Mara?")

    open.finish()
    await saving.value
    #expect(model.canSendDraft)
  }

  @Test("should start a New chat with fresh choices and the comments still waiting")
  func shouldStartANewChatWithFreshChoices() async throws {
    let world = try await ChatWorld.make()
    let source = try await drafted(world)
    let chats = ChatNovelModel(context: world.context, engine: world.engine)
    let composer = chats.composer
    _ = composer.add(try chip(source, quote: "harbour keys"))
    composer.proseEdits = true
    composer.replyOptions.thinkDeeper = true
    await composer.choose(.justDiscuss, current: composer.draftMode, save: nil)
    await composer.choose(.askFirst, current: composer.draftMode, save: nil)

    chats.newChat()

    #expect(!composer.proseEdits && !composer.justDiscussing)
    #expect(composer.replyOptions == ChatReplyOptions())
    #expect(composer.draftMode == .auto)
    #expect(composer.chips.count == 1)
  }

  @Test("should save Ask first on the chat, keep Just discuss in the composer and undo it when the save fails")
  func shouldSaveTheChatModeFromTheModeMenu() async throws {
    let world = try await ChatWorld.make()
    let session = try await world.session()
    let chats = ChatNovelModel(context: world.context, engine: world.engine)
    let observing = Task { await chats.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the chats load") { chats.overview(of: session) != nil }
    let composer = chats.session(session).composer

    await composer.choose(.askFirst, current: chats.mode(of: session)) { await chats.saveMode($0, of: session) }
    try await ChatWait.until("the chat turns manual") { chats.mode(of: session) == .manual }
    #expect(composer.mode(in: chats.mode(of: session)) == .askFirst)

    await composer.choose(.justDiscuss, current: .manual) { _ in true }
    #expect(composer.mode(in: .manual) == .justDiscuss)
    #expect(chats.mode(of: session) == .manual)

    await composer.choose(.editFreely, current: .manual) { _ in false }
    #expect(composer.justDiscussing)
    #expect(composer.switching == nil)
  }

  @Test("should hold ten comments, replace one on the same words and remove one")
  func shouldHoldTenCommentsAndReplaceOneOnTheSameWords() async throws {
    let world = try await ChatWorld.make()
    let source = try await drafted(world, prose: (0..<11).map { "Line \($0)." }.joined(separator: "\n\n"))
    let composer = ChatComposerState()
    let chips = try (0..<11).map { try chip(source, quote: "Line \($0).") }

    for chip in chips.prefix(ChatPassageChip.limit) { #expect(composer.add(chip) == .added) }
    #expect(composer.add(chips[10]) == .full)
    #expect(composer.add(try chip(source, quote: "Line 0.", comment: "Cut it.")) == .replaced)
    #expect(composer.chips.count == ChatPassageChip.limit)
    #expect(composer.chips.first?.passage.comment == "Cut it.")
    #expect(composer.chips.map(\.firstParagraph) == Array(1...10))

    composer.remove(chips[0].id)
    #expect(composer.passages.map(\.quote) == (1..<10).map { "Line \($0)." })
    #expect(composer.add(chips[10]) == .added)
  }

  @Test("should add a Reader selection to the open chat and send it as a passage of that chapter")
  func shouldSendAReaderSelectionAsAPassage() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Braver it is.")])
    let source = try await drafted(world)
    let session = try await world.session()
    let chats = ChatNovelModel(context: world.context, engine: world.engine)
    let quote = "harbour keys"
    let range = (source.body as NSString).range(of: quote)

    #expect(await chats.addPassage(try chip(source, quote: quote, comment: " Make her braver. ")) == .added)

    let model = chats.session(session)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    #expect(chats.composer.chips.isEmpty)
    let added = try #require(model.composer.chips.first?.passage)
    #expect(added.chapter == 1)
    #expect(added.start == range.location && added.end == range.location + range.length)
    #expect(added.quote == quote)
    #expect(model.composer.chips.first.map { [$0.firstParagraph, $0.lastParagraph] } == [1, 1])
    #expect(model.canSendDraft)

    await model.sendDraft()

    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Braver it is." }
    let context = try #require(try userMessage(model).contexts?.first)
    #expect(context["chapter"]?.intValue == 1)
    #expect(context["start"]?.intValue == Int64(range.location))
    #expect(context["end"]?.intValue == Int64(range.location + range.length))
    #expect(context["comment"]?.stringValue == "Make her braver.")
    #expect(model.composer.chips.isEmpty)
  }

  @Test("should keep the message and comments behind a consent prompt and send them once allowed")
  func shouldKeepTheMessageAndCommentsBehindAConsentPrompt() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Allowed now.")], granted: false)
    let source = try await drafted(world)
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    _ = model.composer.add(try chip(source, quote: "She never sleeps."))
    model.draft = "Why?"

    await model.sendDraft()

    let request = try #require(model.consentRequest)
    #expect(model.draft == "Why?")
    #expect(model.composer.chips.count == 1)
    try await world.grantConsent(host: request.host)
    model.consentRequest = nil
    await model.consentAllowed()
    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Allowed now." }
    #expect(model.draft.isEmpty)
    #expect(model.composer.chips.isEmpty)
  }

  @Test("should mark only the comment whose passage changed and keep the message")
  func shouldMarkOnlyTheCommentWhosePassageChanged() async throws {
    let world = try await ChatWorld.make()
    let rest = "She never sleeps, not once in all the long years of the war.\n\nThe tide turns at dawn and the boats go past the breakwater."
    let source = try await drafted(world, prose: "😀 Mara keeps the harbour keys.\n\n\(rest)")
    let model = world.model(of: try await world.session())
    _ = model.composer.add(try chip(source, quote: "harbour keys"))
    _ = model.composer.add(try chip(source, quote: "The tide turns"))
    let novel = world.novel
    let head = try await world.store.load(ChapterContent.self, ChapterLocator(novel: novel, chapter: 1))
    guard case .draft(let draft) = head.body else { throw CancellationError() }
    _ = try await ReaderModel(context: world.context).service.importDraft(chapter: 1, prose: "😀 Mara lost the keys.\n\n\(rest)", base: draft.revision)
    model.draft = "Why?"

    await model.sendDraft()

    #expect(model.notice?.error.detail == "CHT_009")
    #expect(model.draft == "Why?")
    #expect(model.composer.chips.map(\.isStale) == [true, false])
    #expect(!model.canSendDraft)
  }

  @Test("should mark every sent comment when none can be told apart")
  func shouldMarkEverySentCommentWhenNoneCanBeTold() async throws {
    let world = try await ChatWorld.make()
    let source = try await drafted(world)
    let composer = ChatComposerState()
    let keys = try chip(source, quote: "harbour keys")
    let sleeps = try chip(source, quote: "She never sleeps.")
    _ = composer.add(keys)
    _ = composer.add(sleeps)

    composer.markStale([keys.passage], unresolved: [])

    #expect(composer.chips.map(\.isStale) == [true, false])
  }

  @Test("should start a chat from the opening composer with its mode, choices and comments")
  func shouldStartAChatWithTheOpeningComposersChoices() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Let's look.")])
    let source = try await drafted(world)
    let chats = ChatNovelModel(context: world.context, engine: world.engine)
    let observing = Task { await chats.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the chats load") { chats.state.value != nil }
    #expect(chats.current == nil)

    #expect(await chats.addPassage(try chip(source, quote: "harbour keys")) == .added)
    await chats.composer.choose(.askFirst, current: chats.composer.draftMode, save: nil)
    chats.composer.proseEdits = true
    #expect(!chats.canStartDraft)
    chats.draft = "Look here."

    await chats.startDraft()

    let session = try #require(chats.current)
    let opened = chats.session(session)
    let reading = Task { await opened.observe() }
    defer { reading.cancel() }
    try await ChatWait.until("the reply lands") { opened.lastReply?.content == "Let's look." }
    try await ChatWait.until("the chat is listed") { chats.overview(of: session) != nil }
    #expect(chats.mode(of: session) == .manual)
    let sent = try userMessage(opened)
    #expect(sent.proseEdits == true)
    #expect(sent.contexts?.count == 1)
    #expect(opened.composer.proseEdits)
    #expect(opened.composer.chips.isEmpty && chats.composer.chips.isEmpty)
    #expect(chats.draft.isEmpty)
    #expect(!chats.composer.proseEdits && chats.composer.draftMode == .auto)
  }

  @Test("should add a quick comment after the author's words")
  func shouldAddAQuickCommentAfterTheAuthorsWords() {
    #expect(ChatPassageCommentSheet.withQuickComment("  ", "Cut") == "Cut")
    #expect(ChatPassageCommentSheet.withQuickComment("Too slow", "Cut") == "Too slow. Cut")
    #expect(ChatPassageCommentSheet.withQuickComment("Too slow!", "Cut") == "Too slow! Cut")
  }
}
