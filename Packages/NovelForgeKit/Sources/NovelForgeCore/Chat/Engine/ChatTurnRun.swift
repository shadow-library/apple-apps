import Foundation
import GRDB
import OSLog
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowText
import Synchronization

// apps/novel-forge-server/src/modules/refinement/chat.service.ts:119
private let maxLookupRounds = 3

// chat.service.ts:367
private let lookupBudgetExhausted = "\n\nLookup budget exhausted — answer with what you have; do not request more lookups."

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:76
private let role = "chat"

/// Native: the reference appends its reply before staging, so a staging failure leaves the reply without its cards and says nothing.
let stagingFailedNote = "The changes this reply suggests could not be saved — ask again to see them."
let unlinkedFailureCode = "chat_turn.unlinked"
let recoveryUnavailableCode = "chat_turn.recovery_unavailable"
let recoveryUnavailable = "This turn's changes could not be checked on this device just now, so nothing was staged again. Try the turn again."

enum ChatTurnStop: Error {
  case failed(TurnFailure)
  case stopped
}

/// One run of a turn on this device, from its first model call (or the round, answer or staging it resumes from) to its reply or its end.
final class ChatTurnRun: Sendable {
  private enum Ending: Sendable {
    case answered
    case failed(TurnFailure)
    case stopped
    /// Ended as a crash would end it: nothing more is written and the turn stays pending.
    case crashed
  }

  let engine: ChatTurnEngine
  let basis: ChatTurnBasis
  let control: ChatTurnEngine.Control
  let stream: ChatTurnStream
  private let call: RoutedCall?
  private let checkpoint: LocalTurnCheckpoint?
  private let settled: ChatTurnSettled?
  private let staged: ChatTurnStaged?
  /// What the turn's earlier runs here began, a call a crash cut off included (orchestrator decision 9: the reply stores its call ids).
  private let earlierCalls: [UUID]
  private let titleCalls = Mutex<[UUID]?>(nil)
  private let begun = Mutex<BegunCalls>(BegunCalls())

  /// The model call this run is making, and which of its ledger ids are stored with the turn record.
  private struct BegunCalls {
    var call: RoutedCall?
    var stored: Set<UUID> = []
    var storing = false
    /// The last store, which the run waits for before it ends, so no store lands after a retry of the turn began or a resume read its calls.
    var task: Task<Void, Never>?

    var unstored: [UUID] { call?.callIDs.filter { !stored.contains($0) } ?? [] }
  }

  init(
    engine: ChatTurnEngine, basis: ChatTurnBasis, control: ChatTurnEngine.Control, call: RoutedCall?, checkpoint: LocalTurnCheckpoint?, settled: ChatTurnSettled?,
    staged: ChatTurnStaged?, after lastSequence: Int, sources: [TurnTraceSource], earlierCalls: [UUID]
  ) {
    self.engine = engine
    self.basis = basis
    self.control = control
    self.call = call
    self.checkpoint = checkpoint
    self.settled = settled
    self.staged = staged
    self.earlierCalls = earlierCalls
    stream = ChatTurnStream(after: lastSequence, sources: sources, now: engine.timing.monotonic)
  }

  private var store: VaultStore { engine.store }

  /// chat.service.ts:329-331: not awaited, it overlaps the turn; its ledger ids join the reply only when it finished first.
  func nameSession(router: TaskRouter) {
    let naming = engine.name(ChatSessionNaming(basis), router: router)
    Task.detached { [self] in
      let calls = await naming.value ?? []
      titleCalls.withLock { $0 = calls }
    }
  }

  func run() async -> ChatTurnOutcome {
    engine.grace.turnStarted(basis.turn) { [control] in control.stop(.interrupted) }
    let flusher = Task.detached { [self] in await flushPeriodically() }
    let ending = await execute()
    flusher.cancel()
    await flusher.value
    await begun.withLock { $0.task }?.value
    let outcome = await Task.detached { [self] in await end(ending) }.value
    engine.grace.turnEnded(basis.turn)
    engine.release(basis.turn)
    stream.close()
    return outcome
  }

