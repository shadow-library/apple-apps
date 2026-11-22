import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/features/plan-card/PlanCard.tsx:112-571, read only: the `brief.update` a chapter_plan card proposes, saved with the card's own
/// apply and discard. Not ported: editing the card before it is saved (the card is first-writer-wins; proposal.service.ts:317 has no native counterpart),
/// the content-mode choice, the pooling actions, and planCardDiagnostics (plan-diagnostics.ts), which G23 stages without.
struct ChatPlanCard: View {
  let model: ChatProposalCardModel
  let presenter: ChatCardsPresenter
  @State private var labels = ReadObserver<PlanCardLabels>()
  @Environment(AdultConfirmationModel.self) private var adult
  @Environment(AIServices.self) private var services

  var body: some View {
    Group {
      if let plan = PlanCardContent(model.ops) {
        content(plan, labels: currentLabels)
      } else {
        ShadowContentUnavailable(
          Text("No chapter plan here", tableName: "PlanCard"), systemImage: "list.bullet.rectangle",
          message: Text("This card holds no plan to show. Plan the next chapter again.", tableName: "PlanCard"))
      }
    }
    .task(id: PlanCardContent(model.ops)?.chapter) {
      guard let chapter = PlanCardContent(model.ops)?.chapter else { return }
      let (store, novel) = (model.context.store, model.context.novel)
      await labels.run { store.observeReads { transaction in try PlanCardLabels.load(novel: novel, chapter: chapter, in: transaction) } }
    }
  }

  private var currentLabels: PlanCardLabels {
    switch labels.state {
    case .loading: PlanCardLabels()
    case .loaded(let labels): labels
    case .failed: PlanCardLabels(isUnavailable: true)
    }
  }

