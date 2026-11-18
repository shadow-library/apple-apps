import Foundation
import NovelForgeCore
import Observation
import ShadowStore

nonisolated struct ChatTrayCard: Equatable, Sendable {
  let proposal: UUID
  let session: ChatProposalSession
  /// Nil when this device cannot read the card.
  let title: String?
  /// The indexes that touch what changed since the card was staged; nil while it would apply as staged.
  let conflicts: [Int]?
}

/// Why an applied card's actions are still pending, as far as this device can tell.
nonisolated enum ChatTrayActionStanding: Equatable, Sendable {
  /// No sweep row here: another device applied it, or this one forgot the row.
  case notHere
  /// The launch sweep left them pending with this code; `givenUp` once no later launch runs them.
  case faulted(code: String?, givenUp: Bool)
}

nonisolated struct ChatTrayActions: Equatable, Sendable {
  let proposal: UUID
  let session: ChatProposalSession
  let title: String?
  let indexes: [Int]
  let standing: ChatTrayActionStanding
}

/// A chat's newest message, when it waits on the author: Forge's question, or the author's own message with no reply.
nonisolated struct ChatTrayLast: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case question(String)
    case author(ChatAnswerBlock?)
  }

  let session: UUID
  let message: UUID
  let kind: Kind
}

/// The session activity the tray reads for a chat whose newest message is the author's.
nonisolated enum ChatTrayActivity: Equatable, Sendable {
  case elsewhere(message: UUID)
  case interrupted
  case failed

  /// A running turn, a stopped one (the author's own doing) and an idle chat wait on nobody.
  init?(_ activity: ChatTurnActivity) {
    switch activity {
    case .answeringElsewhere(let message): self = .elsewhere(message: message)
    case .interrupted: self = .interrupted
    case .ended(let turn) where turn.state != .cancelled: self = .failed
    case .idle, .running, .ended: return nil
    }
  }
}

nonisolated struct ChatTrayCards: Equatable, Sendable {
  let cards: [ChatTrayCard]
  let actions: [ChatTrayActions]
}