  private func execute() async -> Ending {
    let answer: ChatTurnSettled
    if let settled {
      answer = settled
    } else {
      do throws(ChatTurnStop) {
        answer = try await ask()
        try await save(settled: answer)
      } catch {
        switch error {
        case .failed(let failure): return .failed(failure)
        case .stopped: return .stopped
        }
      }
      if engine.faults.inject(.settled) == .crash { return .crashed }
    }
    // An answer that is settled is staged and appended whatever happens to the run: a cancel no longer reaches it.
    return await Task.detached { [self] in await finish(answer) }.value
  }

  // MARK: asking

  // chat.service.ts:349-396
  private func ask() async throws(ChatTurnStop) -> ChatTurnSettled {
    let call = try await routed()
    begun.withLock { $0.call = call }
    var rounds = checkpoint?.messages ?? []
    var carry = checkpoint.flatMap { ChatTurnCarry(json: $0.carry) } ?? ChatTurnCarry()
    var round = checkpoint?.round ?? 0
    var counts = ChatLookupCounts()
    for tool in carry.tools { _ = counts.record(tool) }

    var output = try await invoke(call, rounds: &rounds, calls: &carry.calls)
    var settledCount = rounds.count
    let lookups = ChatLookupService(store: store, novel: basis.novel, now: engine.timing.now, embedders: engine.embedders)
    while round < maxLookupRounds, let requested = output.lookups, !requested.isEmpty {
      let results = try await lookUp(requested, round: round, service: lookups, counts: &counts)
      carry.tools += requested.map(\.tool)
      carry.readPlannerOnly = carry.readPlannerOnly || results.readsPlannerOnly
      carry.sources = stream.sources
      let exhausted = round == maxLookupRounds - 1 ? lookupBudgetExhausted : ""
      rounds += [PromptMessage(.assistant, Self.lookupRequest(output)), PromptMessage(.user, "Lookup results:\n\(results.text)\(exhausted)")]
      round += 1
      try await save(LocalTurnCheckpoint(round: round, messages: rounds, carry: carry.json))
      stream.supersede()
      output = try await invoke(call, rounds: &rounds, calls: &carry.calls)
      settledCount = rounds.count
    }
    // chat.service.ts:373
    if !(output.lookups ?? []).isEmpty { output = ChatRefineOutput(reply: output.reply) }

    // chat.service.ts:375-394
    let requested: [String] = NegationEchoDetector.shared?.requestedNegations(basis.authorWords) ?? []
    let exempt = Set(requested.map { JSString($0) })
    output = guarded(output)
    var warnings = await negationWarnings(output, exempt: exempt)
    if !warnings.isEmpty {
      let unrevised = settledCount
      rounds += [PromptMessage(.assistant, Self.changeSetReply(output)), PromptMessage(.user, negationFixRequest(warnings))]
      stream.supersede()
      do throws(ChatTurnStop) {
        let revised = try await invoke(call, rounds: &rounds, calls: &carry.calls)
        if (revised.lookups ?? []).isEmpty {
          settledCount = rounds.count
          output = guarded(revised)
          warnings = await negationWarnings(output, exempt: exempt)
        } else {
          settledCount = unrevised
        }
      } catch {
        if case .stopped = error { throw error }
        ChatTurnEngine.logger.notice("The negation fix round failed; keeping the flagged change set")
        settledCount = unrevised
      }
    }

    let exchangeMessages = basis.exchange == nil ? [] : [PromptMessage(.user, renderTurnMessage(basis.parts))] + rounds.prefix(settledCount)
    return ChatTurnSettled(
      reply: output.reply, changeSet: output.changeSet, question: sanitizeChatQuestion(output.question, allowedProgressKeys: progressItemKeys.map(\.rawValue)),
      warnings: chatTurnWarnings(warnings, readPlannerOnly: carry.readPlannerOnly), trace: stream.finishTrace(), calls: carry.calls,
      exchangeMessages: exchangeMessages)
  }

