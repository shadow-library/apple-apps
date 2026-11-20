import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias World = ChatReplicaWorld

/// One chat on several devices, with what each did kept for `ChatConvergence`.
private final class Chat {
  let reconciler: NovelForgeReconciler
  let replicas: CausalReplicas
  let devices: [ChatDevice]
  var ledger: ChatReplicaLedger

  init(devices count: Int, seed: UInt64) async throws {
    (reconciler, replicas, devices) = try await World.devices(count: count, seed: seed)
    ledger = ChatReplicaLedger(devices: count)
  }

  /// Sends `name`'s message on `device`; the model answers with `ops`, or fails when `ops` is nil. Returns the turn.
  @discardableResult
  func send(_ name: String, ops: [String]?, on device: Int, creates: [String] = [], choices: ChatTurnChoices = ChatTurnChoices()) async throws -> ChatTurnHandle {
    let script = Self.script(name, ops: ops ?? [], creates: creates, choices: choices)
    devices[device].model.queue(ops == nil ? [.failure(.authentication)] : script.reply)
    let handle = try await devices[device].engine.send(script.message, session: World.session, novel: World.novel, choices: choices)
    ledger.wrote(handle.userMessage, on: device, unrestricted: choices.contentMode == .unrestricted)
    try await finish(handle, script: script, answering: handle.userMessage, on: device, fails: ops == nil)
    return handle
  }

  func finish(_ handle: ChatTurnHandle, script: ChatTurnScript, answering message: UUID, on device: Int, fails: Bool = false) async throws {
    defer { devices[device].model.clear() }
    switch await handle.outcome() {
    case .answered(let reply) where !fails:
      ledger.staged(script)
      try await ledger.record(reply: reply, answering: message, on: device, in: devices[device].store)
    case .failed where fails:
      ledger.waiting.append(ChatReplicaLedger.Waiting(device: device, turn: handle.turn, message: handle.userMessage))
    case let outcome:
      throw ChatReplicaFailure.invariant("the turn on device \(device) ended \(outcome)")
    }
    _ = try await replicas.write(device) { _ in }
  }

  static func script(_ name: String, ops: [String], creates: [String] = [], choices: ChatTurnChoices = ChatTurnChoices()) -> ChatTurnScript {
    let text = EngineWorld.text("Noted \(name).")
    let reply = ops.isEmpty ? EngineWorld.reply(("reply", text)) : EngineWorld.reply(("reply", text), ("changeSet", "[\(ops.joined(separator: ","))]"))
    return ChatTurnScript(message: "\(name) is a smuggler who works the Saltgate docks.", reply: reply, creates: creates, removes: [], choices: choices)
  }

  func store(_ device: Int) -> VaultStore { devices[device].store }

