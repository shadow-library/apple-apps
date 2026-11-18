import Foundation
import NovelForgeCore
import Observation
import ShadowDesignSystem
import SwiftUI

/// use-revert-flow.tsx and UndoImpactDialog.tsx: what relies on a change, shown before whole proposals, one change or a rollback is undone.
@MainActor
@Observable
final class ChatRevertFlow {
  enum Target: Equatable {
    case proposals([UUID])
    case change(proposal: UUID, index: Int, isIdea: Bool)
    case rollback(after: UUID)
  }

  enum Impact: Equatable {
    case loading
    case loaded(ChatUndoImpact)
    /// RFN_014's `impactUnavailable`: the list cannot be read here, which never blocks the undo.
    case unknown
    case failed(PresentedError)
    /// A rollback walks applies it reads as it goes, so it shows none.
    case notShown
  }

  enum Outcome: Equatable {
    case reverted([UUID])
    case undone(proposal: UUID, index: Int)
    case rolledBack(ChatRollbackResult)
  }

  private(set) var target: Target?
  private(set) var impact = Impact.loading
  private(set) var isRunning = false
  private(set) var notice: ChatCardNotice?
  /// Changes left out of a card that changed since: the author confirms them as never applied before the undo goes ahead (declinedChanged).
  private(set) var changedDeclined: (proposal: UUID, indexes: [Int])?
  /// What the last rollback undid before it stopped, so its caller can say "rolled back N, then stopped".
  private(set) var rolledBack: ChatRollbackResult?
  var ideaScope = LedgerRejectionScope.notNow
  @ObservationIgnored var onFinished: (Outcome) -> Void = { _ in }
  /// Set by an owner that runs a `.change` itself, to chain the changes that rely on it; the flow then only collects the idea's scope.
  @ObservationIgnored var undoChange: ((_ index: Int, _ scope: LedgerRejectionScope) async -> Void)?
  /// The apply a rollback stopped at for changes left out of it, reverted alone once the author accepts them.
  @ObservationIgnored private var rollbackStop: UUID?
  @ObservationIgnored private var accepting: [UUID: Set<Int>] = [:]
  /// Proposals of this target already reverted, so a retry after a refusal goes on from the one that refused.
  @ObservationIgnored private var reverted: [UUID] = []
  @ObservationIgnored private var impactTicket = 0
  private let novel: UUID
  private let writer: any ChatProposalWriting

  init(novel: UUID, writer: any ChatProposalWriting) {
    self.novel = novel
    self.writer = writer
  }

  var isPresented: Bool {
    get { target != nil }
    set { if !newValue { cancel() } }
  }

  var canConfirm: Bool {
    guard target != nil, !isRunning, changedDeclined == nil else { return false }
    switch impact {
    case .loaded, .unknown, .notShown: return true
    case .loading, .failed: return false
    }
  }

  func open(_ target: Target) {
    guard !isRunning else { return }
    self.target = target
    notice = nil
    changedDeclined = nil
    accepting = [:]
    reverted = []
    rolledBack = nil
    rollbackStop = nil
    ideaScope = .notNow
    loadImpact()
  }

  func retryImpact() {
    loadImpact()
  }

  func cancel() {
    guard !isRunning else { return }
    impactTicket += 1
    target = nil
    changedDeclined = nil
    notice = nil
  }

  func confirm() async {
    guard let target, canConfirm else { return }
    if case .change(_, let index, let isIdea) = target, let undoChange {
      self.target = nil
      await undoChange(index, isIdea ? ideaScope : .notNow)
      return
    }
    isRunning = true
    notice = nil
    defer { isRunning = false }
    do throws(ChatCardRefusal) {
      let outcome = try await run(target)
      self.target = nil
      onFinished(outcome)
    } catch {
      refused(error)
    }
  }

  /// The author treats the changed changes as never applied; the undo runs again with them accepted.
  func acceptChangedDeclined() async {
    guard let changedDeclined else { return }
    accepting[changedDeclined.proposal, default: []].formUnion(changedDeclined.indexes)
    self.changedDeclined = nil
    await confirm()
  }

