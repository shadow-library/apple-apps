import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// What the chapter offers (apps/novel-forge-web/src/lib/chapter-workspace.ts:25-40, chapter-checks.ts:216-219, 264-272 and use-override-confirm.tsx:13-36):
/// approve while it is neither being written nor approved, as written while it is out of date, after confirming an override of the blocking findings still
/// open; finalize once approved, always through the review of its Story Bible updates.
struct FinalizeOffer: Equatable {
  enum Approve: Equatable {
    case none
    case standard
    case asWritten(StaleCause)
    /// A judge's conflict with no finding to override: the AI review turns it into findings first.
    case refused
  }

  /// The open blocking findings an approval records as overridden, through the lifecycle's count in readiness.
  enum Held: Equatable {
    case loading
    /// Readiness cannot be read now, so the count is not known.
    case unknown
    case count(Int)

    init(_ readiness: Loadable<FinalizeReadiness>) {
      switch readiness {
      case .loading: self = .loading
      case .failed: self = .unknown
      case .loaded(let readiness):
        guard let blockers = readiness.blockers.value else {
          self = .unknown
          return
        }
        self = .count(blockers.lazy.compactMap { if case .openBlockingFindings(_, let count) = $0 { count } else { nil } }.first ?? 0)
      }
    }
  }

  enum Confirmation: Equatable {
    case none
    case overriding(Int)
    /// Readiness cannot say how many findings are open, so approving confirms in words that name no count.
    case overridingUnknown
  }

  let approve: Approve
  let held: Held
  let finalize: Bool
  let final: Bool

  init(row: ChapterRow?, held: Held) {
    self.init(stage: row?.stage, review: row?.review, stale: row?.stale, held: held)
  }

  init(stage: ChapterStage?, review: DraftReviewState?, stale: StaleCause?, held: Held) {
    self.held = held
    guard let stage, stage != .final else {
      (approve, finalize, final) = (.none, false, stage == .final)
      return
    }
    final = false
    finalize = review == .approved
    if review == .generating || review == .approved {
      approve = .none
    } else if review == .contradiction && held == .count(0) {
      approve = .refused
    } else {
      approve = stale.map(Approve.asWritten) ?? .standard
    }
  }

  /// Approve waits for readiness, so an override is never sent unconfirmed while the count is still loading.
  var canApprove: Bool {
    switch approve {
    case .standard, .asWritten: held != .loading
    case .none, .refused: false
    }
  }

  var confirmation: Confirmation {
    switch held {
    case .loading, .count(0): .none
    case .count(let count): .overriding(count)
    case .unknown: .overridingUnknown
    }
  }

  var staleCause: StaleCause? {
    guard case .asWritten(let cause) = approve else { return nil }
    return cause
  }
}

/// The two-sets notices this device's author acknowledged, by chapter and the losing finalizes they listed: a later loss shows the notice again.
struct FinalizeAcknowledgements {
  static let key = "com.shadow.apps.novelforge.finalize.acknowledged-two-sets"

  let defaults: UserDefaults

  /// This device's, or the demo's in its own defaults.
  static func device(isDemo: Bool) -> FinalizeAcknowledgements {
    FinalizeAcknowledgements(defaults: isDemo ? DemoDefaults.suite(for: .novelForge) : .standard)
  }

  func isAcknowledged(_ sets: FinalizePresentation.TwoSets, novel: UUID, chapter: Int) -> Bool {
    (defaults.stringArray(forKey: Self.key) ?? []).contains(Self.entry(sets, novel: novel, chapter: chapter))
  }

  func acknowledge(_ sets: FinalizePresentation.TwoSets, novel: UUID, chapter: Int) {
    let entry = Self.entry(sets, novel: novel, chapter: chapter)
    let kept = (defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.hasPrefix(Self.prefix(novel: novel, chapter: chapter)) }
    defaults.set(kept + [entry], forKey: Self.key)
  }

  private static func prefix(novel: UUID, chapter: Int) -> String { "\(novel.uuidString.lowercased())/\(chapter)/" }

  private static func entry(_ sets: FinalizePresentation.TwoSets, novel: UUID, chapter: Int) -> String { prefix(novel: novel, chapter: chapter) + sets.id }
}

/// apps/novel-forge-web/src/features/chapter-workspace/FinalizeButton.tsx:15-46 with the header's Approve (chapters/ChapterWorkspace.tsx:150-172, 348-355):
/// Approve, or Finalize with readiness' blockers in order; finalize always opens the review. A final chapter keeps its updates reachable only when two
/// devices finalized it with different ones.
struct ChapterFinalizeBar: View {
  let context: NovelContext
  let chapter: Int
  let row: ChapterRow?
  /// The head revision on screen: the text an approval says the author read.
  let revision: String?
  @State private var model: FinalizeModel
  @State private var screen = ReadObserver<FinalizeReviewScreen>()
  @State private var readiness = ReadObserver<FinalizeReadiness>()
  @State private var reviewing = false
  @State private var confirming: FinalizeOffer.Confirmation?
  @State private var acknowledged = false

  @Environment(AIServices.self) private var services

  private var acknowledgements: FinalizeAcknowledgements { .device(isDemo: services.isDemo) }

  init(context: NovelContext, chapter: Int, row: ChapterRow?, revision: String?) {
    self.context = context
    self.chapter = chapter
    self.row = row
    self.revision = revision
    _model = State(initialValue: FinalizeModel(store: context.store, novel: context.novel, chapter: chapter))
  }

  init(context: NovelContext, content: ChapterContent) {
    let revision: String? = if case .draft(let draft) = content.body { draft.revision } else { nil }
    self.init(context: context, chapter: content.chapter, row: content.row, revision: revision)
  }

