import Foundation
import NovelForgeCore
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

@MainActor
@Suite("ChatSessionModel", .timeLimit(.minutes(3)))
struct ChatSessionModelTests {
  @Test("should stream the reply as it is written, then show it in the transcript with its cost")
  func shouldStreamTheReplyThenShowItInTheTranscript() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Mara keeps", then: " the harbour keys.", for: .milliseconds(600))])
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the transcript loads") { model.page != nil }

    model.draft = "Who is Mara?"
    #expect(await model.send("Who is Mara?"))

    #expect(model.draft.isEmpty)
    try await ChatWait.until("the reply streams") { model.streamedText?.contains("Mara keeps") == true }
    #expect(model.isTurnActive)
    try await ChatWait.until("the reply lands") { model.transcriptRoles == [.known(.user), .known(.assistant)] && model.display == .idle }
    let reply = try #require(model.lastReply)
    #expect(reply.content == "Mara keeps the harbour keys.")
    #expect(model.messages.first?.record?.contentMode == .known(.standard))
    #expect(model.cost(of: reply.id) != nil)
    #expect(!model.isTurnActive)
  }

  @Test("should stop a running turn and offer to try it again")
  func shouldStopARunningTurnAndOfferToTryAgain() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Let me", then: " think.", for: .seconds(60)), ChatScript.reply("Here it is.")])
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }

    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { model.streamedText?.contains("Let me") == true }
    model.stop()

    try await ChatWait.until("the turn reads stopped") {
      guard case .stopped(let turn, let shown) = model.display else { return false }
      return model.canRetry(turn) && shown.text.contains("Let me")
    }
    #expect(model.lastReply == nil)

    await model.retry()
    try await ChatWait.until("the retried reply lands") { model.lastReply?.content == "Here it is." && model.display == .idle }
  }

  @Test("should show a failed turn with its copy and try it again")
  func shouldShowAFailedTurnAndTryItAgain() async throws {
    let world = try await ChatWorld.make([ChatScript.failing(.authentication), ChatScript.reply("Second time lucky.")])
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }

    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the turn fails") {
      guard case .failed(_, let failure, _) = model.display else { return false }
      return failure.code == "model.authentication"
    }
    guard case .failed(_, let failure, _) = model.display else { return }
    #expect(ChatErrors.copy(for: failure).opensSettings)
    #expect(model.transcriptRoles == [.known(.user)])

    await model.retry()
    try await ChatWait.until("the retried reply lands") { model.lastReply?.content == "Second time lucky." && model.display == .idle }
    #expect(model.transcriptRoles == [.known(.user), .known(.assistant)])
  }

  @Test("should show an interrupted turn and resume it")
  func shouldShowAnInterruptedTurnAndResumeIt() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Half", then: " done.", for: .seconds(60)), ChatScript.reply("All done.")])
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }

    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { model.streamedText?.contains("Half") == true }
    guard case .running(let turn) = model.display else { return }
    world.engine.interrupt(turn: turn.turn)

    try await ChatWait.until("the turn reads interrupted") {
      guard case .interrupted = model.display else { return false }
      return true
    }
    await model.resume()
    try await ChatWait.until("the resumed reply lands") { model.lastReply?.content == "All done." && model.display == .idle }
  }

  @Test("should show a message another device is answering and answer it here")
  func shouldShowAMessageAnotherDeviceIsAnsweringAndAnswerItHere() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Half", then: " done.", for: .seconds(60)), ChatScript.reply("Answered here.")])
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { model.streamedText?.contains("Half") == true }
    guard case .running(let turn) = model.display else { return }
    world.engine.interrupt(turn: turn.turn)
    try await ChatWait.until("the turn reads interrupted") {
      guard case .interrupted = model.display else { return false }
      return true
    }

    try await world.store.clearLocalTurn(turn.turn)
    await model.refreshActivity()

    let message = try #require(model.messages.first?.record?.id)
    #expect(model.display == .elsewhere(message: message, answerable: true))
    await model.answerHere()
    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Answered here." && model.display == .idle }
    #expect(model.lastReply?.answers == message)
  }

  @Test("should ask for consent under the v2 disclosure and send once it is allowed")
  func shouldAskForConsentUnderTheV2DisclosureAndSendOnceAllowed() async throws {
    let world = try await ChatWorld.make([ChatScript.reply("Allowed now.")], granted: false)
    let model = world.model(of: try await world.session())
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the transcript loads") { model.page != nil }

    model.draft = "Who is Mara?"
    await model.sendDraft()

    let request = try #require(model.consentRequest)
    #expect(request.disclosure == "novel-text/v2")
    #expect(ConsentDisclosure(request) == .novelText)
    #expect(model.draft == "Who is Mara?")
    #expect(model.messages.isEmpty)

    try await world.grantConsent(host: request.host)
    model.consentRequest = nil
    await model.consentAllowed()
    try await ChatWait.until("the reply lands") { model.lastReply?.content == "Allowed now." }
    #expect(model.draft.isEmpty)
  }

  @Test("should refuse a send in an archived chat and keep the message")
  func shouldRefuseASendInAnArchivedChat() async throws {
    let world = try await ChatWorld.make()
    let session = try await world.session()
    try await world.store.archiveChatSession(session, novel: world.novel)
    let model = world.model(of: session)
    model.draft = "Who is Mara?"

    await model.sendDraft()

    #expect(model.notice?.error.detail == ChatTurnError.sessionArchived.code)
    #expect(model.draft == "Who is Mara?")
  }

  @Test("should resume an interrupted turn at launch and follow it again")
  func shouldResumeAnInterruptedTurnAtLaunchAndFollowItAgain() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Half", then: " done.", for: .seconds(60)), ChatScript.paused("Resumed", then: " at launch.", for: .milliseconds(600))])
    let session = try await world.session()
    let first = world.model(of: session)
    #expect(await first.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { first.streamedText?.contains("Half") == true }
    guard case .running(let turn) = first.display else { return }
    world.engine.interrupt(turn: turn.turn)
    try await ChatWait.until("the turn stays pending") {
      guard case .interrupted = first.display else { return false }
      return true
    }

    let runtime = ChatRuntime(store: world.store, engine: try await world.relaunched())
    await runtime.launch()
    await runtime.launch()
    let model = runtime.model(for: world.context).session(session)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }

    try await ChatWait.until("the resumed reply lands") { model.lastReply?.content == "Resumed at launch." && model.display == .idle }
    #expect(world.provider.remainingCalls == 0)
  }

  @Test("should stream a turn that launch resumes while its chat is already open")
  func shouldStreamATurnLaunchResumesWhileItsChatIsOpen() async throws {
    let world = try await ChatWorld.make([
      ChatScript.paused("Half", then: " done.", for: .seconds(60)), ChatScript.paused("Resumed", then: " at launch.", for: .seconds(3)),
    ])
    let session = try await world.session()
    let first = world.model(of: session)
    #expect(await first.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { first.streamedText?.contains("Half") == true }
    guard case .running(let turn) = first.display else { return }
    world.engine.interrupt(turn: turn.turn)
    try await ChatWait.until("the turn stays pending") {
      guard case .interrupted = first.display else { return false }
      return true
    }

    let runtime = ChatRuntime(store: world.store, engine: try await world.relaunched())
    let model = runtime.model(for: world.context).session(session)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the open chat shows the interrupted turn") {
      guard case .interrupted = model.display else { return false }
      return true
    }
    try await Task.sleep(for: .milliseconds(300))

    await runtime.launch()
    try await ChatWait.until("the resumed turn streams in the open chat") { model.streamedText?.contains("Resumed") == true }
    try await ChatWait.until("the resumed reply lands") { model.lastReply?.content == "Resumed at launch." }
  }

  @Test("should not offer Answer Here for a message that follows an unrestricted novel while the flag is off")
  func shouldNotOfferAnswerHereForAMessageThatFollowsAnUnrestrictedNovel() async throws {
    let world = try await ChatWorld.make(contentMode: .unrestricted)
    let session = try await world.session()
    let message = try ChatMessageRecord(novel: world.novel, session: session, role: .user, content: "Who is Mara?")
    try await world.store.write { transaction in _ = try message.append(in: &transaction) }
    let chats = ChatNovelModel(context: world.context, engine: world.engine)
    let observingChats = Task { await chats.observe() }
    defer { observingChats.cancel() }
    try await ChatWait.until("the chats load") { chats.novelTitle != nil }
    let model = chats.session(session)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }

    try await ChatWait.until("the message reads as answered elsewhere") { model.display == .elsewhere(message: message.id, answerable: false) }
    await model.answerHere()
    #expect(world.provider.requests.isEmpty)
  }

  @Test("should keep a stopped turn's text when it is read again after a relaunch")
  func shouldKeepAStoppedTurnsTextAfterARelaunch() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Let me", then: " think.", for: .seconds(60))])
    let session = try await world.session()
    let first = world.model(of: session)
    #expect(await first.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { first.streamedText?.contains("Let me") == true }
    first.stop()
    try await ChatWait.until("the turn reads stopped") {
      guard case .stopped = first.display else { return false }
      return true
    }

    let runtime = ChatRuntime(store: world.store, engine: try await world.relaunched())
    let model = runtime.model(for: world.context).session(session)
    let observing = Task { await model.observe() }
    defer { observing.cancel() }

    try await ChatWait.until("the stopped turn shows its text") {
      guard case .stopped(_, let shown) = model.display else { return false }
      return shown.text.contains("Let me")
    }
  }
}