  func keepChangedDeclined() {
    changedDeclined = nil
  }

  private func run(_ target: Target) async throws(ChatCardRefusal) -> Outcome {
    switch target {
    case .proposals(let proposals):
      for proposal in proposals where !reverted.contains(proposal) {
        do throws(ChatCardRefusal) {
          _ = try await writer.revert(proposal, accepting: accepting[proposal] ?? [], novel: novel)
          reverted.append(proposal)
        } catch {
          if error.code == Self.declinedChanged { changedDeclined = (proposal, error.indexes) }
          throw error
        }
      }
      return .reverted(proposals)
    case .change(let proposal, let index, let isIdea):
      do throws(ChatCardRefusal) {
        _ = try await writer.undo(proposal, index: index, idea: isIdea ? ideaScope : nil, accepting: accepting[proposal] ?? [], novel: novel)
      } catch {
        if error.code == Self.declinedChanged { changedDeclined = (proposal, error.indexes) }
        throw error
      }
      return .undone(proposal: proposal, index: index)
    case .rollback(let anchor):
      var alone = [UUID]()
      if let stopped = rollbackStop {
        do throws(ChatCardRefusal) {
          _ = try await writer.revert(stopped, accepting: accepting[stopped] ?? [], novel: novel)
        } catch {
          if error.code == Self.declinedChanged { changedDeclined = (stopped, error.indexes) }
          throw error
        }
        alone.append(stopped)
        rollbackStop = nil
      }
      let result = try await writer.rollback(after: anchor, novel: novel)
      let total = ChatRollbackResult(
        reverted: (rolledBack?.reverted ?? []) + alone + result.reverted, skipped: result.skipped, stoppedAt: result.stoppedAt, refusal: result.refusal)
      rolledBack = total
      guard let refusal = result.refusal else { return .rolledBack(total) }
      if refusal.code == Self.declinedChanged, let stopped = result.stoppedAt {
        rollbackStop = stopped
        changedDeclined = (stopped, refusal.indexes)
      }
      throw refusal
    }
  }

  private func refused(_ refusal: ChatCardRefusal) {
    guard refusal.code != Self.declinedChanged else { return }
    notice = ChatCardNotice(error: ChatCardsErrors.presented(refusal, during: .revert))
  }

  private func loadImpact() {
    impactTicket += 1
    let ticket = impactTicket
    guard let target else { return }
    let requests: [(UUID, Int?)]
    switch target {
    case .proposals(let proposals): requests = proposals.map { ($0, nil) }
    case .change(let proposal, let index, _): requests = [(proposal, index)]
    case .rollback:
      impact = .notShown
      return
    }
    impact = .loading
    let (writer, novel) = (writer, novel)
    Task {
      var impacts = [ChatUndoImpact]()
      var unknown = false
      for (proposal, index) in requests {
        do throws(ChatCardRefusal) {
          impacts.append(try await writer.impact(of: proposal, index: index, novel: novel))
        } catch  where error.code == Self.impactUnavailable {
          unknown = true
        } catch {
          guard ticket == impactTicket else { return }
          impact = .failed(ChatCardsErrors.presented(error, during: .impact))
          return
        }
      }
      guard ticket == impactTicket else { return }
      impact = unknown ? .unknown : .loaded(ChatUndoImpact.merged(impacts))
    }
  }

  private static let declinedChanged = "refinement.declined_changed"
  private static let impactUnavailable = "refinement.impact_unavailable"
}