  func reply(_ handle: ChatTurnHandle, on device: Int) async throws -> ChatMessageRecord {
    try await store(device).read { transaction in try #require(try ChatMessageRecord.read(id: handle.turn, in: transaction).entry?.record) }
  }

  func flush(_ device: Int) async throws {
    _ = try await replicas.write(device) { _ in }
  }

  func proposal(_ id: UUID, on device: Int) async throws -> ProposalRecord? {
    try await store(device).read { transaction in try ProposalRecord.read(id: id, in: transaction).entry?.record }
  }

  func change(_ id: UUID, _ index: Int, on device: Int) async throws -> ProposalChangeRecord? {
    try await store(device).read { transaction in
      guard let proposal = try ProposalRecord.read(id: id, in: transaction).entry?.record,
        case .recorded(let change) = try ProposalChangeRecord.changes(of: proposal, in: transaction)[index]
      else { return nil }
      return change
    }
  }

  func entity(_ key: String, on device: Int) async throws -> ArtifactState? {
    try await store(device).read { transaction in try ArtifactStateLoader.states(refs: ["entity:\(key)"], novel: World.novel, in: transaction)[JSString("entity:\(key)")] }
  }

  func window(on device: Int) async throws -> ChatConversationWindow {
    try await CompactionWorld.window(World.session, in: store(device))
  }

  /// Delivers everything and checks every replica against the others and the ledger.
  @discardableResult
  func converge() async throws -> ChatConvergence.Reach {
    let before = try await ChatConvergence.decisions(on: devices)
    try await replicas.settle()
    return try await ChatConvergence.check(reconciler, devices: devices, ledger: ledger, before: before)
  }
}

private func names(_ device: Int, _ serial: Int) -> (key: String, name: String) {
  ChatTurnScript.key(device: device, serial: serial)
}

@Suite("Chat replica interleavings", TestTimeLimit.property)
struct ChatReplicaInterleavingTests {
  @Test func shouldStandAppliedEverywhereWhenOneDeviceAppliesACardAnotherDiscards() async throws {
    let chat = try await Chat(devices: 3, seed: 0xF26_A1)
    let (key, name) = names(0, 0)
    let turn = try await chat.send(name, ops: [ChatTurnScript.quoted(key, name)], on: 0, creates: [key], choices: ChatTurnChoices(justDiscussing: true))
    let card = try #require(try await chat.reply(turn, on: 0).cardProposal)
    try await chat.replicas.settle()

    guard case .applied = try await chat.store(1).applyProposal(card, selection: .whole, context: World.applyContext) else {
      Issue.record("the card did not apply")
      return
    }
    chat.ledger.applied(card, on: 1, selecting: [0])
    try await chat.flush(1)
    try await chat.store(2).discardProposal(card, novel: World.novel)
    try await chat.flush(2)
    #expect(try await chat.proposal(card, on: 2)?.decision == .known(.discarded))
    #expect(try await chat.entity(key, on: 2)?.exists == false)

    let reach = try await chat.converge()
    #expect(reach.raisedByMerge == 1)
    for device in 0..<3 {
      #expect(try await chat.proposal(card, on: device)?.decision == .known(.applied))
      #expect(try await chat.entity(key, on: device)?.exists == true)
      #expect(try await chat.store(device).load(ChatPendingProposals.self, World.novel).count == .available(0))
    }
  }