  /// A resumed turn routes afresh, so a key, consent or spend cap changed meanwhile holds.
  private func routed() async throws(ChatTurnStop) -> RoutedCall {
    if let call { return call }
    // decision 5 for a turn that skips preparation, as a settled retry or a resume does
    guard basis.contentMode == .standard || engine.unrestrictedAvailable else {
      throw .failed(ChatTurnFailures.failure(ChatTurnError.unrestrictedUnavailable))
    }
    let router = await engine.router()
    do {
      return try await router.prepare(
        TaskCall(
          task: .chat, pace: basis.costTier.pace, thinksDeeper: basis.thinksDeeper, contentMode: basis.contentMode.modelContentMode, consent: engine.consent))
    } catch {
      if Task.isCancelled || control.stop != nil { throw .stopped }
      throw .failed(ChatTurnFailures.failure(error))
    }
  }

  /// One structured call with its own relay (model-router.service.ts:442-451); a keyed turn keeps a repair's exchange in its rounds, as the reference's
  /// `onRepair` does (chat.service.ts:347).
  private func invoke(_ call: RoutedCall, rounds: inout [PromptMessage], calls: inout [UUID]) async throws(ChatTurnStop) -> ChatRefineOutput {
    let unrestricted = basis.contentMode == .unrestricted
    // model-router.service.ts:464: an unrestricted call is held to the hard line on its inputs before it is sent
    if unrestricted, let hit = screenTexts(inputScreens(screenedInput(rounds))) { throw .failed(ChatTurnFailures.hardLine(hit)) }
    let parts = ChatRefineRequestParts(
      scopeInstructions: chatScopeInstructions(ChatLookups.tools), stableContext: basis.stableContext, history: basis.history, turn: basis.parts, rounds: rounds)
    let request = call.request(
      system: parts.system, messages: parts.conversation.map { ModelMessage(role: $0.role == .assistant ? .assistant : .user, text: $0.text) },
      cachesConversation: basis.exchange != nil)
    let review = chatRefineReview(lookupsAllowed: true, proseEdits: basis.proseEdits, organiseNotes: basis.organiseRequest)
    let (stream, control, keyed, sent) = (stream, control, basis.exchange != nil, request.messages.count)
    var relay = ReplyStreamRelay(contentMode: basis.contentMode, role: role)
    var repairs = [PromptMessage]()
    let result: StructuredResult
    do {
      result = try await call.streamStructured(request, name: chatRefineSchemaName, schema: JSONValue(schema: chatRefineSchema), review: review) { event in
        switch event {
        case .attemptStarted(let attempt):
          stream.sent(attempt)
          if keyed, case .repair = attempt.purpose {
            repairs = attempt.request.messages.dropFirst(sent).map { PromptMessage($0.role == .assistant ? .assistant : .user, $0.text) }
          }
        // a stop ends the call as a failed attempt, and the stopped turn keeps what it wrote (apps/novel-forge-web/src/features/chat/StreamedTurn.tsx:28)
        case .completed(.failed) where control.stop == nil:
          stream.relay(relay.restart())
        case .textDelta:
          storeBegunCalls()
        case .reset, .completed:
          break
        }
        stream.relay(relay.receive(event))
      }
    } catch {
      calls += error.callIDs
      if Task.isCancelled || control.stop != nil { throw .stopped }
      throw .failed(ChatTurnFailures.failure(error.error))
    }
    calls += result.callIDs
    rounds += repairs
    guard let json = try? OrderedJSON(parsing: String(decoding: result.json, as: UTF8.self)), let output = ChatRefineOutput(json: json) else {
      stream.relay(relay.restart())
      throw .failed(TurnFailure(code: ChatTurnFailures.unreadableReplyCode, message: ChatTurnFailures.unreadableReply))
    }
    // model-router.service.ts:761-781: what an unrestricted model wrote is screened before anything keeps it, and what it showed is voided
    if unrestricted, let hit = screenTexts(outputScreens(json, role: role)) {
      stream.relay(relay.restart())
      throw .failed(ChatTurnFailures.hardLine(hit))
    }
    stream.relay(relay.settle(result))
    return output
  }

  // model-router.service.ts:464 reads the prompt's input variables; the turn's are chat-refine.prompt.ts:31-48's
  private func screenedInput(_ rounds: [PromptMessage]) -> OrderedJSONObject {
    OrderedJSONObject([
      ("scopeInstructions", .string(chatScopeInstructions(ChatLookups.tools))), ("stableContext", .string(basis.stableContext)),
      ("history", .array(basis.history.map { .string($0.text) })), ("volatileContext", .string(basis.parts.volatileContext)),
      ("turnRules", .string(basis.parts.turnRules)), ("userMessage", .string(basis.parts.userMessage)), ("rounds", .array(rounds.map { .string($0.text) })),
    ])
  }

