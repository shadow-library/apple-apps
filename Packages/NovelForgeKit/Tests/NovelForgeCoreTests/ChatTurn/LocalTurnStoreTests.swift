import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private enum Abort: Error {
  case crash
}

@Suite("Local turn store", TestTimeLimit.standard)
struct LocalTurnStoreTests {
  private static let novel = UUID()
  private static let session = UUID()
  private static let start = Date(timeIntervalSince1970: 1_800_000_000)

  private static func begin(_ store: VaultStore, turn: UUID = UUID(), session: UUID = session, message: UUID = UUID(), at offset: TimeInterval = 0) async throws -> (
    turn: UUID, message: UUID
  ) {
    let replica = store.replica
    try await store.write { transaction in
      try LocalTurnStore.begin(turn, novel: novel, session: session, userMessage: message, replica: replica, at: start + offset, in: transaction.database)
    }
    return (turn, message)
  }

  private static func frames(_ events: [TurnStreamEvent], after sequence: Int = 0) -> [TurnFrame] {
    var log = TurnEventLog(after: sequence)
    log.record(events)
    return log.takeFrames()
  }

  private static let checkpoint = LocalTurnCheckpoint(
    round: 2, messages: [PromptMessage(.assistant, #"{"reply":"r","lookups":[{"tool":"get_brief"}]}"#), PromptMessage(.user, "Lookup results:\n### get_brief\n…")],
    carry: ["counts": ["get_brief": 1], "planner": false])

  @Test func shouldReadNothingBeforeAnyTurnWasStored() async throws {
    let store = try NovelForgeStore.openInMemory()
    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: nil) == .idle)
    #expect(try await store.pendingLocalTurns().isEmpty)
    #expect(try await store.localTurnFrames(UUID()).isEmpty)
    #expect(try await store.saveLocalTurnRound(Self.checkpoint, turn: UUID()) == false)
    #expect(try await store.endLocalTurn(UUID(), as: .cancelled) == false)
    try await store.clearLocalTurn(UUID())
  }