/// Everything the tray lists, read in one transaction: the novel's waiting cards and actions (ChatWaitingOnYou), and every active chat's newest message.
nonisolated struct ChatTraySnapshot: Equatable, Sendable {
  let cards: Derived<ChatTrayCards>
  let lasts: [ChatTrayLast]

  static func load(novel: UUID, in transaction: ReadTransaction) throws -> ChatTraySnapshot {
    let lasts = try Self.lasts(novel: novel, in: transaction)
    switch try ChatWaitingOnYou.load(novel, in: transaction).contents {
    case .unavailable(let faults):
      return ChatTraySnapshot(cards: .unavailable(faults), lasts: lasts)
    case .available(let contents):
      let standings = try ChatPendingActionStanding.load(novel: novel, in: transaction)
      let titles = try Self.titles(contents.actions.map(\.proposal), in: transaction)
      let staged = (contents.cards + contents.conflicted).sorted { $0.state.staged == $1.state.staged ? $0.state.ref < $1.state.ref : $0.state.staged < $1.state.staged }
      let cards = ChatTrayCards(
        cards: staged.map { ChatTrayCard(proposal: $0.state.proposal, session: $0.session, title: $0.card.map(ChatTrayTitles.title), conflicts: $0.conflict?.indexes) },
        actions: contents.actions.compactMap { action in
          Self.standing(standings[action.proposal].map { ($0.fault, $0.isGivenUp) }).map {
            ChatTrayActions(proposal: action.proposal, session: action.session, title: titles[action.proposal], indexes: action.indexes, standing: $0)
          }
        })
      return ChatTraySnapshot(cards: .available(cards), lasts: lasts)
    }
  }

  /// A row with no fault yet belongs to an apply running its actions now, or to a sweep that has not finished: neither waits on the author.
  static func standing(_ row: (fault: String?, isGivenUp: Bool)?) -> ChatTrayActionStanding? {
    guard let row else { return .notHere }
    guard row.fault != nil || row.isGivenUp else { return nil }
    return .faulted(code: row.fault, givenUp: row.isGivenUp)
  }

  private static func titles(_ proposals: [UUID], in transaction: ReadTransaction) throws -> [UUID: String] {
    var titles = [UUID: String]()
    for proposal in proposals {
      guard let card = try ProposalRecord.read(id: proposal, in: transaction).entry?.record.card else { continue }
      titles[proposal] = ChatTrayTitles.title(card)
    }
    return titles
  }

  /// Archived chats take no turn, so what waits in them is left out; their cards still wait, novel-wide.
  private static func lasts(novel: UUID, in transaction: ReadTransaction) throws -> [ChatTrayLast] {
    let sessions = try ChatSessionList.load(ChatSessionListQuery(novel: novel, filter: .active, startedOnly: true), in: transaction).sessions.value ?? []
    let mode: ContentMode = try NovelRecord.read(id: novel, in: transaction).entry?.record.contentMode.known == .unrestricted ? .unrestricted : .standard
    var undecided: Set<ProgressItemKey>?
    return try sessions.compactMap { overview -> ChatTrayLast? in
      let session = overview.state.session
      guard let last = try ChatTranscript.load(ChatTranscriptQuery(session: session, limit: 1), in: transaction).page.value?.messages.last,
        let record = last.record
      else { return nil }
      switch record.role {
      case .known(.user):
        return ChatTrayLast(session: session, message: record.id, kind: .author(ChatAnswerBlock.of(last, novelMode: mode)))
      case .known(.assistant):
        // chat-view.ts:625-629: Forge's newest reply asked a question the author has not written after
        guard let question = record.questionCard, !question.answers.isEmpty else { return nil }
        if let key = question.progressKey.flatMap(ProgressItemKey.init(rawValue:)) {
          if undecided == nil { undecided = try Self.undecided(novel: novel, in: transaction) }
          if undecided?.contains(key) == true { return nil }
        }
        return ChatTrayLast(session: session, message: record.id, kind: .question(question.question))
      default:
        return nil
      }
    }
  }

  /// ChatColumn.tsx:641-647: Undecided for now on a checklist item answers its question.
  private static func undecided(novel: UUID, in transaction: ReadTransaction) throws -> Set<ProgressItemKey> {
    let items = try ProgressChecklist.load(novel, in: transaction).checklist.value?.checklist?.items ?? []
    return Set(items.filter { $0.status == .undecided }.map(\.key))
  }
}

/// apps/novel-forge-web/src/lib/pending-items.ts:97-105: the card's own summary, else the one action it runs, else how many changes it holds.
nonisolated enum ChatTrayTitles {
  static func title(_ card: ProposalCard) -> String {
    title(summary: card.summary, ops: ChatOp.ops(of: card))
  }

  static func title(summary: String?, ops: [ChatOp]) -> String {
    let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    if !first.isEmpty { return first }
    if ops.count == 1, let only = ops.first, only.isAction { return only.subject }
    return String(localized: "\(ops.count) changes", table: "ChatChanges")
  }
}

nonisolated struct ChatTrayItem: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case card(conflicts: [Int]?)
    case unreadableCard
    case actions(indexes: [Int], standing: ChatTrayActionStanding)
    case question
    /// The engine reads the message as answered elsewhere; Answer here is offered only without a block.
    case elsewhere(ChatAnswerBlock?)
    case interrupted
    case failed
  }

  let id: String
  let kind: Kind
  /// Nil for a card this device cannot read.
  let title: String?
  let session: ChatProposalSession
  let target: ChatFocusTarget

  var isAnswerable: Bool { kind == .elsewhere(nil) }

  /// Everything waiting on the author across the novel: unanswered messages and questions chat by chat, then cards by age (pending-items.ts:121-123,
  /// :164-180), then actions that did not run.
  static func items(_ snapshot: ChatTraySnapshot, activities: [UUID: ChatTrayActivity]) -> [ChatTrayItem] {
    var messages = [ChatTrayItem]()
    var questions = [ChatTrayItem]()
    for last in snapshot.lasts {
      let session = ChatProposalSession.live(last.session)
      switch last.kind {
      case .question(let text):
        questions.append(ChatTrayItem(id: "question:\(last.message)", kind: .question, title: text, session: session, target: .message(last.message)))
      case .author(let block):
        guard let kind = Self.waiting(activities[last.session], message: last.message, block: block) else { continue }
        messages.append(ChatTrayItem(id: "message:\(last.message)", kind: kind, title: nil, session: session, target: .message(last.message)))
      }
    }
    let contents = snapshot.cards.value
    let cards = (contents?.cards ?? []).map { card in
      ChatTrayItem(
        id: "card:\(card.proposal)", kind: card.title == nil ? .unreadableCard : .card(conflicts: card.conflicts), title: card.title, session: card.session,
        target: .proposal(card.proposal))
    }
    let actions = (contents?.actions ?? []).map { action in
      ChatTrayItem(
        id: "actions:\(action.proposal)", kind: .actions(indexes: action.indexes, standing: action.standing), title: action.title, session: action.session,
        target: .proposal(action.proposal))
    }
    return messages + questions + cards + actions
  }

  private static func waiting(_ activity: ChatTrayActivity?, message: UUID, block: ChatAnswerBlock?) -> Kind? {
    switch activity {
    case .elsewhere(let waiting) where waiting == message: .elsewhere(block)
    case .interrupted: .interrupted
    case .failed: .failed
    case .elsewhere, nil: nil
    }
  }
}