  // apps/novel-forge-server/src/modules/refinement/chat-lookup.service.ts:51-118
  private func lookUp(_ requested: [ChatLookup], round: Int, service: ChatLookupService, counts: inout ChatLookupCounts) async throws(ChatTurnStop) -> ChatLookupRound {
    if Task.isCancelled || control.stop != nil { throw .stopped }
    for lookup in requested {
      stream.emit(.lookup(TurnLookupEvent(round: round, tool: lookup.tool, args: lookup.args ?? OrderedJSONObject([]), status: .running)))
      stream.lookupStarted()
    }
    let results: ChatLookupRound
    do {
      results = try await service.execute(requested.map { ChatLookupCall(tool: $0.tool, args: $0.args) }, counts: &counts)
    } catch {
      for lookup in requested {
        let args = lookup.args ?? OrderedJSONObject([])
        stream.emit(.lookup(TurnLookupEvent(round: round, tool: lookup.tool, args: args, status: .error)))
        let trace = ChatLookupTrace(tool: lookup.tool, args: traceArgs(tool: lookup.tool, args: args), status: .error, audit: .handlerError, resultCharacters: 0, truncated: false)
        stream.lookupSettled(trace, tool: lookup.tool)
      }
      throw .stopped
    }
    for (lookup, outcome) in zip(requested, results.outcomes) {
      let status: TurnLookupStatus = outcome.trace.status == .ok ? .ok : .error
      stream.emit(.lookup(TurnLookupEvent(round: round, tool: lookup.tool, args: lookup.args ?? OrderedJSONObject([]), status: status)))
      stream.lookupSettled(outcome.trace, tool: lookup.tool)
    }
    if Task.isCancelled || control.stop != nil { throw .stopped }
    return results
  }

  // chat.service.ts:368: `JSON.stringify({ reply, lookups })`
  private static func lookupRequest(_ output: ChatRefineOutput) -> String {
    let lookups = (output.lookups ?? []).map { lookup in
      OrderedJSON.object(OrderedJSONObject([("tool", .string(lookup.tool))] + (lookup.args.map { [("args", OrderedJSON.object($0))] } ?? [])))
    }
    return OrderedJSON.object(OrderedJSONObject([("reply", .string(output.reply)), ("lookups", .array(lookups))])).jsonText
  }

  // chat.service.ts:381: `JSON.stringify({ reply, changeSet })`, which leaves out an absent change set
  private static func changeSetReply(_ output: ChatRefineOutput) -> String {
    let changeSet = output.changeSet.map { [("changeSet", OrderedJSON.array($0.map(OrderedJSON.object)))] } ?? []
    return OrderedJSON.object(OrderedJSONObject([("reply", .string(output.reply))] + changeSet)).jsonText
  }

  // chat.service.ts:296
  private func guarded(_ output: ChatRefineOutput) -> ChatRefineOutput {
    withLaterPlansRouted(withheldProse(output), organise: basis.organise)
  }

  // chat.service.ts:121-130
  private func withheldProse(_ output: ChatRefineOutput) -> ChatRefineOutput {
    guard !basis.proseEdits, let changeSet = output.changeSet, !changeSet.isEmpty else { return output }
    let (kept, withheld) = withoutProseEditOps(changeSet)
    guard withheld > 0 else { return output }
    return ChatRefineOutput(reply: "\(output.reply)\n\n\(proseWithheldNote(changeSet))", changeSet: kept.isEmpty ? nil : kept, question: output.question)
  }

