import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import NovelForgeCore

enum ChatReplicaOperation: String, CaseIterable, Sendable {
  case turn = "send a turn"
  case failingTurn = "send a turn the model fails"
  case overtakenTurn = "send a turn that deliveries overtake"
  case answer = "answer a waiting message"
  case retry = "retry a failed turn"
  case apply = "apply a card"
  case discard = "discard a card"
  case undo = "undo a change"
  case redo = "redo a change"
  case revert = "revert a card"
  case compact = "compact the chat"
  case rename = "rename the chat"
  case archive = "archive or unarchive the chat"

  var weight: Int {
    switch self {
    case .turn: 12
    case .revert, .compact, .rename, .archive: 2
    case .failingTurn, .answer, .retry, .redo, .discard: 3
    case .overtakenTurn: 4
    case .undo: 5
    case .apply: 7
    }
  }

  /// The operations a second device may run at the same time on the same target, repeats weighing a pick.
  var partners: [ChatReplicaOperation] {
    switch self {
    case .turn, .failingTurn, .overtakenTurn, .compact: [self, .turn, .failingTurn, .overtakenTurn, .compact]
    case .answer, .retry: [.answer, .retry]
    case .apply: [.apply, .apply, .apply, .discard]
    case .discard: [.apply, .discard]
    case .undo, .redo, .revert: [self, .undo, .redo, .revert]
    case .rename, .archive: [.rename, .archive]
    }
  }

  var decidesCards: Bool { [.apply, .discard, .undo, .redo, .revert].contains(self) }

  static func pick(_ generator: inout SeededGenerator) -> ChatReplicaOperation {
    var remaining = generator.int(in: 0...(allCases.map(\.weight).reduce(0, +) - 1))
    for operation in allCases {
      if remaining < operation.weight { return operation }
      remaining -= operation.weight
    }
    return .turn
  }
}

final class ChatReachTally: Sendable {
  private let runs = Mutex<[ChatConvergence.Reach]>([])

  func record(_ reach: ChatConvergence.Reach) {
    runs.withLock { $0.append(reach) }
  }

  var snapshot: [ChatConvergence.Reach] { runs.withLock { $0 } }
}

/// Phase 6 done-when: two or three replicas run random chat operations on one session through the engine and the store, each device with its own scripted
/// model, while deliveries arrive partially, out of order, again and in the middle of a turn. Each block of `block` steps opens with `partition` steps
/// without deliveries, in which a second device, one holding the card when it can, decides the same card or often works on the same message; its apply
/// takes the indexes the first left out. Half the runs never go unrestricted. After full delivery every replica keeps `ChatConvergence`'s invariants.
/// `NOVELFORGE_CHAT_REPLICA_REPLAY=<seed>` replays one failure.
struct ChatReplicaProperty: Sendable {
  static let replaySeed = ProcessInfo.processInfo.environment["NOVELFORGE_CHAT_REPLICA_REPLAY"].flatMap(parseSeed)

  var iterations = 6
  var steps = 44
  var block = 12
  var partition = 6
  var checkRate = 0.08
  let tally = DomainTally()
  let reach = ChatReachTally()

  func check(order: CausalReplicaOrder, seed: UInt64) async throws {
    if let replaySeed = Self.replaySeed {
      try await replay(seed: replaySeed) { generator in try await run(order: order, &generator) }
      return
    }
    try await forAllConcurrently(iterations: ProjectionProperty.gatedIterations(iterations), seed: seed) { generator in try await run(order: order, &generator) }
  }

  private func run(order: CausalReplicaOrder, _ generator: inout SeededGenerator) async throws {
    let count = generator.int(in: 2...3)
    let (reconciler, replicas, devices) = try await ChatReplicaWorld.devices(count: count, order: order, seed: generator.next())
    var ledger = ChatReplicaLedger(devices: count)
    let context = Run(reconciler: reconciler, replicas: replicas, unrestricted: generator.chance(0.5) ? 0 : 0.08)
    for step in 0..<steps {
      guard step % block < partition || generator.chance(0.55) else {
        _ = try await replicas.step(using: &generator)
        continue
      }
      let (operation, first) = (ChatReplicaOperation.pick(&generator), devices[generator.int(in: 0...(count - 1))])
      (ledger.target, ledger.targetSelection) = (nil, nil)
      try await perform(operation, on: first, context, &ledger, &generator)
      guard step % block < partition, operation.decidesCards || generator.chance(0.6) else { continue }
      let others = devices.filter { $0.index != first.index }
      var holding = [ChatDevice]()
      for device in others {
        if let target = ledger.target, try await device.holds(target) { holding.append(device) }
      }
      try await perform(generator.pick(from: operation.partners), on: generator.pick(from: holding.isEmpty ? others : holding), context, &ledger, &generator)
    }
    let before = try await ChatConvergence.decisions(on: devices)
    try await replicas.settle()
    reach.record(try await ChatConvergence.check(reconciler, devices: devices, ledger: ledger, before: before))
  }

