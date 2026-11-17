import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowStore

enum ChatTurnAuthored: Sendable {
  case new(content: String, passages: [ChatTurnPassage], choices: ChatTurnChoices)
  /// An author message already in the transcript: a retry, or one another device is answering.
  case existing(UUID)
}

struct ChatTurnPrepared: Sendable {
  let basis: ChatTurnBasis
  /// The author's message to append with the turn, for a new one.
  let message: ChatMessageRecord?
  let call: RoutedCall
}

extension CostTier {
  /// The reference's tiers as the native paces (Think deeper is its own flag, as `TaskCall.thinksDeeper`).
  var pace: Pace {
    switch self {
    case .economy: .swift
    case .balanced: .steady
    case .performant: .meticulous
    }
  }
}

extension ContentMode {
  var modelContentMode: ModelContentMode {
    switch self {
    case .standard: .standard
    case .unrestricted: .unrestricted
    }
  }
}

private struct ChatTurnSnapshot: Sendable {
  let session: ChatSessionRecord
  let novel: NovelRecord
  let content: String
  let contexts: [ChatPassageContext]
  let choices: ChatTurnChoices
  let message: UUID?
  let notesWords: Int
  let opened: HLCTimestamp?
  let exchanges: [UUID: ChatExchange]
}

extension ChatTurnEngine {
  // apps/novel-forge-server/src/modules/refinement/chat.service.ts:269-311, through building the request; nothing is written but a compaction's summary.
  func prepare(_ authored: ChatTurnAuthored, session: UUID, novel: UUID, turn: UUID, router: TaskRouter) async throws(ChatTurnError) -> ChatTurnPrepared {
    if case .new(let content, let passages, _) = authored {
      // chat.dto.ts:471-476
      guard content.unicodeScalars.count <= maxChatTurnCharacters else { throw .messageTooLong(limit: maxChatTurnCharacters) }
      try ChatTurnDrafts.validate(passages)
    }
    let snapshot = try await snapshot(authored, session: session, novel: novel)
    // chat.service.ts:274
    if snapshot.message == nil, snapshot.content.jsTrim().isEmpty, snapshot.contexts.isEmpty { throw .emptyMessage }

    let novelMode = snapshot.novel.contentMode.known ?? .unrestricted
    let selection = try available(
      chatSelection(
        ChatSelectionOverride(contentMode: snapshot.choices.contentMode, costTier: snapshot.choices.pace),
        project: ChatProjectConfig(contentMode: snapshot.novel.contentMode.known, costTier: snapshot.novel.costTier.known)),
      authored: authored, asked: snapshot.choices.contentMode)
    let compacted = try await compact(session, selection: selection, novelMode: novelMode, router: router)

    // chat.service.ts:284, :414-423
    let call: RoutedCall
    do {
      call = try await router.prepare(
        TaskCall(
          task: .chat, pace: selection.costTier.pace, thinksDeeper: snapshot.choices.thinksDeeper, contentMode: selection.contentMode.modelContentMode, consent: consent))
    } catch {
      throw .routing(error)
    }
    // chat.service.ts:285-290: refused before it is saved, since a stored message would ride every later turn's history
    if selection.contentMode == .unrestricted, let hit = screenTexts(turnScreens(snapshot.content, contexts: snapshot.contexts)) {
      Self.logger.notice("Refused a chat turn before saving it rule=\(hit.rule.rawValue, privacy: .public) source=\(hit.source, privacy: .public)")
      throw .hardLine(code: hardLineError(hit).code, message: hardLineError(hit).errorDescription ?? hit.source)
    }

    let window = compacted.window
    let history: [ChatWindowMessage]
    if let message = snapshot.message {
      guard let position = window.messages.firstIndex(where: { $0.record.id == message }) else { throw .messageNotAnswerable }
      history = Array(window.messages[..<position])
    } else {
      history = window.messages
    }
    let sessionMode = snapshot.session.mode.known.flatMap { RefinementChatMode(rawValue: $0.rawValue) } ?? .manual
    // chat.service.ts:293-297
    let organiseRequest = isNotesOrganiseRequest(snapshot.content) && snapshot.notesWords >= organiseMinWords
    let organise = organiseRouting(organiseRequest: organiseRequest, mode: sessionMode, justDiscussing: snapshot.choices.justDiscussing)
    let turnRules = renderTurnRules(
      ChatTurnPermissions(proseEdits: snapshot.choices.proseEdits, justDiscussing: snapshot.choices.justDiscussing, organiseNotes: organiseRequest, mode: sessionMode))
    // chat.service.ts:299-307: the hub's lookups; a standard turn continues its segment only while the session is known to hold no unrestricted text
    let scope = chatScopeInstructions(ChatLookups.tools)
    let playbook = ChatContextExchange.playbookDigest(scope)
    let keyed = selection.contentMode == .standard && window.lock == .unlocked
    let conversation = ChatTurnConversation.build(
      window, messages: history, mode: selection.contentMode, keyed: keyed, playbook: playbook, exchanges: snapshot.exchanges)
    let rendered = renderTurnContent(snapshot.content, contexts: snapshot.contexts)
    let requestTokens = countTokens(turnRules) + countTokens(rendered) + ChatTurnConversation.tokens(conversation.plain)
    // chat.service.ts:308-311
    let pack: ChatContextPack
    do {
      pack = try await store.chatContext(novel: novel, since: snapshot.opened, promptTokens: chatPromptTokens(scope), requestTokens: requestTokens)
    } catch {
      throw .store(error)
    }
    let update = keyed ? ChatContextExchange.contextUpdate(pack, holding: conversation.segment?.sections) : nil
    let stableContext = [conversation.segment?.stableContext, pack.renderedStable].compactMap { $0 }.first { !$0.allSatisfy(\.isWhitespace) } ?? "nothing"
    let volatile = update?.text ?? (pack.renderedVolatile.allSatisfy(\.isWhitespace) ? "nothing" : pack.renderedVolatile)
    // chat.service.ts:398-403
    let exchange = update.map { update in
      ChatExchangePlan(
        segment: conversation.segment?.id ?? UUID().uuidString.lowercased(),
        opening: conversation.segment == nil ? ChatSegmentOpening(through: window.watermark, playbook: playbook, stableContext: stableContext) : nil,
        sections: update.sections)
    }

    let userMessage = snapshot.message ?? UUID()
    let seen = history.last?.record.id
    // Answering a message already sent never names the session again: the device that sent it did (chat.service.ts:331).
    let opens = snapshot.message == nil && window.summary == nil && !history.contains { $0.role == .user }
    let basis = ChatTurnBasis(
      turn: turn, novel: novel, session: session, userMessage: userMessage, seen: seen, contentMode: selection.contentMode, costTier: selection.costTier,
      thinksDeeper: snapshot.choices.thinksDeeper, justDiscussing: snapshot.choices.justDiscussing, proseEdits: snapshot.choices.proseEdits, sessionMode: sessionMode,
      organiseRequest: organiseRequest, organise: organise, content: snapshot.content, contexts: snapshot.contexts, stableContext: stableContext,
      history: conversation.history, parts: TurnMessageParts(volatileContext: volatile, turnRules: turnRules, userMessage: rendered), exchange: exchange,
      compactionCalls: compacted.calls, namesSession: opens)
    let message: ChatMessageRecord?
    do {
      // chat.service.ts:425-445; the turn's choices are recorded, so a retry or another device answers it the same way
      message =
        snapshot.message == nil
        ? try ChatMessageRecord(
          id: userMessage, novel: novel, session: session, role: .user, content: snapshot.content, passageContexts: snapshot.contexts, seen: seen,
          pace: selection.costTier, deeper: snapshot.choices.thinksDeeper, contentMode: selection.contentMode, justDiscussing: snapshot.choices.justDiscussing,
          proseEdits: snapshot.choices.proseEdits, tokens: countTokens(rendered)) : nil
    } catch {
      throw .conversationUnavailable(code: error.code, message: error.errorDescription ?? error.code)
    }
    return ChatTurnPrepared(basis: basis, message: message, call: call)
  }