@MainActor
@Suite("Chat consent and gates")
struct ChatConsentTests {
  @Test("should describe the earlier conversation and usage figures under the v2 disclosure and no longer map v1")
  func shouldDescribeTheConversationUnderV2AndNoLongerMapV1() {
    #expect(ConsentDisclosure.novelText.id == "novel-text/v2")
    #expect(ConsentDisclosure(AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "novel-text", disclosure: "novel-text/v1")) == nil)
    let explanation = ConsentDisclosure.novelText.explanation(provider: "Anthropic")
    #expect(explanation.contains("earlier conversation"))
    #expect(explanation.contains("usage"))
  }

  @Test("should refuse an unrestricted request while the build flag is off")
  func shouldRefuseAnUnrestrictedRequestWhileTheFlagIsOff() async throws {
    #expect(!UnrestrictedWriting.isAvailable)
    let world = try await ChatWorld.make()
    let model = world.model(of: try await world.session())

    #expect(await model.send("Who is Mara?", choices: ChatTurnChoices(contentMode: .unrestricted)) == false)

    #expect(model.notice?.error.detail == "AI_024")
  }

  @Test("should keep one runtime per open vault")
  func shouldKeepOneRuntimePerOpenVault() throws {
    let runtimes = ChatRuntimes()
    let settings = try SettingsFixtures.world()
    defer { settings.tearDown() }
    let services = settings.services
    let store = try NovelForgeStore.openInMemory()
    #expect(runtimes.runtime(for: store, services: services) === runtimes.runtime(for: store, services: services))
    #expect(runtimes.runtime(for: try NovelForgeStore.openInMemory(), services: services) !== runtimes.runtime(for: store, services: services))
  }
}
