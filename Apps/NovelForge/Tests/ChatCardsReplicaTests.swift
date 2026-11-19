import Foundation
import NovelForgeCore
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

private typealias Script = ChatCardsScript

@MainActor
@Suite("Chat cards across devices", TestTimeLimit.standard)
struct ChatCardsReplicaTests {
  private func entityExists(_ key: String, on store: VaultStore, novel: UUID) async throws -> Bool {
    try await store.read { transaction in try EntityRecord.read(EntityRecord.ref(novel: novel, entity: key), in: transaction).entry?.isRemoved == false }
  }

  // ChatReplicaInterleavingTests.shouldKeepBothRepliesAndOneEntityWhenTwoDevicesAnswerOneMessage: two replies to one message each created `mara`; undoing
  // one twin removed it, so the other's undo refuses RFN_006 and redoing the undone twin brings it back
  @Test func shouldExplainATwinsUndoRefusalAndRecoverByRedoingTheOtherChange() async throws {
    let created = Script.reply("Noted.", ops: [Script.quotedCharacter("mara", "Mara")])
    let world = try await ChatCardsReplicas.make([[[.failure(.authentication)], created], [created]], mode: .auto)
    let failed = try await world.engines[0].send(Script.quotedMessage, session: world.session, novel: world.novel)
    guard case .failed = await failed.outcome() else { throw ChatFixtureError.noBinding }
    try await world.settle()
    #expect(try await world.engines[1].activity(session: world.session) == .answeringElsewhere(message: failed.userMessage))

    let answered = try await world.engines[1].answer(message: failed.userMessage, session: world.session, novel: world.novel)
    guard case .answered(let there) = await answered.outcome() else { throw ChatFixtureError.noBinding }
    try await world.flush(1)
    let retried = try await world.engines[0].retry(turn: failed.turn)
    guard case .answered(let here) = await retried.outcome() else { throw ChatFixtureError.noBinding }
    try await world.settle()

    let hereReply = try await ChatCardsTurns.record(here, in: world.stores[0])
    let thereReply = try await ChatCardsTurns.record(there, in: world.stores[1])
    let hereProposal = try #require(hereReply.appliedProposal)
    #expect(try await world.writer(0).undo(hereProposal, index: 0, idea: nil, accepting: [], novel: world.novel))
    try await world.settle()
    #expect(try await !entityExists("mara", on: world.stores[1], novel: world.novel))

    let receipt = ChatReceiptModel(proposal: try #require(thereReply.appliedProposal), reply: thereReply, context: world.context(1), writer: world.writer(1))
    let task = observing { await receipt.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the receipt loads") { receipt.changes.count == 1 }
    let change = try #require(receipt.changes.first)
    await receipt.toggle(change)

    let notice = try #require(receipt.notices[0])
    #expect(notice.error == ChatCardsErrors.twinRemoved(ChatCardRefusal(code: "RFN_006")))
    #expect(notice.recovery == .redoTwin(proposal: hereProposal, index: 0))
    #expect(receipt.state(of: change) == .applied)

    await receipt.recover(0)

    #expect(receipt.notices.isEmpty)
    #expect(try await entityExists("mara", on: world.stores[1], novel: world.novel))
    try await world.settle()
    #expect(try await entityExists("mara", on: world.stores[0], novel: world.novel))
  }

  @Test func shouldRereadACardWhenAnotherDeviceDecidesIt() async throws {
    let places = Script.reply("A place.", ops: [Script.idea("hall", "Saltgate Hall")])
    let world = try await ChatCardsReplicas.make([[places], []], mode: .manual)
    let reply = try await ChatCardsTurns.reply(to: "Add a place.", engine: world.engines[0], store: world.stores[0], session: world.session, novel: world.novel)
    let proposal = try #require(reply.cardProposal)
    try await world.settle()
    let here = ChatProposalCardModel(proposal: proposal, context: world.context(0), writer: world.writer(0))
    let task = observing { await here.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the card loads") { here.status == .pending }

    _ = try await world.writer(1).apply(proposal, indexes: [0], novel: world.novel)
    try await world.settle()

    try await ChatWait.until("the synced decision shows") { here.status == .applied }
    #expect(here.snapshot?.state(of: 0) == .applied)
    #expect(!here.canApply && !here.canDiscard && here.canRevert)
  }
}
