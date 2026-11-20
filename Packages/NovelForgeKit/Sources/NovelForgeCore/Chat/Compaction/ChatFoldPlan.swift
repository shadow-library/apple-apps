import Foundation
import ShadowText

struct ChatFoldPlan: Equatable, Sendable {
  // chat-compaction.service.ts:25-26
  static let maxVerbatimTurns = 12
  static let keepVerbatimTurns = 6
  /// Native: the reference folds everything past the newest six at once (chat-compaction.service.ts:131); after a mass return, such as a session whose
  /// summaries this version cannot read, that could outgrow the helper model's context, so a fold takes the oldest within this many transcript tokens.
  static let maxFoldTokens = 24_000

  let novel: UUID
  let folded: [ChatWindowMessage]
  let kept: [ChatWindowMessage]
  let priorSummary: String
  let transcript: String
  /// The standing summary's ids, then the folded ones: the new summary's text stands for both, so it never covers less than the one it replaces.
  /// PERF: it grows with every fold, so a long session's summaries repeat O(n) ids.
  let covered: [UUID]

  var input: OrderedJSONObject {
    OrderedJSONObject([(key: "priorSummary", value: .string(priorSummary)), (key: "transcript", value: .string(transcript))])
  }
}

extension ChatConversationWindow {
  /// Folds once the window outgrows the history budget or the verbatim cap; the newest messages stay verbatim, a refused author message is folded
  /// without its text, and the next turn folds what `maxFoldTokens` left.
  // chat-compaction.service.ts:125-136
  func foldPlan(historyBudget: Int = ChatContextAssembler.historyBudget) -> ChatFoldPlan? {
    guard messages.count > ChatFoldPlan.keepVerbatimTurns else { return nil }
    let total = messages.reduce(0) { sum, message in Self.saturatingSum(sum, message.tokens) }
    guard total > historyBudget || messages.count > ChatFoldPlan.maxVerbatimTurns else { return nil }
    var (folded, lines, tokens) = ([ChatWindowMessage](), [String](), 0)
    for message in messages.dropLast(ChatFoldPlan.keepVerbatimTurns) {
      let line = Self.transcriptLine(message)
      let next = Self.saturatingSum(tokens, line.map(countTokens) ?? 0)
      if !folded.isEmpty, next > ChatFoldPlan.maxFoldTokens { break }
      (tokens, folded) = (next, folded + [message])
      if let line { lines.append(line) }
    }
    guard let novel = folded.first?.record.novel else { return nil }
    var covered = summary?.record.covered ?? []
    var seen = Set(covered)
    for id in folded.map(\.record.id) where seen.insert(id).inserted { covered.append(id) }
    return ChatFoldPlan(
      novel: novel, folded: folded, kept: Array(messages.dropFirst(folded.count)), priorSummary: summary?.record.text ?? "none",
      transcript: lines.joined(separator: "\n\n"), covered: covered)
  }

  /// The reference raises a fold for the novel's mode, the turn's, the prior summary's or a folded reply's (chat-compaction.service.ts:138-142); here a
  /// folded author message in unrestricted mode raises it too, and so does a session known to hold unrestricted text. A lock hidden by a fault does not:
  /// everything the fold sends has its own claim.
  func foldMode(_ plan: ChatFoldPlan, turn: ContentMode, novel: ContentMode) -> ContentMode {
    let raised = turn == .unrestricted || novel == .unrestricted || summaryClaimsUnrestricted || plan.folded.contains(where: \.claimsUnrestricted) || lock == .locked
    return raised ? .unrestricted : .standard
  }

  // chat-compaction.service.ts:133-135
  private static func transcriptLine(_ message: ChatWindowMessage) -> String? {
    switch message.role {
    case .assistant: "assistant: \(message.record.content)"
    case .user: message.refusesAuthored ? nil : "user: \(renderTurnContent(message.record.content, contexts: message.record.passageContexts))"
    }
  }

  private static func saturatingSum(_ sum: Int, _ next: Int) -> Int {
    let (result, overflow) = sum.addingReportingOverflow(next)
    guard overflow else { return result }
    return next > 0 ? .max : .min
  }
}
