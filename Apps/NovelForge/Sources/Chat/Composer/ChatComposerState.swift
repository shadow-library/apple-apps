import Foundation
import NovelForgeCore
import Observation

/// apps/novel-forge-web/src/features/chat/chat-view.ts:594-606
enum ChatComposerMode: CaseIterable, Hashable {
  case editFreely
  case askFirst
  case justDiscuss

  /// chat-view.ts:619-623: the chat mode a pick implies; Just discuss keeps the chat's own.
  var sessionMode: ChatSessionMode? {
    switch self {
    case .editFreely: .auto
    case .askFirst: .manual
    case .justDiscuss: nil
    }
  }
}

/// apps/novel-forge-web/src/lib/chat-model.ts:24-29
struct ChatReplyOptions: Equatable {
  var thinkDeeper = false
  var unrestricted = false
}

/// How the composer shows Unrestricted: not at all, as a switch that first asks the owner to confirm their age, or as a plain switch.
enum ChatUnrestrictedSwitch: Equatable {
  case hidden
  case gated
  case open
}

/// Which one-shot reply options are on offer (chat-model.ts:39-43): none until the novel is known, and Unrestricted only on a standard novel it is offered for.
struct ChatReplyOffer: Equatable {
  static let none = ChatReplyOffer(thinkDeeper: false, unrestricted: .hidden)

  let thinkDeeper: Bool
  let unrestricted: ChatUnrestrictedSwitch

  init(thinkDeeper: Bool, unrestricted: ChatUnrestrictedSwitch) {
    self.thinkDeeper = thinkDeeper
    self.unrestricted = unrestricted
  }

  init(novel: NovelRecord?, unrestricted offer: UnrestrictedOffer) {
    guard let novel else {
      self = .none
      return
    }
    let unrestricted: ChatUnrestrictedSwitch =
      switch offer {
      case _ where novel.contentMode.known != .standard: .hidden
      case .offered: .open
      case .needsAgeConfirmation: .gated
      case .notInThisBuild, .needsModel, .uncoveredLanguage: .hidden
      }
    self.init(thinkDeeper: novel.costTier.known != .performant, unrestricted: unrestricted)
  }

  var isEmpty: Bool { !thinkDeeper && unrestricted == .hidden }
}

enum ChatPassageAddition: Equatable {
  case added
  case replaced
  /// The message already carries as many comments as it can (passage-comments.ts:112-116).
  case full
}

/// The next message's passages, mode, reply options and Edit prose, per chat (ChatColumn.tsx:214-218, use-passage-chips.ts:64-68).
@MainActor
@Observable
final class ChatComposerState {
  private(set) var chips: [ChatPassageChip] = []
  var proseEdits = false
  var justDiscussing = false
  var replyOptions = ChatReplyOptions()
  /// chat.tsx:425-429: the opening composer creates its chat with this mode.
  var draftMode = ChatSessionMode.auto
  /// ChatColumn.tsx:327: a message sent while the mode saves could still run under the old one.
  private(set) var switching: ChatSessionMode?
  /// Raised to put the cursor in the composer, as ChatColumn.tsx:767 focuses its input.
  private(set) var focusRequest = 0

  var passages: [ChatTurnPassage] { chips.map(\.passage) }

  var hasStaleChips: Bool { chips.contains(where: \.isStale) }

  var isFull: Bool { chips.count >= ChatPassageChip.limit }

  func add(_ chip: ChatPassageChip) -> ChatPassageAddition {
    if let index = chips.firstIndex(where: { $0.id == chip.id }) {
      chips[index] = chip
      return .replaced
    }
    guard !isFull else { return .full }
    chips.append(chip)
    return .added
  }

  func requestFocus() {
    focusRequest += 1
  }

  func remove(_ id: ChatPassageChip.ID) {
    chips.removeAll { $0.id == id }
  }

  func mode(in session: ChatSessionMode) -> ChatComposerMode {
    if justDiscussing { return .justDiscuss }
    return (switching ?? session) == .manual ? .askFirst : .editFreely
  }

  /// ChatColumn.tsx:1045
  func canChangeMode(isLocked: Bool, isRunning: Bool, isSending: Bool) -> Bool {
    !isLocked && !isRunning && !isSending && switching == nil
  }

  /// chat-model.ts:51-56: an option rides the message only while it is still on offer.
  func choices(offer: ChatReplyOffer) -> ChatTurnChoices {
    ChatTurnChoices(
      thinksDeeper: replyOptions.thinkDeeper && offer.thinkDeeper, contentMode: replyOptions.unrestricted && offer.unrestricted == .open ? .unrestricted : nil,
      justDiscussing: justDiscussing, proseEdits: proseEdits)
  }

  /// ChatColumn.tsx:422-425, :469: only the comments the message took leave, and the reply options are one-shot.
  func sent(_ passages: [ChatTurnPassage]) {
    let taken = Set(passages.map(ChatPassageChip.id(of:)))
    chips.removeAll { taken.contains($0.id) }
    replyOptions = ChatReplyOptions()
  }

  /// ChatColumn.tsx:446: Unrestricted refused would be refused again.
  func refused(_ error: ChatTurnError) {
    guard case .unrestrictedUnavailable = error else { return }
    replyOptions.unrestricted = false
  }

  /// A withdrawn age confirmation turns Unrestricted off, so confirming again later does not bring back a choice made before.
  func ageConfirmationWithdrawn() {
    replyOptions.unrestricted = false
  }

  /// passage-comments.ts:154-161: the sent comments their chapters no longer hold, or every one sent when none can be told.
  func markStale(_ sent: [ChatTurnPassage], unresolved: [Int]) {
    let marked = unresolved.isEmpty ? sent : unresolved.filter(sent.indices.contains).map { sent[$0] }
    let ids = Set(marked.map(ChatPassageChip.id(of:)))
    for index in chips.indices where ids.contains(chips[index].id) { chips[index].isStale = true }
  }

  /// use-passage-chips.ts:86-94: the opening composer's comments and choices go into the chat it becomes, and it starts over.
  func adopt(_ opening: ChatComposerState) {
    if chips.isEmpty { chips = opening.chips }
    proseEdits = opening.proseEdits
    justDiscussing = opening.justDiscussing
    replyOptions = opening.replyOptions
    opening.chips = []
    opening.startOver()
  }

  /// chat.tsx:410-421: New chat remounts the column, so its choices reset while its comments stay (use-passage-chips.ts:68-70).
  func startOver() {
    proseEdits = false
    justDiscussing = false
    replyOptions = ChatReplyOptions()
    draftMode = .auto
  }

  /// chat-view.ts:619-623, ChatColumn.tsx:539-553: Just discuss stays here; the other picks save the chat's mode, and a failed save restores Just discuss.
  func choose(_ mode: ChatComposerMode, current: ChatSessionMode, save: ((ChatSessionMode) async -> Bool)?) async {
    let wasDiscussing = justDiscussing
    justDiscussing = mode == .justDiscuss
    guard let wanted = mode.sessionMode, wanted != current else { return }
    guard let save else {
      draftMode = wanted
      return
    }
    switching = wanted
    let saved = await save(wanted)
    switching = nil
    if !saved { justDiscussing = wasDiscussing }
  }
}