/// What waits on the author across the novel's chats, kept per novel beside the chats so it reads once for every chat shown.
@MainActor
@Observable
final class ChatTrayModel {
  private(set) var activities: [UUID: ChatTrayActivity] = [:]
  private(set) var generation = 0
  /// The card whose actions the author asked to run again, while they run.
  private(set) var retrying: UUID?
  private(set) var retryNotices: [UUID: PresentedError] = [:]
  /// A chat's own model while it is loaded: it follows a turn live, which the engine's activity is read again for only on a commit.
  @ObservationIgnored var live: (UUID) -> ChatTurnActivity? = { _ in nil }
  private let context: NovelContext
  private let engine: ChatTurnEngine
  private let observer = ReadObserver<ChatTraySnapshot>()
  @ObservationIgnored private var ticket = 0

  init(context: NovelContext, engine: ChatTurnEngine) {
    self.context = context
    self.engine = engine
  }

  var state: Loadable<ChatTraySnapshot> { observer.state }

  var items: [ChatTrayItem] {
    guard let snapshot = state.value else { return [] }
    var merged = activities
    for last in snapshot.lasts {
      guard let activity = live(last.session), activity != .idle else { continue }
      merged[last.session] = ChatTrayActivity(activity)
    }
    return ChatTrayItem.items(snapshot, activities: merged)
  }

  var isUnavailable: Bool { state.value?.cards.isUnavailable == true }

  func observe() async {
    let (store, novel) = (context.store, context.novel)
    await observer.run(
      { store.observeReads { transaction in try ChatTraySnapshot.load(novel: novel, in: transaction) } },
      onValue: { [weak self] _ in Task { await self?.refreshActivities() } })
  }

  func retry() {
    generation += 1
  }

  /// Try Again for actions the launch sweep stopped retrying; what is still pending afterwards stays listed, with how many.
  func retryActions(_ proposal: UUID) async {
    guard retrying == nil else { return }
    retrying = proposal
    defer { retrying = nil }
    do throws(ProposalApplyError) {
      let left = try await context.store.retryPendingActions(proposal, novel: context.novel)
      retryNotices[proposal] = left.isEmpty ? nil : PresentedError(headline: String(localized: "\(left.count) actions still didn't run.", table: "ChatChanges"), detail: nil)
    } catch {
      retryNotices[proposal] = PresentedError(headline: String(localized: "The actions couldn't run again.", table: "ChatChanges"), detail: error.code)
    }
  }

  /// Reads the engine's activity for every chat whose newest message is the author's; a later read replaces an earlier one still in flight.
  func refreshActivities() async {
    ticket += 1
    let current = ticket
    guard let snapshot = state.value else { return }
    var next = [UUID: ChatTrayActivity]()
    for last in snapshot.lasts {
      guard case .author = last.kind, let activity = try? await engine.activity(session: last.session) else { continue }
      next[last.session] = ChatTrayActivity(activity)
    }
    guard current == ticket else { return }
    activities = next
  }
}
