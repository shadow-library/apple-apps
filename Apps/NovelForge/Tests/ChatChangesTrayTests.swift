import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

private typealias Script = ChatCardsScript

/// A novel whose chats hold a pending card, a question and a message no turn answers here, with its chats' and tray's observation running.
@MainActor
private struct TrayWorld {
  let world: ChatCardsWorld
  let chats: ChatNovelModel
  let asking: UUID
  let waiting: UUID
  let card: UUID
  let question: UUID
  let message: ChatMessageRecord
  let tasks: [Task<Void, Never>]

  var tray: ChatTrayModel { chats.waiting }

  static let questionJSON = #"{"question":"Who leads the crew?","answers":[{"title":"Mara"},{"title":"Cole"}]}"#

  static func make() async throws -> TrayWorld {
    let world = try await ChatCardsWorld.make([Script.reply("A place.", ops: [Script.idea("hall", "Saltgate Hall")]), Script.reply("One question.", question: questionJSON)])
    let card = try #require(try await world.reply(to: "Add a place.").cardProposal)
    let asking = try await titled("Asking", world)
    let question = try await ChatCardsTurns.reply(to: "Ask me something.", engine: world.chat.engine, store: world.store, session: asking, novel: world.novel).id
    let waiting = try await titled("Waiting", world)
    let message = try await append("Who is Mara?", to: waiting, world)
    let chats = ChatNovelModel(context: world.context, engine: world.chat.engine)
    let tasks = [observing { await chats.observe() }, observing { await chats.waiting.observe() }]
    try await ChatWait.until("the chats load") { chats.overviews.count == 3 }
    return TrayWorld(world: world, chats: chats, asking: asking, waiting: waiting, card: card, question: question, message: message, tasks: tasks)
  }

  static func titled(_ title: String, _ world: ChatCardsWorld) async throws -> UUID {
    let session = try await world.store.createChatSession(novel: world.novel).id
    try await world.store.renameChatSession(session, novel: world.novel, title: title)
    return session
  }

  static func append(_ content: String, to session: UUID, _ world: ChatCardsWorld) async throws -> ChatMessageRecord {
    let message = try ChatMessageRecord(novel: world.novel, session: session, role: .user, content: content)
    try await world.store.write { transaction in _ = try message.append(in: &transaction) }
    return message
  }

  func item(_ id: String) -> ChatTrayItem? { tray.items.first { $0.id == id } }

  func stop() {
    for task in tasks { task.cancel() }
  }
}

@MainActor
@Suite("Chat waiting tray", TestTimeLimit.standard)
struct ChatChangesTrayTests {
  @Test func shouldListPendingCardsQuestionsAndWaitingMessagesAcrossChatsAndUpdateLive() async throws {
    let world = try await TrayWorld.make()
    defer { world.stop() }

    try await ChatWait.until("everything waiting is listed") { world.tray.items.count == 3 }
    #expect(world.tray.items.map(\.id) == ["message:\(world.message.id)", "question:\(world.question)", "card:\(world.card)"])
    #expect(world.item("card:\(world.card)")?.session == .live(world.world.session))
    #expect(world.item("card:\(world.card)")?.kind == .card(conflicts: nil))
    #expect(world.item("question:\(world.question)")?.title == "Who leads the crew?")
    #expect(world.item("question:\(world.question)")?.target == .message(world.question))

    try await world.world.writer.discard(world.card, novel: world.world.novel)
    try await ChatWait.until("the discarded card leaves the tray") { world.item("card:\(world.card)") == nil }
    let answer = try await TrayWorld.append("Mara.", to: world.asking, world.world)
    try await ChatWait.until("the answered question leaves the tray") { world.item("question:\(world.question)") == nil }
    try await ChatWait.until("the answer waits for its own reply") { world.item("message:\(answer.id)") != nil }
    #expect(Set(world.tray.items.map(\.id)) == ["message:\(world.message.id)", "message:\(answer.id)"])
  }

  @Test func shouldOpenTheItemsChatAndShowItsRow() async throws {
    let world = try await TrayWorld.make()
    defer { world.stop() }
    try await ChatWait.until("the question is listed") { world.item("question:\(world.question)") != nil }
    let item = try #require(world.item("question:\(world.question)"))

    world.chats.reveal(item.target, in: world.asking)

    #expect(world.chats.current == world.asking)
    let session = world.chats.session(world.asking)
    #expect(session.focus == item.target)
    let reading = observing { await session.observe() }
    defer { reading.cancel() }
    try await ChatWait.until("the row to show is found") { session.focusedRow != nil }
    #expect(session.focusedRow == session.messages.first { $0.record?.id == world.question }?.row.key)
    session.focusShown()
    #expect(session.focus == nil && session.focusedRow == nil)
  }

