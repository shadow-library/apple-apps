import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import NovelForge

private typealias Script = ChatCardsScript

@MainActor
@Suite("Chat cards", TestTimeLimit.standard)
struct ChatCardsModelTests {
  private static let places = Script.reply("Two places.", ops: [Script.idea("hall", "Saltgate Hall"), Script.idea("quay", "Ember Quay")])

  private func pendingCard(_ world: ChatCardsWorld) async throws -> (ChatProposalCardModel, Task<Void, Never>) {
    let reply = try await world.reply(to: "Add two places.")
    let model = world.card(try #require(reply.cardProposal))
    let task = observing { await model.observe() }
    try await ChatWait.until("the card loads") { model.status == .pending }
    return (model, task)
  }

  @Test func shouldApplyTheWholeCardAndReadItApplied() async throws {
    let world = try await ChatCardsWorld.make([Self.places])
    let (model, task) = try await pendingCard(world)
    defer { task.cancel() }
    #expect(model.selected == [0, 1])
    #expect(model.applyTitle == String(localized: "Apply", table: "ChatCards"))

    await model.apply()

    try await ChatWait.until("the card reads applied") { model.status == .applied }
    #expect(model.snapshot?.state(of: 0) == .applied && model.snapshot?.state(of: 1) == .applied)
    #expect(model.notice == nil && model.canRevert && !model.canDiscard)
  }

  @Test func shouldApplyOnlyTheSelectedChanges() async throws {
    let world = try await ChatCardsWorld.make([Self.places])
    let (model, task) = try await pendingCard(world)
    defer { task.cancel() }

    model.toggle(model.ops[1])
    #expect(model.selected == [0])
    #expect(model.applyTitle == String(localized: "Apply \(1) selected", table: "ChatCards"))
    await model.apply()

    try await ChatWait.until("the card reads applied") { model.status == .applied }
    #expect(model.snapshot?.state(of: 0) == .applied)
    #expect(model.snapshot?.state(of: 1) == .declined)
  }

  @Test func shouldDiscardTheCard() async throws {
    let world = try await ChatCardsWorld.make([Self.places])
    let (model, task) = try await pendingCard(world)
    defer { task.cancel() }

    await model.discard()

    try await ChatWait.until("the card reads discarded") { model.status == .discarded }
    #expect(!model.canApply && !model.canDiscard && !model.isPending)
  }

  @Test func shouldShowAConflictedCardAndRefuseToApplyIt() async throws {
    let world = try await ChatCardsWorld.make([Self.places])
    let (stale, staleTask) = try await pendingCard(world)
    staleTask.cancel()
    await staleTask.value
    let novel = world.novel
    try await world.store.writeDomain { transaction throws(DomainError) in
      try Entities.create(novel: novel, entity: "hall", type: .location, name: "The Old Hall", in: &transaction)
    }

    let fresh = world.card(stale.proposal)
    let freshTask = observing { await fresh.observe() }
    defer { freshTask.cancel() }
    try await ChatWait.until("the card reads conflicted") { fresh.status == .conflicted }
    #expect(!fresh.canApply && fresh.canDiscard)
    #expect(fresh.snapshot?.conflict?.indexes == [0])

    await stale.apply()

    #expect(stale.status == .conflicted)
    #expect(stale.notice?.error == PresentedError(headline: ChatCardsErrors.conflicted, detail: "RFN_003"))
    #expect(fresh.snapshot?.decision == .known(.pending))
  }

  @Test func shouldUndoThenRedoOneChangeOfAReply() async throws {
    let world = try await ChatCardsWorld.make([Script.reply("Noted.", ops: [Script.quotedCharacter("mara", "Mara")])], mode: .auto)
    let reply = try await world.reply(to: Script.quotedMessage)
    let model = try world.receipt(reply)
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the receipt loads") { model.changes.count == 1 }
    let change = try #require(model.changes.first)
    #expect(!model.isIdea(change) && model.canToggle(change))

    await model.toggle(change)
    try await ChatWait.until("the change reads undone") { model.state(of: change) == .reverted }
    #expect(model.title == String(localized: "Every change from this reply was undone.", table: "ChatCards"))

    await model.toggle(change)
    try await ChatWait.until("the change reads applied") { model.state(of: change) == .applied }
    #expect(model.notices.isEmpty && model.prompt == nil)
  }

  @Test func shouldAskHowLongToTurnDownAnIdeaBeforeUndoingIt() async throws {
    let world = try await ChatCardsWorld.make([Script.reply("A place.", ops: [Script.idea("hall", "Saltgate Hall")])], mode: .auto)
    let reply = try await world.reply(to: "Add a place.")
    let model = try world.receipt(reply)
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the receipt loads") { model.changes.count == 1 }
    let change = try #require(model.changes.first)
    #expect(model.isIdea(change))

    await model.toggle(change)
    #expect(model.revert.target == .change(proposal: model.proposal, index: 0, isIdea: true))
    try await ChatWait.until("the impact loads") { model.revert.impact != .loading }
    model.revert.ideaScope = .never
    await model.revert.confirm()

    try await ChatWait.until("the idea reads undone") { model.state(of: change) == .reverted }
    #expect(!model.revert.isPresented)
  }

  @Test func shouldRevertTheWholeCardAfterShowingWhatReliesOnIt() async throws {
    let world = try await ChatCardsWorld.make([Self.places])
    let (model, task) = try await pendingCard(world)
    defer { task.cancel() }
    await model.apply()
    try await ChatWait.until("the card reads applied") { model.status == .applied }
    var finished: ChatRevertFlow.Outcome?
    model.revert.onFinished = { finished = $0 }

    model.openRevert()
    #expect(model.revert.target == .proposals([model.proposal]))
    try await ChatWait.until("the impact loads") { model.revert.impact != .loading }
    #expect(model.revert.impact == .loaded(.none))
    #expect(model.revert.canConfirm)
    await model.revert.confirm()

    #expect(finished == .reverted([model.proposal]))
    #expect(!model.revert.isPresented)
    try await ChatWait.until("the card reads reverted") { model.status == .reverted }
  }

  @Test func shouldRefuseAStaleApprovalWithItsCode() async throws {
    let world = try await ChatCardsWorld.make([Script.reply("Ready to approve.", ops: [Script.approveFirst])])
    let novel = world.novel
    let first = try await world.store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "The tide came in."), base: nil, at: Date(), in: &transaction)
    }
    guard case .committed(let head) = first else { throw ChatFixtureError.noBinding }
    let reply = try await world.reply(to: "Approve chapter 1.")
    let model = world.card(try #require(reply.cardProposal))
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the card loads") { model.status == .pending }
    let approval = try #require(model.ops.first)
    #expect(approval.isGuarded && !approval.isJobAction && !model.isSelected(approval) && !model.canApply)
    _ = try await world.store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "The tide went out."), base: head, at: Date(), in: &transaction)
    }

    model.toggle(approval)
    #expect(model.applyTitle == String(localized: "Apply", table: "ChatCards"))
    await model.apply()

    try await ChatWait.until("the approval reads failed") { model.snapshot?.state(of: 0) == .failed }
    #expect(model.failureCode(of: 0) == "DRF_013")
    #expect(ChatCardsErrors.failure("DRF_013") != ChatCardsErrors.failure("not-a-code"))
  }

  @Test func shouldKeepAnActionWithNoExecutorUnselectable() async throws {
    let world = try await ChatCardsWorld.make([Script.reply("Shall I audit it?", ops: [#"{"op":"action.audit_bible"}"#])])
    let reply = try await world.reply(to: "Audit the bible.")
    let model = world.card(try #require(reply.cardProposal))
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the card loads") { model.status == .pending }
    let job = try #require(model.ops.first)

    model.toggle(job)

    #expect(job.isJobAction && !model.isSelectable(job) && !model.isSelected(job) && !model.canApply)
  }

  @Test func shouldLetARunnableJobActionBeSelectedDeliberately() async throws {
    let world = try await ChatCardsWorld.make([Script.reply("Shall I write it?", ops: [#"{"op":"action.generate_chapter","chapter":1}"#])])
    let reply = try await world.reply(to: "Write chapter 1.")
    let model = world.card(try #require(reply.cardProposal))
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the card loads") { model.status == .pending }
    let job = try #require(model.ops.first)
    #expect(!job.isJobAction && job.isGuarded && model.isSelectable(job) && !model.isSelected(job))

    model.toggle(job)

    #expect(model.isSelected(job) && model.canApply)
  }

  @Test func shouldAnswerAQuestionAndSettleIt() async throws {
    let answers = #"[{"title":"Mara","recommended":true},{"title":"Cole","tradeOff":"Less history"}]"#
    let question = #"{"question":"Who leads the crew?","why":"The first chapter needs a lead.","answers":\#(answers),"progressKey":"protagonist"}"#
    let world = try await ChatCardsWorld.make([Script.reply("One question.", question: question), Script.reply("Mara it is.")])
    let reply = try await world.reply(to: "Ask me something.")
    let block = try #require(reply.questionCard)
    #expect(block.answers.map(\.title) == ["Mara", "Cole"])
    #expect(block.answers.map(\.recommended) == [true, false])
    #expect(block.progressItem == .protagonist)
    let session = world.chat.model(of: world.session)
    let task = observing { await session.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the transcript loads") { session.messages.count == 2 }
    #expect(!ChatQuestionAnswering.isSettled(reply: reply.id, in: session.messages))

    #expect(await session.send(block.answers[0].title))

    try await ChatWait.until("the answer settles the question") { ChatQuestionAnswering.isSettled(reply: reply.id, in: session.messages) }
    let undecided = await ChatQuestionAnswering.leaveUndecided(block.progressItem, session: session)
    #expect(undecided?.error.detail == nil)
    let checklist = try await world.store.load(ProgressChecklist.self, world.novel)
    #expect(checklist.checklist.value?.checklist?.items.first { $0.key == .protagonist }?.status == .undecided)
  }
}