/// apps/novel-forge-web/src/features/chat/chat-view.ts:177-197
nonisolated struct ChatUndoImpactText: Equatable {
  let counts: [String]
  let rows: [Row]
  let finalNote: String?
  let unreadableNote: String?

  struct Row: Equatable, Identifiable {
    let id: String
    let label: String
    let isFinal: Bool
  }

  init(_ impact: ChatUndoImpact) {
    var kinds = [String]()
    for dependent in impact.dependents where !kinds.contains(dependent.kind) { kinds.append(dependent.kind) }
    counts = kinds.map { kind in Self.counted(impact.dependents.count { $0.kind == kind }, kind: kind) }
    rows = impact.dependents.map { Row(id: "\($0.kind):\($0.ref)", label: Self.label($0.ref, chapter: $0.chapter), isFinal: $0.isFinal) }
    finalNote =
      impact.finalUnaffected > 0
      ? String(localized: "\(impact.finalUnaffected) final chapters and plans also rely on it and stay as they are.", table: "ChatCards") : nil
    unreadableNote =
      impact.unreadable > 0
      ? String(localized: "\(impact.unreadable) records can't be read on this device, so this list may be missing what relies on them.", table: "ChatCards") : nil
  }

  var isEmpty: Bool { rows.isEmpty && finalNote == nil && unreadableNote == nil }

  private static func counted(_ count: Int, kind: String) -> String {
    switch kind {
    case "plan": String(localized: "\(count) chapter plans", table: "ChatCards")
    case "draft": String(localized: "\(count) drafts", table: "ChatCards")
    case "knowledge": String(localized: "\(count) things characters know", table: "ChatCards")
    case "suggestion": String(localized: "\(count) waiting suggestions", table: "ChatCards")
    default: "\(count) \(kind)"
    }
  }

  // chat-view.ts:186-192
  private static func label(_ ref: String, chapter: Int?) -> String {
    let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
    let rest = parts.count > 1 ? parts[1] : ""
    switch parts.first {
    case "chapter": return String(localized: "Chapter \(rest) plan", table: "ChatCards")
    case "draft": return String(localized: "Chapter \(rest) draft", table: "ChatCards")
    case "knowledge":
      let pair = rest.split(separator: "/", maxSplits: 1).map(String.init)
      let knows = pair.count > 1 ? String(localized: "\(pair[0]) knows \(pair[1])", table: "ChatCards") : rest
      guard let chapter, chapter > 0 else { return knows }
      return String(localized: "\(knows) (since chapter \(chapter))", table: "ChatCards")
    case "proposal": return String(localized: "A suggestion waiting for you", table: "ChatCards")
    default: return ref
    }
  }
}