  private struct Run: Sendable {
    let reconciler: NovelForgeReconciler
    let replicas: CausalReplicas
    /// The chance that a turn of this run is unrestricted.
    let unrestricted: Double
  }

  /// Runs the operation on the device, then hands what it wrote to the delivery streams; now and then compares the device with a rebuild.
  private func perform(_ operation: ChatReplicaOperation, on device: ChatDevice, _ run: Run, _ ledger: inout ChatReplicaLedger, _ generator: inout SeededGenerator)
    async throws
  {
    await run.replicas.advanceClock(of: device.index, by: generator.chance(0.2) ? .seconds(700) : .milliseconds(generator.int(in: 0...50)))
    do {
      defer { device.model.clear() }
      tally.record(operation.rawValue, refusal: try await body(operation, on: device, run, &ledger, &generator))
    } catch let failure as ChatReplicaFailure {
      throw failure
    } catch {
      guard let code = ChatReplicaRefusal.code(of: error) else { throw ChatReplicaFailure.unexpected(operation.rawValue, error) }
      tally.record(operation.rawValue, refusal: code)
    }
    _ = try await run.replicas.write(device.index) { _ in }
    if generator.chance(checkRate) { try await ChatConvergence.expectRebuilt(run.reconciler, device: device) }
  }

  /// Runs the operation; returns why it did nothing, or nil when it did.
  private func body(_ operation: ChatReplicaOperation, on device: ChatDevice, _ run: Run, _ ledger: inout ChatReplicaLedger, _ generator: inout SeededGenerator)
    async throws -> String?
  {
    let (store, session, novel) = (device.store, ChatReplicaWorld.session, ChatReplicaWorld.novel)
    switch operation {
    case .turn, .failingTurn, .overtakenTurn:
      let script = ChatTurnScript.make(device: device.index, serial: ledger.nextSerial(device.index), removable: ledger.created, unrestricted: run.unrestricted, &generator)
      device.model.queue(operation == .failingTurn ? [.failure(.authentication)] : script.reply)
      let gate = operation == .overtakenTurn ? device.model.holdNextTurn() : nil
      defer { gate?.release() }
      let handle = try await device.engine.send(script.message, session: session, novel: novel, choices: script.choices)
      ledger.wrote(handle.userMessage, on: device.index, unrestricted: script.choices.contentMode == .unrestricted)
      if let gate {
        guard await gate.reached(by: handle) else { throw ChatReplicaFailure.invariant("a held turn ended before asking its model") }
        try await overtake(device, run.replicas, &generator)
        gate.release()
      }
      try await finish(operation, handle, script: script, answering: handle.userMessage, on: device, &ledger)
    case .answer:
      let elsewhere = ledger.waiting.filter { $0.device != device.index }
      guard let waiting = ledger.waitingTarget(elsewhere.isEmpty || generator.chance(0.2) ? ledger.waiting : elsewhere, &generator) else { return "nothing waiting" }
      let script = ChatTurnScript.make(device: device.index, serial: ledger.nextSerial(device.index), removable: ledger.created, unrestricted: run.unrestricted, &generator)
      device.model.queue(script.reply)
      let handle = try await device.engine.answer(message: waiting.message, session: session, novel: novel)
      try await finish(operation, handle, script: script, answering: waiting.message, on: device, &ledger)
    case .retry:
      guard let waiting = ledger.waitingTarget(ledger.waiting.filter { $0.device == device.index && !ledger.retried.contains($0.turn) }, &generator) else {
        return "nothing to retry"
      }
      let script = ChatTurnScript.make(device: device.index, serial: ledger.nextSerial(device.index), removable: ledger.created, unrestricted: run.unrestricted, &generator)
      device.model.queue(script.reply)
      let handle = try await device.engine.retry(turn: waiting.turn)
      try await finish(operation, handle, script: script, answering: waiting.message, on: device, &ledger)
      ledger.retried.insert(waiting.turn)
    case .apply:
      guard let (id, count) = try await card(ledger.cards, on: device, &ledger, &generator) else { return "no card" }
      let indexes = Set(0..<count)
      let chosen: Set<Int>
      if let first = ledger.targetSelection {
        chosen = first == indexes ? indexes : indexes.subtracting(first)
      } else {
        let some = indexes.filter { _ in generator.chance(0.5) }
        chosen = some.isEmpty || !generator.chance(0.7) ? indexes : some
      }
      ledger.targetSelection = chosen
      let selection: ApplySelection = chosen == indexes ? .whole : .indexes(chosen.sorted())
      guard case .applied = try await store.applyProposal(id, selection: selection, context: ChatReplicaWorld.applyContext) else { return "conflicted" }
      ledger.applied(id, on: device.index, selecting: chosen)
    case .discard:
      guard let (id, _) = try await card(ledger.cards, on: device, &ledger, &generator) else { return "no card" }
      try await store.discardProposal(id, novel: novel)
    case .undo, .redo:
      guard let (id, count) = try await card(ledger.applied, on: device, &ledger, &generator) else { return "no card" }
      let index = generator.int(in: 0...max(count - 1, 0))
      let toggle =
        operation == .undo
        ? try await store.undoProposalChange(id, index: index, context: ChatReplicaWorld.revertContext)
        : try await store.redoProposalChange(id, index: index, context: ChatReplicaWorld.revertContext)
      return toggle.changed ? nil : "already so"
    case .revert:
      guard let (id, _) = try await card(ledger.applied, on: device, &ledger, &generator) else { return "no card" }
      _ = try await store.revertProposal(id, context: ChatReplicaWorld.revertContext)
    case .compact:
      do {
        switch try await ChatCompaction.compactIfNeeded(session: session, turn: CompactionWorld.turn(), store: store, router: device.router).outcome {
        case .kept: return "kept"
        case .refused: return "refused"
        case .folded: return nil
        }
      } catch {
        throw ChatReplicaFailure.unexpected(operation.rawValue, error)
      }
    case .rename:
      let title = generator.chance(0.2) ? nil : "Chat \(device.index)-\(generator.int(in: 0...99))"
      try await sessionCall(operation) { () async throws(ChatSessionError) in try await store.renameChatSession(session, novel: novel, title: title) }
    case .archive:
      let archives = generator.chance(0.25)
      try await sessionCall(operation) { () async throws(ChatSessionError) in
        if archives { try await store.archiveChatSession(session, novel: novel) } else { try await store.unarchiveChatSession(session, novel: novel) }
      }
    }
    return nil
  }