  var body: some View {
    let offer = FinalizeOffer(row: row, held: FinalizeOffer.Held(readiness.state))
    let presentation = screen.state.value.map { FinalizePresentation(screen: $0, readiness: readiness.state.value) }
    VStack(alignment: .leading, spacing: Spacing.space3) {
      actions(offer, twoSets: presentation?.twoSets != nil)
      if offer.held == .unknown && offer.canApprove {
        note(Text("Open blocking findings can't be counted on this device right now.", tableName: "Finalize"))
      }
      if offer.finalize, let presentation { finalizeState(presentation) }
      if offer.final, let sets = presentation?.twoSets, !acknowledged, !acknowledgements.isAcknowledged(sets, novel: context.novel, chapter: chapter) {
        FinalizeTwoSetsNotice(chapter: chapter, sets: sets) {
          acknowledgements.acknowledge(sets, novel: context.novel, chapter: chapter)
          acknowledged = true
        }
      }
      if let approved = model.approved { approvedNotice(approved) }
      if let refusal = model.refusal { ShadowCallout(Text("Couldn't approve", tableName: "Finalize"), message: refusal.text, intent: .danger) { EmptyView() } }
    }
    .task {
      let (store, query) = (context.store, FinalizeReviewScreenQuery(novel: context.novel, chapter: chapter))
      await screen.run { store.observe(FinalizeReviewScreen.self, query) }
    }
    .task {
      let (store, query) = (context.store, FinalizeReadinessQuery(novel: context.novel, chapter: chapter))
      await readiness.run { store.observe(FinalizeReadiness.self, query) }
    }
    .onChange(of: presentation?.twoSets?.id) { acknowledged = false }
    .onChange(of: model.reconfirm) {
      guard let open = model.reconfirm else { return }
      model.reconfirm = nil
      confirming = .overriding(open)
    }
    .sheet(isPresented: $reviewing) { FinalizeReviewDialog(context: context, chapter: chapter) }
    .confirmationDialog(confirmTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { confirmation in
      Button(role: .destructive) {
        Task { await approve(offer, overriding: confirmation) }
      } label: {
        Text("Approve and Override", tableName: "Finalize")
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Finalize")
      }
    } message: { confirmation in
      // chapter-checks.ts:269-272
      switch confirmation {
      case .overriding(let count):
        Text("Approving records \(count) blocking findings as overridden, including any you marked “I'll fix it myself”.", tableName: "Finalize")
      case .overridingUnknown, .none:
        Text("Approving records every blocking finding still open as overridden, including any you marked “I'll fix it myself”.", tableName: "Finalize")
      }
    }
  }

  private var isConfirming: Binding<Bool> {
    Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
  }

  // use-override-confirm.tsx:26
  private var confirmTitle: Text {
    guard case .overriding(let count) = confirming else { return Text("Approve over the blocking findings still open?", tableName: "Finalize") }
    return Text("Approve over \(count) blocking findings?", tableName: "Finalize")
  }

  @ViewBuilder
  private func actions(_ offer: FinalizeOffer, twoSets: Bool) -> some View {
    HStack(spacing: Spacing.space2) {
      switch offer.approve {
      case .none:
        EmptyView()
      case .standard, .asWritten:
        Button {
          let confirmation = offer.confirmation
          if confirmation == .none { Task { await approve(offer, overriding: .none) } } else { confirming = confirmation }
        } label: {
          if case .asWritten = offer.approve { Text("Approve as Written", tableName: "Finalize") } else { Text("Approve", tableName: "Finalize") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(revision == nil || model.approving || !offer.canApprove)
        .accessibilityIdentifier("approve-chapter")
      case .refused:
        note(Text("Run the AI review first: it turns the judge's conflict into findings you can fix, dismiss or override.", tableName: "Finalize"))
      }
      if offer.finalize {
        Button {
          reviewing = true
        } label: {
          Text("Finalize · Review Story Bible Updates", tableName: "Finalize")
        }
        .buttonStyle(.borderedProminent)
      }
      if offer.final && twoSets {
        Button {
          reviewing = true
        } label: {
          Text("Story Bible Updates", tableName: "Finalize")
        }
        .buttonStyle(.bordered)
      }
    }
  }

  @ViewBuilder
  private func finalizeState(_ presentation: FinalizePresentation) -> some View {
    if let message = presentation.unavailableMessage { note(Text(verbatim: message)) }
    if !presentation.blockers.isEmpty { FinalizeBlockerList(chapter: chapter, blockers: presentation.blockers) }
    if presentation.phase == .preparing {
      if presentation.finalizesOnItsOwn {
        note(Text("Its Story Bible updates are being read. If nothing needs your call, the chapter becomes final on its own.", tableName: "Finalize"))
      } else {
        note(Text("Its Story Bible updates are being read. This chapter is isolated, so it becomes final only when you finalize it.", tableName: "Finalize"))
      }
    }
  }

  // chapter-checks.ts:274-278
  private func approvedNotice(_ approved: FinalizeModel.Approved) -> some View {
    Group {
      if approved.overridden == 0 {
        ShadowCallout(Text("Chapter \(chapter) approved", tableName: "Finalize"), intent: .success) { EmptyView() }
      } else {
        ShadowCallout(
          Text("Chapter \(chapter) approved", tableName: "Finalize"),
          message: Text("\(approved.overridden) blocking findings were recorded as overridden.", tableName: "Finalize"), intent: .warning
        ) { EmptyView() }
      }
    }
    .accessibilityIdentifier("chapter-approved")
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
  }

  private func approve(_ offer: FinalizeOffer, overriding: FinalizeOffer.Confirmation) async {
    guard let revision else { return }
    await model.approve(revision: revision, stale: offer.staleCause, overriding: overriding)
  }
}