  private func content(_ plan: PlanCardContent, labels: PlanCardLabels) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      header(plan)
      if let notice = model.notice.map(PlanCardErrors.notice) {
        ShadowCallout(Text(verbatim: notice.title), message: notice.message.map { Text(verbatim: $0) }, intent: .danger) { EmptyView() }
      }
      if model.status == .conflicted && model.notice == nil {
        Text(verbatim: ChatCardsErrors.conflicted).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      recap(plan)
      field(Text("Title", tableName: "PlanCard"), plan.title)
      field(Text("What this chapter does", tableName: "PlanCard"), plan.purpose)
      scenes(plan, labels: labels)
      field(Text("Told mainly by", tableName: "PlanCard"), plan.pov.map(labels.name))
      ending(plan.ending)
      milestones(plan, labels: labels)
      contentMode(plan.contentMode)
      writer(plan, labels: labels)
      warnings
      actions(plan)
    }
  }

  private func header(_ plan: PlanCardContent) -> some View {
    HStack(spacing: Spacing.space2) {
      Image(systemName: "list.bullet.rectangle").foregroundStyle(ShadowColor.accentText)
      Text("Chapter \(plan.chapter) plan", tableName: "PlanCard").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      status(plan)
      Spacer(minLength: Spacing.space2)
      if let words = plan.roundedWords {
        Text("About \(words.formatted()) words", tableName: "PlanCard").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  // PlanCard.tsx:89-96, 220-224
  @ViewBuilder
  private func status(_ plan: PlanCardContent) -> some View {
    switch model.status {
    case .pending where plan.startedEmpty: ShadowBadge(Text("Your plan — nothing filled in for you", tableName: "PlanCard"), intent: .neutral)
    case .pending: ShadowBadge(Text("Draft", tableName: "PlanCard"), intent: .warning)
    case .applied: ShadowBadge(Text("Plan saved", tableName: "PlanCard"), intent: .success)
    case .discarded: ShadowBadge(Text("Discarded", tableName: "PlanCard"), intent: .neutral)
    case .superseded: ShadowBadge(Text("Replaced by a newer plan", tableName: "PlanCard"), intent: .neutral)
    case .conflicted: ShadowBadge(Text("Out of date", tableName: "PlanCard"), intent: .danger)
    case .reverted: ShadowBadge(Text("Undone", tableName: "PlanCard"), intent: .neutral)
    case .absent, .unknown: EmptyView()
    }
  }

  // PlanCard.tsx:289-294
  @ViewBuilder
  private func recap(_ plan: PlanCardContent) -> some View {
    if plan.direction != nil || plan.rationale != nil {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        if let direction = plan.direction {
          Text("Direction: \(direction)", tableName: "PlanCard").shadowFont(.callout).foregroundStyle(ShadowColor.textPrimary)
        }
        if let rationale = plan.rationale {
          Text(verbatim: rationale).shadowFont(.callout).italic().foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .textSelection(.enabled)
    }
  }

  // PlanCard.tsx:310-336, 632-697
  private func scenes(_ plan: PlanCardContent, labels: PlanCardLabels) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label(Text("Scenes · who tells each one", tableName: "PlanCard"))
      if plan.scenes.isEmpty {
        hint(Text("No scenes yet.", tableName: "PlanCard"))
      }
      ForEach(Array(plan.scenes.enumerated()), id: \.offset) { index, scene in
        PlanSceneRow(number: index + 1, scene: scene, teller: scene.pov.map(labels.name))
      }
    }
  }

  // PlanCard.tsx:388-441
  @ViewBuilder
  private func ending(_ ending: PlanCardContent.Ending) -> some View {
    field(Text("Ends on", tableName: "PlanCard"), ending.handoff)
    field(Text("Kind of ending", tableName: "PlanCard"), ending.hook.flatMap(PlanCardContent.hookLabel))
    field(Text("What the reader feels on the last line", tableName: "PlanCard"), ending.beat)
    field(Text("The question it leaves open", tableName: "PlanCard"), ending.question)
  }

  // PlanCard.tsx:443-468
  private func milestones(_ plan: PlanCardContent, labels: PlanCardLabels) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label(Text("This chapter reaches", tableName: "PlanCard"))
      if !plan.milestones.isEmpty {
        ShadowFlowLayout {
          ForEach(plan.milestones, id: \.self) { key in
            ShadowTag(Text("Milestone: \(labels.milestone(key))", tableName: "PlanCard"))
          }
        }
        hint(Text("Provisional until you finalize chapter \(plan.chapter) — rewrite the chapter without it and it goes back to open.", tableName: "PlanCard"))
      } else {
        hint(Text("No milestone claimed — nothing unlocks in this chapter.", tableName: "PlanCard"))
      }
    }
  }

  @ViewBuilder
  private func contentMode(_ mode: PlanCardContent.Mode?) -> some View {
    switch mode {
    case .standard?: field(Text("Content for this chapter", tableName: "PlanCard"), String(localized: "Standard", table: "PlanCard"))
    case .unrestricted?:
      field(Text("Content for this chapter", tableName: "PlanCard"), String(localized: "Unrestricted", table: "PlanCard"))
      hint(unrestrictedNote)
    case .novel?: field(Text("Content for this chapter", tableName: "PlanCard"), String(localized: "Follows the novel's setting", table: "PlanCard"))
    case nil: EmptyView()
    }
  }

  private var unrestrictedNote: Text {
    guard UnrestrictedWriting.isAvailable else { return PlanCardContent.unrestrictedUnavailableNote }
    switch (services.settings.assignments.hasUnrestrictedModel, adult.isConfirmed) {
    case (true, true): return PlanCardContent.unrestrictedNote
    case (true, false): return PlanCardContent.unrestrictedAgeNote
    case (false, true): return PlanCardContent.unrestrictedModelNote
    case (false, false): return PlanCardContent.unrestrictedModelAndAgeNote
    }
  }

  // PlanCard.tsx:493-524, ChatPlanCard.tsx:60
  private func writer(_ plan: PlanCardContent, labels: PlanCardLabels) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        label(Text("What the writer gets", tableName: "PlanCard"))
        hint(Text("Pages picked from your Story Bible", tableName: "PlanCard"))
      }
      hint(PlanCardContent.alwaysSent)
      if plan.contextRefs.isEmpty {
        hint(Text("No pages picked — the writer gets only what is always sent.", tableName: "PlanCard"))
      } else {
        ShadowFlowLayout {
          ForEach(plan.contextRefs, id: \.self) { ref in
            ShadowTag(Text(verbatim: labels.ref(ref)))
          }
        }
      }
      let kept = plan.keptBack(chapterIsEnding: labels.chapterIsEnding).joined(separator: ", ")
      hint(
        Text(
          "Kept from the writer: \(kept). You can't add these here; a locked secret goes in only once its conditions are met. The Writer's view shows exactly what was sent.",
          tableName: "PlanCard"))
    }
  }

  // PlanCard.tsx:361-367
  @ViewBuilder
  private var warnings: some View {
    let warnings = model.snapshot?.card?.warnings ?? []
    if !warnings.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        label(Text("Other things to look at", tableName: "PlanCard"))
        ForEach(warnings, id: \.self) { warning in
          Label {
            Text(verbatim: warning)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.warningText)
        }
      }
    }
  }

  // PlanCard.tsx:527-568
  @ViewBuilder
  private func actions(_ plan: PlanCardContent) -> some View {
    if model.canDiscard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        HStack(spacing: Spacing.space2) {
          if model.isPending {
            Button {
              Task { await model.apply() }
            } label: {
              Text("Save Plan", tableName: "PlanCard")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSavePlan)
          }
          Button {
            presenter.discarding = model
          } label: {
            Text("Discard", tableName: "PlanCard")
          }
          .buttonStyle(.bordered)
          if model.isBusy { ProgressView().controlSize(.small) }
        }
        if model.isPending && plan.isBlank {
          hint(Text("Give it a title and at least one scene first", tableName: "PlanCard"))
        }
      }
    }
  }

  @ViewBuilder
  private func field(_ title: Text, _ value: String?) -> some View {
    if let value {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        label(title)
        Text(verbatim: value).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
      }
    }
  }

  private func label(_ text: Text) -> some View {
    text.shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
  }

  private func hint(_ text: Text) -> some View {
    text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
  }
}