  @Test(arguments: [0, 1])
  func shouldAgreeOnTheLaterToggleWhenOneDeviceUndoesAChangeAnotherRedoes(later: Int) async throws {
    let chat = try await Chat(devices: 2, seed: 0xF26_A2 + UInt64(later))
    let (key, name) = names(0, 0)
    let turn = try await chat.send(name, ops: [ChatTurnScript.quoted(key, name)], on: 0, creates: [key])
    let applied = try #require(try await chat.reply(turn, on: 0).appliedProposal)
    try await chat.replicas.settle()
    let created = try #require(try await chat.entity(key, on: 1))

    if later == 1 { await chat.replicas.advanceClock(of: 1, by: .seconds(60)) }
    #expect(try await chat.store(1).undoProposalChange(applied, index: 0, context: World.revertContext).changed)
    #expect(try await chat.store(1).redoProposalChange(applied, index: 0, context: World.revertContext).changed)
    try await chat.flush(1)
    if later == 0 { await chat.replicas.advanceClock(of: 0, by: .seconds(120)) }
    #expect(try await chat.store(0).undoProposalChange(applied, index: 0, context: World.revertContext).changed)
    try await chat.flush(0)

    try await chat.converge()
    for device in 0..<2 {
      let change = try #require(try await chat.change(applied, 0, on: device))
      #expect(change.status == .known(later == 0 ? .reverted : .applied))
      let entity = try #require(try await chat.entity(key, on: device))
      #expect(entity.exists == (later == 1))
      if later == 1 { #expect(entity.contentHash == created.contentHash) }
    }
  }

  @Test func shouldStandOnOneOfTwoConcurrentFoldsAndBuildTheNextOnIt() async throws {
    let chat = try await Chat(devices: 2, seed: 0xF26_A3)
    for serial in 0..<7 {
      let (key, name) = names(serial % 2, serial)
      try await chat.send(name, ops: [ChatTurnScript.quoted(key, name)], on: serial % 2, creates: [key])
      try await chat.replicas.settle()
    }
    let shared = try await chat.window(on: 0).messages.map(\.record.id)
    #expect(shared.count == 14)

    try await chat.send(names(0, 7).name, ops: [], on: 0)
    try await chat.send(names(1, 8).name, ops: [], on: 1)
    let folds = [try await chat.window(on: 0).summary?.record, try await chat.window(on: 1).summary?.record]
    #expect(folds.map { $0?.covered } == [Array(shared.prefix(8)), Array(shared.prefix(8))])

    try await chat.converge()
    let standing = try #require(try await chat.window(on: 0).summary?.record)
    #expect(folds.contains { $0?.id == standing.id })
    #expect(try await chat.window(on: 0).messages.count == 10)

    for serial in 9..<12 {
      let (key, name) = names(1, serial)
      try await chat.send(name, ops: [ChatTurnScript.quoted(key, name)], on: 1, creates: [key])
    }
    try await chat.converge()
    let next = try #require(try await chat.window(on: 0).summary?.record)
    #expect(next.id != standing.id && Set(next.covered).isSuperset(of: standing.covered))
    #expect(Array(next.covered.prefix(standing.covered.count)) == standing.covered)
  }

  // Orchestrator decision 6: both replies stand
  @Test func shouldKeepBothRepliesAndOneEntityWhenTwoDevicesAnswerOneMessage() async throws {
    let chat = try await Chat(devices: 2, seed: 0xF26_A4)
    let (key, name) = names(0, 0)
    let failed = try await chat.send(name, ops: nil, on: 0)
    try await chat.replicas.settle()
    #expect(try await chat.devices[1].engine.activity(session: World.session) == .answeringElsewhere(message: failed.userMessage))

    let script = Chat.script(name, ops: [ChatTurnScript.quoted(key, name)], creates: [key])
    chat.devices[1].model.queue(script.reply)
    let answer = try await chat.devices[1].engine.answer(message: failed.userMessage, session: World.session, novel: World.novel)
    try await chat.finish(answer, script: script, answering: failed.userMessage, on: 1)
    chat.devices[0].model.queue(script.reply)
    let retried = try await chat.devices[0].engine.retry(turn: failed.turn)
    try await chat.finish(retried, script: script, answering: failed.userMessage, on: 0)
    #expect(retried.turn == failed.turn)

    let reach = try await chat.converge()
    #expect(reach.repliesToOneMessage == 1)
    let replies = [try await chat.reply(answer, on: 0), try await chat.reply(retried, on: 1)]
    #expect(replies.map(\.answers) == [failed.userMessage, failed.userMessage])
    let applied = try replies.map { try #require($0.appliedProposal) }
    for device in 0..<2 {
      #expect(try await chat.entity(key, on: device)?.exists == true)
      for proposal in applied { #expect(try await chat.change(proposal, 0, on: device)?.status == .known(.applied)) }
      #expect(try await chat.devices[device].engine.activity(session: World.session) == .idle)
    }

    // An undo is guarded by its own change's post-state only, as for two applies of one ref on one device: undoing one twin removes the entity the other
    // still records as applied, and that one can no longer be undone
    #expect(try await chat.store(0).undoProposalChange(applied[0], index: 0, context: World.revertContext).changed)
    try await chat.flush(0)
    try await chat.replicas.settle()
    await #expect {
      _ = try await chat.store(1).undoProposalChange(applied[1], index: 0, context: World.revertContext)
    } throws: { error in
      guard case .conflicted = error as? ProposalRevertError else { return false }
      return true
    }
    try await chat.converge()
    for device in 0..<2 {
      #expect(try await chat.entity(key, on: device)?.exists == false)
      #expect(try await chat.change(applied[0], 0, on: device)?.status == .known(.reverted))
      #expect(try await chat.change(applied[1], 0, on: device)?.status == .known(.applied))
    }

    #expect(try await chat.store(1).redoProposalChange(applied[0], index: 0, context: World.revertContext).changed)
    try await chat.flush(1)
    try await chat.converge()
    for device in 0..<2 {
      #expect(try await chat.entity(key, on: device)?.exists == true)
      for proposal in applied { #expect(try await chat.change(proposal, 0, on: device)?.status == .known(.applied)) }
    }
  }

  @Test func shouldLockEveryDeviceOnAnUnrestrictedAuthorMessageWhoseTurnFailed() async throws {
    let chat = try await Chat(devices: 3, seed: 0xF26_A8)
    let failed = try await chat.send(names(0, 0).name, ops: nil, on: 0, choices: ChatTurnChoices(contentMode: .unrestricted))
    #expect(chat.ledger.replies.isEmpty && chat.ledger.unrestricted)
    try await chat.converge()
    for device in 0..<3 {
      let lock = try await chat.store(device).read { transaction in try ChatWindow.load(World.session, in: transaction).lock }
      #expect(lock.value??.item == NovelForgeKey.chatMessage(failed.userMessage))
    }
  }

  @Test func shouldAnswerATurnThatAFoldAndAnArchiveOvertookAndRefuseTheNext() async throws {
    let chat = try await Chat(devices: 2, seed: 0xF26_A5)
    for serial in 0..<6 {
      let (key, name) = names(1, serial)
      try await chat.send(name, ops: [ChatTurnScript.quoted(key, name)], on: 1, creates: [key])
    }
    try await chat.replicas.settle()
    let (key, name) = names(0, 6)
    let script = Chat.script(name, ops: [ChatTurnScript.quoted(key, name)], creates: [key])
    chat.devices[0].model.queue(script.reply)
    let gate = chat.devices[0].model.holdNextTurn()
    defer { gate.release() }
    let turn = try await chat.devices[0].engine.send(script.message, session: World.session, novel: World.novel)
    chat.ledger.wrote(turn.userMessage, on: 0, unrestricted: false)
    #expect(await gate.reached(by: turn))
    try await chat.flush(0)

    try await chat.send(names(1, 7).name, ops: [], on: 1)
    let fold = try await ChatCompaction.compactIfNeeded(session: World.session, turn: CompactionWorld.turn(), store: chat.store(1), router: chat.devices[1].router)
    guard case .folded = fold.outcome else {
      Issue.record("device 1 did not fold: \(fold.outcome)")
      return
    }
    try await chat.store(1).archiveChatSession(World.session, novel: World.novel)
    try await chat.flush(1)
    try await chat.replicas.deliver(from: 1, to: 0)
    #expect(try await chat.window(on: 0).summary != nil)

    gate.release()
    try await chat.finish(turn, script: script, answering: turn.userMessage, on: 0)
    try await chat.converge()
    #expect(try await chat.entity(key, on: 1)?.exists == true)
    await #expect {
      _ = try await chat.devices[0].engine.send("One more.", session: World.session, novel: World.novel)
    } throws: { error in
      (error as? ChatTurnError)?.code == ChatTurnError.sessionArchived.code
    }
  }

  @Test func shouldStandAppliedWhenACardIsSupersededOnOneDeviceAndAppliedOnAnother() async throws {
    let chat = try await Chat(devices: 2, seed: 0xF26_A7)
    let discussing = ChatTurnChoices(justDiscussing: true)
    let first = try await chat.send(names(0, 0).name, ops: [ChatTurnScript.maraEdit("brass")], on: 0, choices: discussing)
    let older = try #require(try await chat.reply(first, on: 0).cardProposal)
    try await chat.replicas.settle()

    let second = try await chat.send(names(0, 1).name, ops: [ChatTurnScript.maraEdit("copper")], on: 0, choices: discussing)
    let newer = try #require(try await chat.reply(second, on: 0).cardProposal)
    #expect(try await chat.proposal(older, on: 0)?.decision == .known(.superseded))
    #expect(try await chat.proposal(newer, on: 0)?.card.supersedes == [older])
    guard case .applied = try await chat.store(1).applyProposal(older, selection: .whole, context: World.applyContext) else {
      Issue.record("the older card did not apply")
      return
    }
    chat.ledger.applied(older, on: 1, selecting: [0])
    try await chat.flush(1)

    let reach = try await chat.converge()
    #expect(reach.raisedByMerge == 1)
    for device in 0..<2 {
      #expect(try await chat.proposal(older, on: device)?.decision == .known(.applied))
      #expect(try await chat.proposal(newer, on: device)?.decision == .known(.pending))
    }
    guard case .conflicted = try await chat.store(0).applyProposal(newer, selection: .whole, context: World.applyContext) else {
      Issue.record("the superseding card applied over the change the superseded one made")
      return
    }
  }
}