  /// Orchestrator decision 5, while the build cannot write unrestricted text: a new message that only follows an unrestricted novel is written standard,
  /// and one that asks for unrestricted writing, or an earlier message whose turn would be unrestricted, is refused as the reference refuses an
  /// unavailable mode (chat.dto.ts:502, AI_024). Answer, retry and resume start from a basis this check made, so none of them can run unrestricted.
  private func available(_ selection: ChatSelection, authored: ChatTurnAuthored, asked: ContentMode?) throws(ChatTurnError) -> ChatSelection {
    guard selection.contentMode == .unrestricted, !unrestrictedAvailable else { return selection }
    guard case .new = authored, asked != .unrestricted else { throw .unrestrictedUnavailable }
    return ChatSelection(contentMode: .standard, costTier: selection.costTier)
  }

  // chat.service.ts:282; a compaction that cannot run fails the turn before its message is saved, as the reference's does before its run exists
  private func compact(_ session: UUID, selection: ChatSelection, novelMode: ContentMode, router: TaskRouter) async throws(ChatTurnError)
    -> (window: ChatConversationWindow, calls: [UUID])
  {
    // decision 5: a novel's unrestricted mode alone never raises a fold here; text the session holds still does, and the fold is then refused
    let turn = ChatCompactionTurn(
      contentMode: selection.contentMode, novelMode: unrestrictedAvailable ? novelMode : .standard, pace: selection.costTier.pace, consent: consent,
      unrestrictedAvailable: unrestrictedAvailable)
    let result: ChatCompactionResult
    do {
      result = try await ChatCompaction.compactIfNeeded(session: session, turn: turn, store: store, router: router)
    } catch {
      if case .routing(let routing) = error { throw .routing(routing) }
      if case .store(let store) = error { throw .store(store) }
      if case .unrestrictedUnavailable = error { throw .unrestrictedUnavailable }
      throw .conversationUnavailable(code: error.code, message: error.errorDescription ?? error.code)
    }
    switch result.outcome {
    case .kept: return (result.window, [])
    case .folded(_, _, let calls), .refused(_, let calls): return (result.window, calls)
    }
  }