/// PlanCard.tsx:632-697: a scene's summary and who tells it, with its goal, obstacle, turn, beats and length behind a disclosure.
private struct PlanSceneRow: View {
  let number: Int
  let scene: PlanCardContent.Scene
  let teller: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
      Text(verbatim: "\(number)").shadowFont(.callout).monospacedDigit().foregroundStyle(ShadowColor.textTertiary)
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(verbatim: scene.summary).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
        if let teller {
          Text("Told by \(teller)", tableName: "PlanCard").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        } else {
          Text("No point of view yet", tableName: "PlanCard").shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
        }
        if scene.detailCount > 0 || scene.words != nil {
          DisclosureGroup {
            details
          } label: {
            Text("Goal, obstacle and beats · \(scene.detailCount) filled", tableName: "PlanCard").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      detail(Text("What they want", tableName: "PlanCard"), scene.goal)
      detail(Text("What stands in the way", tableName: "PlanCard"), scene.obstacle)
      detail(Text("How it stands when the scene ends", tableName: "PlanCard"), scene.turn)
      detail(Text("Beats", tableName: "PlanCard"), scene.beats.isEmpty ? nil : scene.beats.map { "• \($0)" }.joined(separator: "\n"))
      detail(Text("Words for this scene", tableName: "PlanCard"), scene.words.map { $0.formatted() })
    }
    .padding(.top, Spacing.space1)
  }

  @ViewBuilder
  private func detail(_ title: Text, _ value: String?) -> some View {
    if let value {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        title.shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
        Text(verbatim: value).shadowFont(.callout).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
      }
    }
  }
}