  private func finish(
    _ operation: ChatReplicaOperation, _ handle: ChatTurnHandle, script: ChatTurnScript, answering message: UUID, on device: ChatDevice,
    _ ledger: inout ChatReplicaLedger
  ) async throws {
    switch await handle.outcome() {
    case .answered(let reply):
      ledger.staged(script)
      try await ledger.record(reply: reply, answering: message, on: device.index, in: device.store)
    case .failed(let failure):
      guard operation == .failingTurn else { throw ChatReplicaFailure.turnFailed(operation.rawValue, failure) }
      ledger.waiting.append(ChatReplicaLedger.Waiting(device: device.index, turn: handle.turn, message: handle.userMessage))
    case .cancelled, .interrupted:
      throw ChatReplicaFailure.invariant("\(operation.rawValue) stopped without being asked to")
    }
  }

  /// Deliveries that reach the device, and others, while its turn waits on the model.
  private func overtake(_ device: ChatDevice, _ replicas: CausalReplicas, _ generator: inout SeededGenerator) async throws {
    for writer in 0..<replicas.count where writer != device.index && generator.chance(0.7) {
      try await replicas.deliver(from: writer, to: device.index, atMost: generator.int(in: 1...6), batch: generator.int(in: 1...3))
    }
    if generator.chance(0.5) { _ = try await replicas.step(using: &generator) }
  }

  /// The card the step works on, else one of `proposals`, and how many changes this device reads in it; one that has not reached this device counts three.
  private func card(_ proposals: [UUID], on device: ChatDevice, _ ledger: inout ChatReplicaLedger, _ generator: inout SeededGenerator) async throws
    -> (UUID, Int)?
  {
    guard let id = ledger.cardTarget(proposals, &generator) else { return nil }
    let count = try await device.store.read { transaction in try ProposalRecord.read(id: id, in: transaction).entry?.record.card.changeSet.count }
    return (id, count ?? 3)
  }

  private func sessionCall(_ operation: ChatReplicaOperation, _ body: () async throws(ChatSessionError) -> Void) async throws {
    do {
      try await body()
    } catch {
      throw ChatReplicaFailure.unexpected(operation.rawValue, error)
    }
  }

  private static func parseSeed(_ text: String) -> UInt64? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    return trimmed.hasPrefix("0x") ? UInt64(trimmed.dropFirst(2), radix: 16) : UInt64(trimmed)
  }
}