  /// chat.service.ts:506-514: a check that cannot run stages without its warnings. Drafts are read through this device's working copies.
  private func negationWarnings(_ output: ChatRefineOutput, exempt: Set<JSString>) async -> [String] {
    guard let changeSet = output.changeSet, !changeSet.isEmpty,
      let ops = try? parseOptionalChangeSet(.array(changeSet.map(OrderedJSON.object)), allowedOps: hubAllowedOps), !ops.isEmpty
    else { return [] }
    let novel = basis.novel
    do {
      return try await store.read { transaction in
        let chapters = DraftReadThrough.draftChapters(of: changeSetRefs(ops))
        let drafts = try ChatTurnDrafts.read(chapters, novel: novel, in: transaction).mapValues(\.record)
        let baselines = try ProposalWarnings.baselineTexts(ops, novel: novel, drafts: drafts, in: transaction)
        return ProposalWarnings.negationEchoes(ops, baselines: baselines, options: NegationEchoOptions(exempt: exempt)) ?? []
      }
    } catch {
      ChatTurnEngine.logger.notice("The negation check could not read the records; staging without its warnings code=\(error.code, privacy: .public)")
      return []
    }
  }

  // MARK: finishing

  /// chat.service.ts:447-487 in two steps: the staging (its own transactions) with the reply's id, then the reply appended in one transaction with its
  /// exchange and the end of the local turn. What staging left is saved first, and staging never runs twice for one reply: a run that starts from a saved
  /// answer first reads which staging transactions committed, and fails rather than stage when it cannot read them.
  private func finish(_ answer: ChatTurnSettled) async -> Ending {
    var outcome = staged
    if outcome == nil, settled != nil {
      switch await recoveredStaging() {
      case .failure:
        return .failed(TurnFailure(code: recoveryUnavailableCode, message: recoveryUnavailable))
      case .success(let recovered):
        outcome = recovered
      }
    }
    if outcome == nil {
      let made = await stage(answer)
      outcome = made
      switch engine.faults.inject(.staged) {
      case .crash?: return .crashed
      case .failure?: ChatTurnEngine.logger.error("Could not save what a turn staged")
      case nil: await save(staged: made)
      }
    }
    let result = outcome ?? ChatTurnStaged(appliedProposal: nil, cardProposal: nil, applyNote: nil, held: nil, replyNote: nil)
    let content = result.replyNote.map { "\(answer.reply)\n\n\($0)" } ?? answer.reply
    var calls = [UUID]()
    for id in basis.compactionCalls + (titleCalls.withLock { $0 } ?? []) + earlierCalls + answer.calls where !calls.contains(id) { calls.append(id) }
    let reply: ChatMessageRecord
    do {
      reply = try ChatMessageRecord(
        id: basis.reply, novel: basis.novel, session: basis.session, role: .assistant, content: content, passageContexts: [], answers: basis.userMessage, seen: basis.seen,
        pace: basis.costTier, deeper: basis.thinksDeeper, contentMode: basis.contentMode, justDiscussing: basis.justDiscussing, proseEdits: basis.proseEdits,
        tokens: countTokens(content), question: answer.question, trace: answer.trace, modelCalls: calls.isEmpty ? nil : calls,
        appliedProposal: result.appliedProposal, cardProposal: result.cardProposal, applyNote: result.applyNote, held: result.held)
    } catch {
      return .failed(ChatTurnFailures.failure(error))
    }
    let exchange = basis.exchange.map { ChatExchange(segment: $0.segment, opening: $0.opening, sections: $0.sections, messages: answer.exchangeMessages) }
    let fault = engine.faults.inject(.appending)
    if fault == .crash { return .crashed }
    let (basis, pending, now) = (basis, stream.take(), engine.timing.now())
    do throws(StoreError) {
      if fault == .failure { throw .database("an injected failure of the reply's write") }
      try await store.write { transaction in
        _ = try reply.append(in: &transaction)
        if let exchange { try ChatContextExchangeLog.record(exchange, reply: basis.reply, session: basis.session, in: transaction.database) }
        if let attempt = pending.attempt { try ChatCallInspector.record(attempt, turn: basis.turn, session: basis.session, at: now, in: transaction.database) }
        try LocalTurnStore.finish(basis.turn, in: transaction.database)
        try ChatTurnRecords.forget(basis.turn, in: transaction.database)
      }
    } catch {
      stream.requeue(pending)
      ChatTurnEngine.logger.error("Could not append a turn's reply code=\(error.code, privacy: .public)")
      // turn-proposals.ts:19 (the reference's UNLINKED case): the author's words applied, but no reply names them
      guard result.appliedProposal == nil else { return .failed(TurnFailure(code: unlinkedFailureCode, message: unlinkedNote)) }
      return .failed(ChatTurnFailures.failure(error))
    }
    stream.emit(.done(reply: basis.reply))
    return .answered
  }