  @Test func shouldKeepARunningTurnWithItsFramesAndSavedRoundOnThisDeviceOnly() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, message) = try await Self.begin(store)
    let frames = Self.frames([.user(message: message), .delta("Hel"), .delta("lo"), .reset])
    #expect(try await store.appendLocalTurnFrames(frames, turn: turn, at: Self.start + 1))
    #expect(try await store.saveLocalTurnRound(Self.checkpoint, turn: turn, at: Self.start + 2))

    let status = try await store.localTurnStatus(session: Self.session, lastMessage: message)
    let pending = try #require(status.pending)
    #expect(status.ended == nil)
    #expect(pending.id == turn && pending.novel == Self.novel && pending.session == Self.session && pending.userMessage == message)
    #expect(pending.replica == store.replica && pending.state == .pending && pending.failure == nil && pending.endedAt == nil)
    #expect(pending.startedAt == Self.start && pending.updatedAt == Self.start + 2)
    #expect(pending.lastSequence == 3 && pending.savedRounds == 2 && pending.checkpoint == Self.checkpoint)
    #expect(try await store.localTurnFrames(turn) == frames)
    #expect(try await store.localTurnFrames(turn, after: 1).map(\.sequence) == [2, 3])
    #expect(try await store.pendingChanges(limit: 100).isEmpty)
  }

  @Test func shouldKeepTheFirstFrameStoredUnderASequenceAndDropFramesOfATurnNoLongerStored() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, _) = try await Self.begin(store)
    let frames = Self.frames([.delta("a"), .reset])
    #expect(try await store.appendLocalTurnFrames(frames, turn: turn))
    #expect(try await store.appendLocalTurnFrames(frames, turn: turn))
    #expect(try await store.appendLocalTurnFrames(Self.frames([.delta("rewritten")]), turn: turn))
    #expect(try await store.localTurnFrames(turn) == frames)
    #expect(try await store.appendLocalTurnFrames(frames, turn: UUID()) == false)
    try await store.clearLocalTurn(turn)
    #expect(try await store.appendLocalTurnFrames(frames, turn: turn) == false)
    #expect(try await store.localTurnFrames(turn).isEmpty)
  }

  @Test func shouldShowAnEndedTurnOnlyWhileTheTranscriptEndsOnItsMessageAndNothingRuns() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, message) = try await Self.begin(store)
    let failure = TurnFailure(code: "AI_001", message: "The model's answer could not be read")
    #expect(try await store.saveLocalTurnRound(Self.checkpoint, turn: turn, at: Self.start + 4))
    #expect(try await store.endLocalTurn(turn, as: .failed(failure), frames: Self.frames([.delta("Half"), .error(failure)]), at: Self.start + 5))
    #expect(try await store.endLocalTurn(turn, as: .cancelled, at: Self.start + 9) == false)
    #expect(try await store.saveLocalTurnRound(Self.checkpoint, turn: turn) == false)
    #expect(try await store.appendLocalTurnFrames(Self.frames([.delta("late")], after: 2), turn: turn) == false)

    let ended = try #require(try await store.localTurnStatus(session: Self.session, lastMessage: message).ended)
    #expect(ended.state == .failed && ended.failure == failure && ended.endedAt == Self.start + 5 && ended.lastSequence == 2)
    #expect(ended.savedRounds == 0 && ended.checkpoint == nil)
    #expect(try await store.localTurnFrames(turn).last?.decoded == .error(failure))
    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: UUID()) == .idle)
    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: nil) == .idle)
    #expect(try await store.pendingLocalTurns().isEmpty)

    let (other, _) = try await Self.begin(store, session: UUID(), at: 1)
    let running = try await Self.begin(store, at: 2)
    let status = try await store.localTurnStatus(session: Self.session, lastMessage: message)
    #expect(status.pending?.id == running.turn && status.ended == nil)
    #expect(try await store.localTurn(turn) == nil)
    #expect(try await store.localTurnFrames(turn).isEmpty)
    #expect(try await store.localTurn(other) != nil)
  }

  @Test func shouldRecordACancelledTurnWithoutAFailure() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, message) = try await Self.begin(store)
    #expect(try await store.endLocalTurn(turn, as: .cancelled, at: Self.start + 3))
    let ended = try #require(try await store.localTurnStatus(session: Self.session, lastMessage: message).ended)
    #expect(ended.state == .cancelled && ended.failure == nil && ended.checkpoint == nil)
  }

  @Test func shouldShowTheLatestOfSeveralRunningTurns() async throws {
    let store = try NovelForgeStore.openInMemory()
    let first = try await Self.begin(store, at: 0)
    let second = try await Self.begin(store, at: 10)
    #expect(try await store.endLocalTurn(first.turn, as: .cancelled))
    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: first.message).pending?.id == second.turn)
    #expect(try await store.pendingLocalTurns().map(\.id) == [second.turn])
  }

  @Test func shouldRemoveTheTurnInTheTransactionThatAppendsTheReplyAndNotWhenThatTransactionFails() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, _) = try await Self.begin(store)
    #expect(try await store.appendLocalTurnFrames(Self.frames([.delta("a")]), turn: turn))
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        try LocalTurnStore.finish(turn, in: transaction.database)
        throw Abort.crash
      }
    }
    #expect(try await store.localTurn(turn) != nil)
    #expect(try await store.localTurnFrames(turn).count == 1)
    try await store.write { transaction in try LocalTurnStore.finish(turn, in: transaction.database) }
    #expect(try await store.localTurn(turn) == nil)
    #expect(try await store.localTurnFrames(turn).isEmpty)
  }

  @Test func shouldLeaveNoTurnWhenTheMessagesTransactionFails() async throws {
    let store = try NovelForgeStore.openInMemory()
    let replica = store.replica
    let turn = UUID()
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        try LocalTurnStore.begin(turn, novel: Self.novel, session: Self.session, userMessage: UUID(), replica: replica, at: Self.start, in: transaction.database)
        throw Abort.crash
      }
    }
    #expect(try await store.localTurn(turn) == nil)
    _ = try await Self.begin(store, turn: turn)
    await #expect(throws: StoreError.self) { _ = try await Self.begin(store, turn: turn) }
  }

  @Test func shouldFindAnInterruptedTurnAfterTheAppRestarts() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LocalTurnStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "vault.sqlite")
    let frames = Self.frames([.delta("partial"), .lookup(TurnLookupEvent(round: 0, tool: "get_notes", args: OrderedJSONObject([]), status: .running))])
    var turn = UUID()
    do {
      let store = try NovelForgeStore.open(at: url)
      turn = try await Self.begin(store).turn
      #expect(try await store.appendLocalTurnFrames(frames, turn: turn))
      #expect(try await store.saveLocalTurnRound(Self.checkpoint, turn: turn))
    }
    let reopened = try NovelForgeStore.open(at: url)
    let interrupted = try #require(try await reopened.pendingLocalTurns().first)
    #expect(interrupted.id == turn && interrupted.replica == reopened.replica)
    #expect(interrupted.checkpoint == Self.checkpoint && interrupted.lastSequence == 2)
    #expect(try await reopened.localTurnFrames(turn) == frames)
    var log = TurnEventLog(after: interrupted.lastSequence)
    log.record(.reset)
    #expect(log.takeFrames().map(\.sequence) == [3])
  }

  @Test func shouldStepOverRowsItCannotReadAndResumeFromTheStartWhenTheRoundIsUnreadable() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, message) = try await Self.begin(store, at: 0)
    let (broken, _) = try await Self.begin(store, at: 5)
    #expect(try await store.saveLocalTurnRound(Self.checkpoint, turn: turn))
    #expect(try await store.appendLocalTurnFrames(Self.frames([.delta("a"), .reset]), turn: turn))
    try await store.write { transaction in
      try transaction.database.execute(sql: "UPDATE nf_local_turn SET state = 'paused' WHERE id = ?", arguments: [broken])
      try transaction.database.execute(sql: "UPDATE nf_local_turn SET checkpoint = X'7B7D' WHERE id = ?", arguments: [turn])
      try transaction.database.execute(sql: "UPDATE nf_local_turn_frame SET event = 'later' WHERE turn = ? AND seq = 1", arguments: [turn])
    }
    let status = try await store.localTurnStatus(session: Self.session, lastMessage: message)
    let pending = try #require(status.pending)
    #expect(pending.id == turn && pending.checkpoint == nil && pending.savedRounds == 0)
    #expect(try await store.localTurnFrames(turn).map(\.sequence) == [2])
    #expect(try await store.pendingLocalTurns().map(\.id) == [turn])
    try await store.clearLocalTurn(broken)
    #expect(try await store.localTurn(broken) == nil)
  }

  @Test func shouldNeitherResumeNorShowATurnAnotherReplicaBeganAndDropItAtTheSessionsNextTurn() async throws {
    let store = try NovelForgeStore.openInMemory()
    let elsewhere = ReplicaID(UUID()).description
    let (foreign, message) = try await Self.begin(store, at: 0)
    let (foreignEnded, endedMessage) = try await Self.begin(store, session: UUID(), at: 1)
    let (otherSession, _) = try await Self.begin(store, session: UUID(), at: 2)
    #expect(try await store.appendLocalTurnFrames(Self.frames([.delta("a")]), turn: foreign))
    #expect(try await store.endLocalTurn(foreignEnded, as: .cancelled))
    try await store.write { transaction in
      try transaction.database.execute(sql: "UPDATE nf_local_turn SET replica = ? WHERE id IN (?, ?, ?)", arguments: [elsewhere, foreign, foreignEnded, otherSession])
    }
    let endedSession = try #require(try await store.localTurn(foreignEnded)?.session)

    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: message) == .idle)
    #expect(try await store.localTurnStatus(session: endedSession, lastMessage: endedMessage) == .idle)
    #expect(try await store.pendingLocalTurns().isEmpty)
    #expect(try await store.failStaleLocalTurns(except: []).isEmpty)
    #expect(try await store.localTurn(foreign)?.state == .pending)

    let (next, _) = try await Self.begin(store, at: 3)
    #expect(try await store.localTurn(foreign) == nil)
    #expect(try await store.localTurnFrames(foreign).isEmpty)
    #expect(try await store.localTurn(otherSession) != nil)
    #expect(try await store.localTurnStatus(session: Self.session, lastMessage: nil).pending?.id == next)
    #expect(try await store.pendingLocalTurns().map(\.id) == [next])
  }

  @Test func shouldFailEveryInterruptedTurnOfThisReplicaThatIsNotResumed() async throws {
    let store = try NovelForgeStore.openInMemory()
    let first = try await Self.begin(store, at: 0)
    let resumed = try await Self.begin(store, session: UUID(), at: 1)
    let third = try await Self.begin(store, session: UUID(), at: 2)
    let foreign = try await Self.begin(store, session: UUID(), at: 3)
    try await store.write { transaction in
      try transaction.database.execute(sql: "UPDATE nf_local_turn SET replica = ? WHERE id = ?", arguments: [ReplicaID(UUID()).description, foreign.turn])
    }

    #expect(try await store.failStaleLocalTurns(except: [resumed.turn], at: Self.start + 60) == [first.turn, third.turn])
    let failed = try #require(try await store.localTurnStatus(session: Self.session, lastMessage: first.message).ended)
    #expect(failed.id == first.turn && failed.state == .failed && failed.failure == LocalTurnStore.interrupted && failed.endedAt == Self.start + 60)
    #expect(try await store.pendingLocalTurns().map(\.id) == [resumed.turn])
    #expect(try await store.localTurn(foreign.turn)?.state == .pending)
    #expect(try await store.failStaleLocalTurns(except: [resumed.turn]).isEmpty)
  }

  @Test func shouldRefuseToSaveARoundBeforeTheFirst() async throws {
    let store = try NovelForgeStore.openInMemory()
    let (turn, _) = try await Self.begin(store)
    #expect(try await store.saveLocalTurnRound(LocalTurnCheckpoint(round: 0, messages: [], carry: .null), turn: turn) == false)
    #expect(try await store.localTurn(turn)?.checkpoint == nil)
  }
}