  private func snapshot(_ authored: ChatTurnAuthored, session: UUID, novel: UUID) async throws(ChatTurnError) -> ChatTurnSnapshot {
    do {
      return try await store.read { transaction in try Self.snapshot(authored, session: session, novel: novel, in: transaction) }
    } catch {
      if case .aborted(let cause) = error, let refusal = cause as? ChatTurnError { throw refusal }
      throw .store(error)
    }
  }

  private static func snapshot(_ authored: ChatTurnAuthored, session: UUID, novel: UUID, in transaction: ReadTransaction) throws -> ChatTurnSnapshot {
    // chat.service.ts:270-271
    guard case .readable(let sessionEntry) = try ChatSessionRecord.read(id: session, in: transaction), !sessionEntry.isRemoved, sessionEntry.record.novel == novel
    else { throw ChatTurnError.sessionNotFound }
    guard sessionEntry.record.status == .known(.active) else { throw ChatTurnError.sessionArchived }
    guard case .readable(let novelEntry) = try NovelRecord.read(id: novel, in: transaction), !novelEntry.isRemoved else { throw ChatTurnError.novelNotFound }

    let content: String
    let contexts: [ChatPassageContext]
    let choices: ChatTurnChoices
    let message: UUID?
    switch authored {
    case .new(let text, let passages, let chosen):
      // chat.service.ts:273: passages are anchored to the drafts as this device shows them
      let drafts = try ChatTurnDrafts.read(passages.map(\.chapter), novel: novel, in: transaction)
      (content, contexts, choices, message) = (text, try ChatTurnDrafts.resolve(passages, drafts: drafts), chosen, nil)
    case .existing(let id):
      // a message whose passages this device cannot read is not answered: its turn could not show the model what the author pointed at
      guard case .readable(let entry) = try ChatMessageRecord.read(id: id, in: transaction), entry.record.role == .known(.user),
        entry.record.session == session, entry.record.novel == novel, !entry.record.hasUnreadableContexts
      else { throw ChatTurnError.messageNotAnswerable }
      let record = entry.record
      content = record.content
      contexts = record.passageContexts ?? []
      choices = ChatTurnChoices(
        pace: record.pace?.known, thinksDeeper: record.deeper ?? false, contentMode: record.contentMode?.known, justDiscussing: record.justDiscussing ?? false,
        proseEdits: record.proseEdits ?? false)
      message = id
    }
    var notesWords = 0
    if isNotesOrganiseRequest(content), case .readable(let notes) = try AuthorNotesRecord.read(novel: novel, in: transaction) {
      notesWords = ProseMetrics.countWords(notes.record.content.text)
    }
    return ChatTurnSnapshot(
      session: sessionEntry.record, novel: novelEntry.record, content: content, contexts: contexts, choices: choices, message: message, notesWords: notesWords,
      opened: try ChatContextLoader.sessionOpened(session, in: transaction), exchanges: try ChatContextExchangeLog.load(session: session, in: transaction.database))
  }
}