  // chat.service.ts:479; a staging that throws still leaves the reply, with the reasons it gathered (F18's retry notes) and a line saying so
  private func stage(_ answer: ChatTurnSettled) async -> ChatTurnStaged {
    let request = TurnStagingRequest(
      novel: basis.novel, session: basis.session, reply: basis.reply, replyText: answer.reply, changeSet: answer.changeSet, authorMessage: basis.authorWords,
      mode: basis.sessionMode, justDiscussing: basis.justDiscussing, organise: basis.organise, contexts: basis.contexts, warnings: answer.warnings,
      run: basis.turn.uuidString.lowercased(), now: engine.timing.now(),
      unrestrictedAvailable: engine.unrestrictedAvailable)
    do {
      let result = try await store.stageTurn(request)
      return ChatTurnStaged(
        appliedProposal: result.appliedProposal, cardProposal: result.cardProposal, applyNote: result.applyNote, held: result.held?.rawValue, replyNote: result.replyNote)
    } catch {
      ChatTurnEngine.logger.error("Could not stage a turn's changes code=\(error.code, privacy: .public)")
      let notes: [String] = if case .unsaved(_, let replyNotes) = error { replyNotes } else { [] }
      return ChatTurnStaged(appliedProposal: nil, cardProposal: nil, applyNote: nil, held: nil, replyNote: TurnStagingFlow.replyNote(notes + [stagingFailedNote]))
    }
  }

  private struct RecoveryUnavailable: Error {}

  /// What a run that stopped after staging committed and before it saved the result had staged, from the steps recorded in the staging transactions:
  /// nil when nothing committed. The last step's notes are the reply's, as the staging would have ended there; cards that were to follow an applied side
  /// and whose step never committed are said to be missing, as when their transaction fails (turn-proposals.ts:160). A step recorded without notes says
  /// only that.
  private func recoveredStaging() async -> Result<ChatTurnStaged?, RecoveryUnavailable> {
    let reply = basis.reply
    let read: [TurnStagingMark]?
    do {
      read = try await store.read { transaction in try TurnStagingMarks.marks(of: reply, in: transaction.database) }
    } catch {
      return .failure(RecoveryUnavailable())
    }
    guard let marks = read else { return .failure(RecoveryUnavailable()) }
    guard let last = marks.last else { return .success(nil) }
    var applied: (proposal: UUID, cardsFollow: Bool)?
    var cards: UUID??
    for mark in marks {
      switch mark.step {
      case .applied(let proposal, let cardsFollow): applied = (proposal, cardsFollow)
      case .cards(let proposal): cards = .some(proposal)
      }
    }
    let card = cards ?? nil
    let missing = cards == nil && applied?.cardsFollow == true
    let notes = last.notes ?? TurnStagingNotes(applyNote: missing ? cardsUnsavedNote : nil)
    return .success(
      ChatTurnStaged(
        appliedProposal: applied?.proposal, cardProposal: card, applyNote: notes.applyNote, held: notes.held?.rawValue, replyNote: notes.replyNote))
  }

  // MARK: writing

  private func save(_ checkpoint: LocalTurnCheckpoint) async throws(ChatTurnStop) {
    let (turn, pending, now, session) = (basis.turn, stream.take(), engine.timing.now(), basis.session)
    do {
      try await store.write { transaction in
        try Self.write(pending, turn: turn, session: session, at: now, in: transaction.database)
        try LocalTurnStore.save(checkpoint, turn: turn, at: now, in: transaction.database)
      }
    } catch {
      stream.requeue(pending)
      if Task.isCancelled || control.stop != nil { throw .stopped }
      ChatTurnEngine.logger.notice("Could not save a lookup round; a resume repeats it code=\(error.code, privacy: .public)")
    }
  }