  @Test func shouldOfferAnswerHereOnlyForAMessageThatCanBeAnswered() async throws {
    let world = try await TrayWorld.make()
    defer { world.stop() }
    try await ChatWait.until("the waiting message is listed") { world.item("message:\(world.message.id)") != nil }
    let waiting = try #require(world.item("message:\(world.message.id)"))
    #expect(waiting.kind == .elsewhere(nil) && waiting.isAnswerable)

    let summary = try ChatSummaryRecord(novel: world.world.novel, session: world.waiting, covered: [world.message.id], text: "Mara asked about.", contentMode: .standard)
    try await world.world.store.write { transaction in _ = try summary.append(in: &transaction) }

    try await ChatWait.until("the folded message is listed as such") { world.item("message:\(world.message.id)")?.kind == .elsewhere(.folded) }
    #expect(world.item("message:\(world.message.id)")?.isAnswerable == false)
    let session = world.chats.session(world.waiting)
    let reading = observing { await session.observe() }
    defer { reading.cancel() }
    try await ChatWait.until("the chat reads the message folded") { session.display == .elsewhere(message: world.message.id, answerable: false) }
    #expect(session.answerBlock(world.message.id) == .folded)
    let requests = world.world.chat.provider.requests.count
    await session.answerHere()
    #expect(world.world.chat.provider.requests.count == requests)
  }

  @Test func shouldListWaitingMessagesThenQuestionsThenCardsThenActionsAndSkipWhatWaitsOnNobody() {
    let (chat, other, card, applied, asked, sent) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
    let snapshot = ChatTraySnapshot(
      cards: .available(
        ChatTrayCards(
          cards: [
            ChatTrayCard(proposal: card, session: .deleted(other), title: nil, conflicts: nil)
          ],
          actions: [
            ChatTrayActions(proposal: applied, session: .live(chat), title: "Approve chapter 3", indexes: [0, 1], standing: .faulted(code: "DRF_013", givenUp: true))
          ])),
      lasts: [
        ChatTrayLast(session: chat, message: asked, kind: .question("Who leads?")),
        ChatTrayLast(session: other, message: sent, kind: .author(.unrestricted)),
      ])

    let items = ChatTrayItem.items(snapshot, activities: [other: .elsewhere(message: sent)])

    #expect(items.map(\.id) == ["message:\(sent)", "question:\(asked)", "card:\(card)", "actions:\(applied)"])
    #expect(items.map(\.kind) == [.elsewhere(.unrestricted), .question, .unreadableCard, .actions(indexes: [0, 1], standing: .faulted(code: "DRF_013", givenUp: true))])
    #expect(!items[0].isAnswerable)
    #expect(ChatTrayItem.items(snapshot, activities: [:]).map(\.id) == ["question:\(asked)", "card:\(card)", "actions:\(applied)"])
    #expect(ChatTrayItem.items(snapshot, activities: [other: .failed])[0].kind == .failed)
    #expect(ChatTrayItem.items(snapshot, activities: [other: .elsewhere(message: UUID())]).count == 3)
  }

  @Test func shouldSayWhyActionsAreStillPending() {
    let faulted = ChatTrayItem.Kind.actions(indexes: [0], standing: .faulted(code: "DRF_013", givenUp: false))
    let givenUp = ChatTrayItem.Kind.actions(indexes: [0, 1], standing: .faulted(code: nil, givenUp: true))
    let elsewhere = ChatTrayItem.Kind.actions(indexes: [2], standing: .notHere)

    #expect(ChatTrayText.detail(faulted) == "1 action stopped before it ran. Novel Forge tries it again the next time it opens.")
    #expect(ChatTrayText.detail(givenUp)?.hasPrefix("2 actions stopped before they ran, and Novel Forge has stopped retrying") == true)
    #expect(ChatTrayText.detail(elsewhere) == "1 action hasn't finished on the device that applied this card.")
    #expect(ChatTrayText.detail(.card(conflicts: [0, 2]))?.hasPrefix("2 changes no longer match") == true)
    #expect(ChatTrayText.detail(.elsewhere(nil)) == nil)
    #expect(ChatTrayText.code(faulted) == "DRF_013" && ChatTrayText.code(givenUp) == nil && ChatTrayText.code(elsewhere) == nil)
  }

  @Test func shouldListActionsOnlyOnceTheSweepFaultedThemOrNoRowIsHere() {
    #expect(ChatTraySnapshot.standing(nil) == .notHere)
    #expect(ChatTraySnapshot.standing((fault: nil, isGivenUp: false)) == nil)
    #expect(ChatTraySnapshot.standing((fault: "DRF_013", isGivenUp: false)) == .faulted(code: "DRF_013", givenUp: false))
    #expect(ChatTraySnapshot.standing((fault: nil, isGivenUp: true)) == .faulted(code: nil, givenUp: true))
  }

