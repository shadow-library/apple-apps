import Foundation
import ShadowCore
import ShadowStore

/// The chat's context as one turn sends it: `renderedStable` is `ChatRefineRequestParts`' stable context, never empty as the Notebook section is always kept.
// apps/novel-forge-server/src/modules/ai/context/sections.ts:29 (AssembledPack)
struct ChatContextPack: Equatable, Sendable {
  let sections: [ChatPackSection]
  /// The sections not sent: the stable ones the budget dropped, then the volatile ones, then, as `unresolved`, those that could not be read.
  let omitted: [ChatPackOmission]
  /// The sections sent degraded, as `unresolved`: a stand-in for one that could not be read, or one read without some of its records.
  let partial: [ChatPackOmission]
  let budgetTokens: Int
  let usedTokens: Int
  let renderedStable: String
  let renderedVolatile: String

  var rendered: String { joinSections(sections) }
}

enum ChatContextAssembler {
  // context-assembler.service.ts:133-135
  static let historyBudget = 6_000
  static let summaryBudget = 1_500
  static let historyAllowance = historyBudget + summaryBudget + ChatPack.messageAllowance

  /// The parts each section is built from, in the order the reference adds the sections.
  static let sectionParts: [(key: String, parts: Set<ChatContextPart>)] = [
    ("story", [.novel]),
    ("notebook", [.notebook]),
    ("author_notes", [.notes]),
    ("volume_plan", [.volumes]),
    ("promises", [.promises, .volumes, .milestones, .chapters]),
    ("inventory", [.bible, .secrets, .milestones]),
    ("chapter_index", [.chapters]),
    ("handoff", [.chapters]),
    ("prev_ending", [.chapters, .latestEnding]),
    ("pipeline_status", [.chapters]),
    ("changed_since", [.volumes, .chapters, .bible]),
    ("progress", [.progress, .novel]),
  ]

  static let unreadableNotebook =
    "The Notebook could not be read on this device just now, so the author's decisions are missing here. Do not take that to mean nothing is decided: ask before settling anything the author may already have decided."
  static let unreadableHandoff =
    "Where the story stands could not be read on this device just now. Do not take that to mean nothing is written or planned: ask the author before planning or writing a chapter."

  static let incompleteNotebook = "Some of the author's decisions could not be read on this device just now; ask before settling anything they may have decided."

  /// The stable sections are budgeted against a fixed reservation so the cached prefix holds still as the conversation grows; what they keep is pinned, and the
  /// volatile sections take what the request leaves. The required sections are always kept, so a request near the history ceiling may run past the budget.
  // context-assembler.service.ts:858-866
  static func assemble(_ inputs: ChatContextInputs, promptTokens: Int, requestTokens: Int) -> ChatContextPack {
    var unresolved = inputs.unresolved
    let built = sections(inputs.pack, unresolved: &unresolved)
    let unreadable = sectionParts.filter { !$0.parts.isDisjoint(with: unresolved) }.map(\.key)
    let notebookNote = inputs.incomplete.contains(.notebook) && !unresolved.contains(.notebook)
    let stable = built.stable.compactMap { standIn(for: $0, unreadable: unreadable) }.map { notebookNote && $0.key == "notebook" ? noted(inputs.pack.ledger) : $0.asStable }
    let volatile = built.volatile.compactMap { standIn(for: $0, unreadable: unreadable) }

    let stableRoom = max(ChatPack.packFloor, ChatPack.requestBudget - promptTokens - historyAllowance) - ChatPack.packMargin
    let kept = applyBudget(stable, budgetTokens: stableRoom)
    let packRoom = max(ChatPack.packFloor, ChatPack.requestBudget - promptTokens - requestTokens) - ChatPack.packMargin
    let pinned = kept.fitting.map { section -> ChatPackSection in
      var pinned = section
      pinned.required = true
      return pinned
    }
    let budget = max(kept.fitting.reduce(0) { $0 + $1.tokens }, packRoom)
    let final = applyBudget(pinned + volatile, budgetTokens: budget)
    let sent = Set(final.fitting.map { JSString($0.key) })
    let incomplete = sectionParts.filter { !$0.parts.isDisjoint(with: inputs.incomplete) }.map(\.key)
    let absent = unreadable.filter { !sent.contains(JSString($0)) }
    let degraded = sectionParts.map(\.key).filter { key in sent.contains(JSString(key)) && (unreadable + incomplete).contains { $0.jsEquals(key) } }
    let split = splitSegments(final.fitting)
    return ChatContextPack(
      sections: final.fitting, omitted: (kept.omitted + final.omitted).map(ChatPackOmission.init) + absent.map { ChatPackOmission(key: $0, reason: .unresolved) },
      partial: degraded.map { ChatPackOmission(key: $0, reason: .unresolved) }, budgetTokens: budget,
      usedTokens: final.fitting.reduce(0) { $0 + $1.tokens }, renderedStable: split.renderedStable, renderedVolatile: split.renderedVolatile)
  }

  /// The planner's disclosure policy scrubs a previous ending without throwing; were it ever to, nothing could be shown, so every part is reported unreadable.
  private static func sections(_ inputs: ChatPackInputs, unresolved: inout Set<ChatContextPart>) -> ChatPackSections {
    do {
      return try ChatPack.sections(inputs)
    } catch {
      unresolved.formUnion(ChatContextPart.allCases)
      return ChatPackSections(stable: [notebookStandIn], volatile: [handoffStandIn])
    }
  }

  /// The Notebook and the handoff are required, so one that cannot be read stays as a note saying so; any other such section is left out.
  private static func standIn(for section: ChatPackSection, unreadable: [String]) -> ChatPackSection? {
    guard unreadable.contains(where: { $0.jsEquals(section.key) }) else { return section }
    switch section.key {
    case "notebook": return notebookStandIn
    case "handoff": return handoffStandIn
    default: return nil
    }
  }

  private static var notebookStandIn: ChatPackSection {
    ChatPack.capped("notebook", unreadableNotebook, tier: .approvedIntent, cap: ChatPack.Cap.notebook, segment: .stable, required: true)
  }

  /// The Notebook with a closing line saying some entries are missing; the entries make room for it so the cap never cuts it.
  private static func noted(_ ledger: [ChatPackLedgerEntry]) -> ChatPackSection {
    let room = ChatPack.Cap.notebook - countTokens(incompleteNotebook) - countTokens(renderSection("notebook", "")) - ChatPack.sizedSectionMargin
    let body = ChatPack.renderNotebook(ledger, maxTokens: room)
    return ChatPack.capped("notebook", "\(body)\n\n\(incompleteNotebook)", tier: .approvedIntent, cap: ChatPack.Cap.notebook, segment: .stable, required: true)
  }

  private static var handoffStandIn: ChatPackSection {
    ChatPack.capped("handoff", unreadableHandoff, tier: .working, cap: ChatPack.Cap.handoff, segment: .volatile, required: true)
  }
}

extension VaultStore {
  /// The chat context of `novel` from one read of the vault; `since` is when the conversation opened (`ChatContextLoader.sessionOpened`).
  func chatContext(novel: UUID, since: HLCTimestamp?, promptTokens: Int, requestTokens: Int) async throws(StoreError) -> ChatContextPack {
    let inputs = try await read { transaction in try ChatContextLoader.load(novel: novel, since: since, in: transaction) }
    return ChatContextAssembler.assemble(inputs, promptTokens: promptTokens, requestTokens: requestTokens)
  }
}