struct ChatRevertSheet: View {
  @Bindable var flow: ChatRevertFlow

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      impactBody
      if case .change(_, _, true) = flow.target { ideaChoice }
      if let changed = flow.changedDeclined { changedDeclinedPrompt(changed.indexes) }
      if let notice = flow.notice {
        ShadowCallout(Text(verbatim: notice.error.headline), message: notice.error.detail.map { Text(verbatim: $0) }, intent: .danger) { EmptyView() }
      }
    }
    .padding(Spacing.space4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowSheetHeader(
      title, subtitle: subtitle, cancel: ShadowSheetCancel(Text("Keep It", tableName: "ChatCards"), isDisabled: flow.isRunning) { flow.cancel() },
      confirm: ShadowSheetConfirm(confirmTitle, systemImage: "arrow.uturn.backward", isDisabled: !flow.canConfirm, submitShortcut: true) {
        Task { await flow.confirm() }
      }
    )
    .shadowSheetStyle(.form)
    .shadowFittedDetents()
    .interactiveDismissDisabled(flow.isRunning)
  }

  private var title: Text {
    guard case .rollback = flow.target else { return Text("Undo this change?", tableName: "ChatCards") }
    return Text("Undo everything after this?", tableName: "ChatCards")
  }

  private var subtitle: Text {
    guard case .rollback = flow.target else {
      return Text("Everything listed in this change is taken back out of your story. Final chapters are never rewritten.", tableName: "ChatCards")
    }
    return Text("Every change applied after this one is undone, newest first. Final chapters are never rewritten.", tableName: "ChatCards")
  }

  private var confirmTitle: Text {
    guard case .rollback = flow.target else { return Text("Undo This Change", tableName: "ChatCards") }
    return Text("Undo Them", tableName: "ChatCards")
  }

  @ViewBuilder
  private var impactBody: some View {
    switch flow.impact {
    case .loading:
      HStack(spacing: Spacing.space2) {
        ProgressView().controlSize(.small)
        Text("Checking what relies on this change…", tableName: "ChatCards")
      }
      .shadowFont(.body)
      .foregroundStyle(ShadowColor.textSecondary)
    case .failed(let error):
      ShadowCallout(Text("Couldn't check what relies on this change", tableName: "ChatCards"), message: error.text, intent: .danger) {
        Button {
          flow.retryImpact()
        } label: {
          Text("Try Again", tableName: "ChatCards")
        }
      }
    case .unknown:
      ShadowCallout(
        Text("What relies on this change can't be read on this device right now", tableName: "ChatCards"),
        message: Text("You can still undo it.", tableName: "ChatCards"), intent: .warning
      ) { EmptyView() }
    case .notShown:
      EmptyView()
    case .loaded(let impact):
      impactList(ChatUndoImpactText(impact))
    }
  }

  @ViewBuilder
  private func impactList(_ text: ChatUndoImpactText) -> some View {
    if text.isEmpty {
      Text("Nothing else relies on it yet. Undoing removes only what was added.", tableName: "ChatCards").shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
    } else {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        if !text.counts.isEmpty {
          let counts = text.counts.joined(separator: " · ")
          Text("Relies on it: \(counts).", tableName: "ChatCards").shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
        }
        ForEach(text.rows) { row in
          HStack(alignment: .firstTextBaseline) {
            Text(verbatim: row.label).shadowFont(.callout).foregroundStyle(ShadowColor.textPrimary)
            Spacer(minLength: Spacing.space2)
            Group {
              if row.isFinal {
                Text("final, stays as it is", tableName: "ChatCards")
              } else {
                Text("marked to review", tableName: "ChatCards")
              }
            }
            .shadowFont(.caption)
            .foregroundStyle(ShadowColor.textSecondary)
          }
        }
        ForEach([text.finalNote, text.unreadableNote].compactMap(\.self), id: \.self) { note in
          Text(verbatim: note).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }

  // chat-view.ts:290-294: an undone idea is turned down in the Notebook, for now unless the author says otherwise
  private var ideaChoice: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Should it be suggested again?", tableName: "ChatCards").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Picker(selection: $flow.ideaScope) {
        Text("Not now, maybe later", tableName: "ChatCards").tag(LedgerRejectionScope.notNow)
        Text("Never", tableName: "ChatCards").tag(LedgerRejectionScope.never)
        Text("Not for this version", tableName: "ChatCards").tag(LedgerRejectionScope.notThisVersion)
      } label: {
        Text("Suggest it again", tableName: "ChatCards")
      }
      .pickerStyle(.inline)
      .labelsHidden()
      .disabled(flow.isRunning)
    }
  }

  private func changedDeclinedPrompt(_ indexes: [Int]) -> some View {
    ShadowCallout(
      Text("Some changes left out of this card have changed since", tableName: "ChatCards"),
      message: Text("They may be your own edits, or another device's changes still arriving. Undo anyway, treating them as never applied?", tableName: "ChatCards"),
      intent: .warning
    ) {
      HStack(spacing: Spacing.space2) {
        Button {
          Task { await flow.acceptChangedDeclined() }
        } label: {
          Text("Undo Anyway", tableName: "ChatCards")
        }
        Button {
          flow.keepChangedDeclined()
        } label: {
          Text("Not Now", tableName: "ChatCards")
        }
      }
      .disabled(flow.isRunning)
    }
  }
}

extension View {
  /// Presents the flow's undo-impact sheet while it has a target.
  func chatRevertFlow(_ flow: ChatRevertFlow) -> some View {
    sheet(isPresented: Binding(get: { flow.isPresented }, set: { flow.isPresented = $0 })) { ChatRevertSheet(flow: flow) }
  }
}