/// The plan a card proposes, read from its first `brief.update` that names a chapter (apps/novel-forge-web/src/lib/plan-card.ts:100-165).
nonisolated struct PlanCardContent: Equatable, Sendable {
  struct Scene: Equatable, Sendable {
    let summary: String
    let pov: String?
    let goal: String?
    let obstacle: String?
    let turn: String?
    let beats: [String]
    let words: Int?

    // PlanCard.tsx:633
    var detailCount: Int { [goal, obstacle, turn].count { $0 != nil } + (beats.isEmpty ? 0 : 1) }
  }

  struct Ending: Equatable, Sendable {
    let hook: String?
    let handoff: String?
    let beat: String?
    let question: String?
  }

  enum Mode: Equatable, Sendable {
    case standard
    case unrestricted
    /// The card sets the chapter back to following the novel.
    case novel
  }

  let chapter: Int
  let title: String?
  let purpose: String?
  let pov: String?
  let scenes: [Scene]
  let ending: Ending
  let milestones: [String]
  let contextRefs: [String]
  let rationale: String?
  let direction: String?
  let contentMode: Mode?
  let startedEmpty: Bool
  let isEnding: Bool

  init?(_ ops: [ChatOp]) {
    guard let op = ops.first(where: { $0.type == "brief.update" && $0.fields["chapter"]?.intValue != nil }), let chapter = op.fields["chapter"]?.intValue else { return nil }
    let fields = op.fields
    self.chapter = Int(chapter)
    title = Self.text(fields["title"])
    purpose = Self.text(fields["chapterPurpose"])
    pov = Self.text(fields["pov"])
    scenes = (fields["scenes"]?.arrayValue ?? []).compactMap(Self.scene)
    let ending = fields["endingContract"]
    self.ending = Ending(
      hook: Self.text(ending?["hookType"]), handoff: Self.text(ending?["handoffState"]), beat: Self.text(ending?["emotionalBeat"]),
      question: Self.text(ending?["openQuestion"]))
    milestones = Self.strings(fields["claimedMilestones"])
    contextRefs = Self.strings(fields["contextRefs"])
    rationale = Self.text(fields["rationale"])
    direction = Self.text(fields["direction"])
    contentMode = Self.mode(fields["contentMode"])
    startedEmpty = fields["readerValue"]?.arrayValue == nil
    isEnding = fields["isEnding"]?.boolValue == true
  }

  /// plan-card.ts:260-264: the scenes' estimated lengths summed, only when every scene that says what happens has one.
  var words: Int? {
    let saved = scenes.filter { !$0.summary.isEmpty }
    guard !saved.isEmpty, saved.allSatisfy({ $0.words != nil }) else { return nil }
    return saved.reduce(0) { $0 + ($1.words ?? 0) }
  }

  /// PlanCard.tsx:235: the length offered, to the nearest hundred.
  var roundedWords: Int? { words.map { ($0 + 50) / 100 * 100 } }

  /// plan-card.ts:391-393
  var isBlank: Bool { title == nil || !scenes.contains { !$0.summary.isEmpty } }

  /// PlanCard.tsx:533: a plan saves only once it has a title and a scene that says what happens.
  static func canSave(_ plan: PlanCardContent?, canApply: Bool) -> Bool {
    guard let plan else { return false }
    return canApply && !plan.isBlank
  }

  /// plan-card.ts:395-397 with ChatPlanCard.tsx:60: the ending stays kept back unless the card or the chapter's current plan is the ending.
  func keptBack(chapterIsEnding: Bool) -> [String] {
    let ending = isEnding || chapterIsEnding ? [] : [String(localized: "how the book ends", table: "PlanCard")]
    return ending + [
      String(localized: "later volumes and their goals", table: "PlanCard"),
      String(localized: "planner-only pages (the organised timeline and open questions)", table: "PlanCard"),
    ]
  }

  // plan-card.ts:78-79
  static let alwaysSent = Text(
    "Always: this plan, how the last chapter ended, the characters on stage and what their points of view know, the book's rules, the volume's goal and your style. If it can't all fit, you'll be told what was cut.",
    tableName: "PlanCard")

  // PlanCard.tsx:105-108
  static let unrestrictedNote = Text(
    "Every step for this chapter — writing, repairs, revisions, its summary and checks — uses a model that allows dark content. The chapter is then walled off: not searched, quoted or read by the chat. The next chapter sees only a short summary and what changed (where people are, injuries, who learned what), which you check and edit before moving on.",
    tableName: "PlanCard")
  static let unrestrictedUnavailableNote = Text(
    "Unrestricted writing isn't available right now, so this chapter can't be written until it is.", tableName: "PlanCard")
  static let unrestrictedAgeNote = Text(
    "This chapter can be written on this device once you confirm your age for unrestricted writing in Settings.", tableName: "PlanCard")
  static let unrestrictedModelNote = Text("This chapter can be written once a model is chosen for unrestricted writing.", tableName: "PlanCard")
  static let unrestrictedModelAndAgeNote = Text(
    "This chapter can be written on this device once a model is chosen for unrestricted writing and you confirm your age in Settings.", tableName: "PlanCard")

  // apps/novel-forge-web/src/lib/chapter-brief.ts:140-148, 160-162: a hook this version does not know reads as none
  static func hookLabel(_ hook: String) -> String? {
    switch hook {
    case "cliffhanger": String(localized: "cliffhanger", table: "PlanCard")
    case "revelation": String(localized: "revelation", table: "PlanCard")
    case "quiet_dread": String(localized: "quiet dread", table: "PlanCard")
    case "promise": String(localized: "promise", table: "PlanCard")
    case "turn": String(localized: "turn", table: "PlanCard")
    case "closure_with_momentum": String(localized: "closure with momentum", table: "PlanCard")
    case "earned_rest": String(localized: "earned rest", table: "PlanCard")
    default: nil
    }
  }

  // plan-card.ts:116-128
  private static func scene(_ value: JSONValue) -> Scene? {
    guard value.objectValue != nil else { return nil }
    let words = value["estimatedWords"]?.intValue.flatMap { $0 > 0 ? Int($0) : nil }
    return Scene(
      summary: text(value["summary"]) ?? "", pov: text(value["pov"]), goal: text(value["goal"]), obstacle: text(value["obstacle"]), turn: text(value["turn"]),
      beats: strings(value["beats"]), words: words)
  }

  private static func mode(_ value: JSONValue?) -> Mode? {
    switch value {
    case .string("standard")?: .standard
    case .string("unrestricted")?: .unrestricted
    case .null?: .novel
    default: nil
    }
  }

  private static func text(_ value: JSONValue?) -> String? {
    let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  // plan-card.ts:92-94
  private static func strings(_ value: JSONValue?) -> [String] {
    (value?.arrayValue ?? []).compactMap { text($0) }
  }
}

/// What the card's keys read as: characters by name, Story Bible pages and entities by name, milestones by label (ChatPlanCard.tsx:44-58); a key this
/// device cannot name falls back to a label read from the key itself, as the reference's does. While the names cannot be read on this device every label
/// reads Unavailable, never a raw key.
nonisolated struct PlanCardLabels: Equatable, Sendable {
  var names: [String: String] = [:]
  var pages: [String: String] = [:]
  var milestones: [String: String] = [:]
  /// The chapter's current plan is the book's ending (ChatPlanCard.tsx:60).
  var chapterIsEnding = false
  var isUnavailable = false

  static func load(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws -> PlanCardLabels {
    let bible = try StoryBibleContents.load(novel, in: transaction)
    let structure = try StoryStructure.load(novel, in: transaction)
    var labels = PlanCardLabels()
    labels.isUnavailable = bible.entities.isUnavailable || bible.pages.isUnavailable || structure.milestones.isUnavailable
    for entity in bible.entities.value?.items ?? [] {
      if entity.type == .known(.character) { labels.names[entity.entity] = entity.name }
      labels.pages["entity:\(entity.entity)"] = entity.name
    }
    if let head = try ChapterPlanRecord.readHead(ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction).entry, !head.isRemoved {
      labels.chapterIsEnding = head.record.content.contract.isEnding
    }
    for page in bible.pages.value?.items ?? [] where !page.isEmpty {
      labels.pages["bible_doc:\(page.section.rawValue)/\(page.slug)"] = page.title
    }
    for milestone in structure.milestones.value?.items ?? [] {
      labels.milestones[milestone.record.milestone] = milestone.record.label
    }
    return labels
  }

  /// PlanCard.tsx:144, 350: a point of view that names no character reads as its key.
  func name(_ key: String) -> String {
    if isUnavailable { return Self.unavailable }
    return names[key] ?? key
  }

  // plan-card.ts:429-431
  func milestone(_ key: String) -> String {
    if isUnavailable { return Self.unavailable }
    return milestones[key] ?? Self.title(key)
  }

  // plan-card.ts:401-413
  func ref(_ ref: String) -> String {
    if isUnavailable { return Self.unavailable }
    if let page = pages[ref] { return page }
    guard let split = ref.firstIndex(of: ":") else { return Self.title(ref) }
    let (kind, value) = (String(ref[..<split]), String(ref[ref.index(after: split)...]))
    switch kind {
    case "entity": return names[value] ?? Self.title(value)
    case "chapter": return String(localized: "Chapter \(value)", table: "PlanCard")
    case "bible_doc": return Self.title(value.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? value)
    case "thread": return String(localized: "Thread: \(Self.title(value))", table: "PlanCard")
    case "mystery": return String(localized: "Mystery: \(Self.title(value))", table: "PlanCard")
    case "volume": return String(localized: "Volume: \(Self.title(value))", table: "PlanCard")
    case "world_fact": return String(localized: "World: \(Self.title(value))", table: "PlanCard")
    default: return Self.title(value)
    }
  }

  static var unavailable: String { String(localized: "Unavailable", table: "PlanCard") }

  /// apps/novel-forge-web/src/lib/bible-secrets.ts:41-47: separators and whitespace runs read as one space, the first letter raised.
  static func title(_ key: String) -> String {
    let spaced = String(key.map { "_-.".contains($0) ? " " : $0 })
    let words = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard let first = words.first else { return key }
    return first.uppercased() + words.dropFirst()
  }
}

extension ChatProposalCardModel {
  var canSavePlan: Bool { PlanCardContent.canSave(PlanCardContent(ops), canApply: canApply) }
}