  private func save(settled: ChatTurnSettled) async throws(ChatTurnStop) {
    let (turn, pending, now, session) = (basis.turn, stream.take(), engine.timing.now(), basis.session)
    do {
      try await store.write { transaction in
        try Self.write(pending, turn: turn, session: session, at: now, in: transaction.database)
        try ChatTurnRecords.settle(turn, settled, in: transaction.database)
      }
    } catch {
      stream.requeue(pending)
      if Task.isCancelled || control.stop != nil { throw .stopped }
      throw .failed(ChatTurnFailures.failure(error))
    }
  }

  private func save(staged: ChatTurnStaged) async {
    let turn = basis.turn
    do {
      try await store.write { transaction in try ChatTurnRecords.stage(turn, staged, in: transaction.database) }
    } catch {
      ChatTurnEngine.logger.error("Could not save what a turn staged code=\(error.code, privacy: .public)")
    }
  }

  private func flushPeriodically() async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: engine.timing.flushInterval)
      } catch {
        return
      }
      let (turn, pending, now, session) = (basis.turn, stream.take(), engine.timing.now(), basis.session)
      let calls = begun.withLock { $0.unstored }
      guard !pending.isEmpty || !calls.isEmpty else { continue }
      do {
        try await store.write { transaction in
          try Self.write(pending, turn: turn, session: session, at: now, in: transaction.database)
          try ChatTurnRecords.began(calls, turn: turn, session: session, in: transaction.database)
        }
        begun.withLock { $0.stored.formUnion(calls) }
      } catch {
        stream.requeue(pending)
      }
    }
  }

  /// A call's ledger id is stored as soon as the call streams, so a crash while it runs leaves the id for the reply of the resumed turn; a call that
  /// streams nothing before a crash is stored by the next flush or not at all.
  private func storeBegunCalls() {
    let start = begun.withLock { begun -> Bool in
      guard !begun.storing, !begun.unstored.isEmpty else { return false }
      begun.storing = true
      return true
    }
    guard start else { return }
    let (turn, session) = (basis.turn, basis.session)
    let task = Task.detached { [self] in
      while let calls = begun.withLock({ begun -> [UUID]? in
        let calls = begun.unstored
        if calls.isEmpty { begun.storing = false }
        return calls.isEmpty ? nil : calls
      }) {
        do throws(StoreError) {
          try await store.write { transaction in try ChatTurnRecords.began(calls, turn: turn, session: session, in: transaction.database) }
        } catch {
          ChatTurnEngine.logger.notice("Could not store a turn's model calls code=\(error.code, privacy: .public)")
          begun.withLock { $0.storing = false }
          return
        }
        begun.withLock { $0.stored.formUnion(calls) }
      }
    }
    begun.withLock { $0.task = task }
  }

  /// Ends the local turn with its last frames in one write; an interrupted turn only stores them and stays pending.
  private func end(_ ending: Ending) async -> ChatTurnOutcome {
    let outcome: ChatTurnOutcome
    let end: LocalTurnEnd?
    switch ending {
    case .answered:
      return .answered(reply: basis.reply)
    case .crashed:
      return .interrupted
    case .failed(let failure):
      stream.emit(.error(failure))
      (outcome, end) = (.failed(failure), .failed(failure))
    case .stopped where control.stop == .interrupted:
      (outcome, end) = (.interrupted, nil)
    case .stopped:
      (outcome, end) = (.cancelled, .cancelled)
    }
    if engine.faults.inject(.ending) == .crash { return .interrupted }
    let (turn, pending, now, session) = (basis.turn, stream.take(), engine.timing.now(), basis.session)
    do {
      try await store.write { transaction in
        try Self.write(pending, turn: turn, session: session, at: now, in: transaction.database)
        if let end { try LocalTurnStore.end(turn, as: end, at: now, in: transaction.database) }
      }
    } catch {
      ChatTurnEngine.logger.error("Could not record a turn's end code=\(error.code, privacy: .public)")
    }
    return outcome
  }

  static func write(_ pending: ChatTurnStream.Pending, turn: UUID, session: UUID, at now: Date, in database: Database) throws(StoreError) {
    try LocalTurnStore.append(pending.frames, turn: turn, at: now, in: database)
    if let attempt = pending.attempt { try ChatCallInspector.record(attempt, turn: turn, session: session, at: now, in: database) }
  }
}