  @Test func shouldTitleACardByTheFirstLineOfItsTrimmedSummaryElseItsOneActionElseItsCount() {
    let place = ChatOp(index: 0, stored: .object(["op": .string("entity.upsert"), "entityKey": .string("hall"), "name": .string("Saltgate Hall")]), problems: [])
    let approve = ChatOp(index: 0, stored: .object(["op": .string("action.approve_draft"), "chapter": .int(3)]), problems: [])

    #expect(ChatTrayTitles.title(summary: "\n  Two new places \nand a rule", ops: [place]) == "Two new places")
    #expect(ChatTrayTitles.title(summary: "   ", ops: [approve]) == approve.subject)
    #expect(ChatTrayTitles.title(summary: nil, ops: [place]) == "1 change")
    #expect(ChatTrayTitles.title(summary: nil, ops: [place, approve]) == "2 changes")
  }

  @Test func shouldLeaveOutAQuestionItsChecklistItemWasLeftUndecidedFor() async throws {
    let question = #"{"question":"Who leads the crew?","answers":[{"title":"Mara"},{"title":"Cole"}],"progressKey":"protagonist"}"#
    let world = try await ChatCardsWorld.make([Script.reply("One question.", question: question)])
    let reply = try await world.reply(to: "Ask me something.")
    let chats = ChatNovelModel(context: world.context, engine: world.chat.engine)
    let task = observing { await chats.waiting.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the question is listed") { chats.waiting.items.map(\.id) == ["question:\(reply.id)"] }

    try await NotebookService(store: world.store, novel: world.novel).override(.protagonist, as: .undecided)

    try await ChatWait.until("the undecided question leaves the tray") { chats.waiting.items.isEmpty }
  }

  @Test func shouldHideTheMessageOfARunningTurnAndOfOneTheAuthorStopped() async throws {
    let world = try await ChatWorld.make([ChatScript.paused("Half", then: " done.", for: .seconds(60))])
    let session = try await world.session()
    let chats = ChatNovelModel(context: world.context, engine: world.engine)
    let model = chats.session(session)
    let tasks = [observing { await chats.observe() }, observing { await chats.waiting.observe() }, observing { await model.observe() }]
    defer { for task in tasks { task.cancel() } }
    #expect(await model.send("Who is Mara?"))
    try await ChatWait.until("the reply streams") { model.streamedText?.contains("Half") == true }
    try await ChatWait.until("the tray reads the author's message") { chats.waiting.state.value?.lasts.contains { $0.session == session } == true }

    await chats.waiting.refreshActivities()
    #expect(chats.waiting.activities[session] == nil && chats.waiting.items.isEmpty)

    model.stop()
    try await ChatWait.until("the turn reads stopped") {
      guard case .stopped = model.display else { return false }
      return true
    }
    await chats.waiting.refreshActivities()
    #expect(chats.waiting.activities[session] == nil && chats.waiting.items.isEmpty)
  }

  @Test func shouldPageBackUntilTheWindowHoldsAnOldItem() async throws {
    let world = try await ChatWorld.make()
    let session = try await world.session()
    var first: UUID?
    for index in 0...ChatTranscript.pageSize {
      let message = try ChatMessageRecord(novel: world.novel, session: session, role: .user, content: "Note \(index).")
      try await world.store.write { transaction in _ = try message.append(in: &transaction) }
      if first == nil { first = message.id }
    }
    let oldest = try #require(first)
    let model = world.model(of: session)
    let task = observingGenerations(model)
    defer { task.cancel() }
    try await ChatWait.until("the newest page loads") { model.page?.hasEarlier == true }
    #expect(!model.messages.contains { $0.record?.id == oldest })

    model.focus(on: .message(oldest))

    try await ChatWait.until("the window grows to hold it") { model.focusedRow != nil }
    #expect(model.window > ChatTranscript.pageSize)
    #expect(model.focusedRow == model.messages.first { $0.record?.id == oldest }?.row.key)
  }

  @Test func shouldDropAFocusNoPageHolds() async throws {
    let world = try await ChatWorld.make()
    let session = try await world.session()
    let message = try ChatMessageRecord(novel: world.novel, session: session, role: .user, content: "Who is Mara?")
    try await world.store.write { transaction in _ = try message.append(in: &transaction) }
    let model = world.model(of: session)
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the transcript loads") { model.messages.count == 1 }

    model.focus(on: .proposal(UUID()))

    #expect(model.focus == nil && model.focusedRow == nil)
  }
}

/// Reads the transcript again whenever its window grows, as the screen's `.task(id: generation)` does.
@MainActor
private func observingGenerations(_ model: ChatSessionModel) -> Task<Void, Never> {
  Task {
    var generation: Int?
    var reading: Task<Void, Never>?
    while !Task.isCancelled {
      if model.generation != generation {
        generation = model.generation
        reading?.cancel()
        reading = Task { await model.observe() }
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    reading?.cancel()
  }
}
