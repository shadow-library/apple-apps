import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// What a screen that lists occurrences gives the quest actions: its latest row for an occurrence and the account's clock.
@MainActor
protocol QuestActionHosting: AnyObject, Observable {
  var actions: QuestActionsModel { get }
  var nowMillis: Int64 { get }
  func occurrence(_ id: Occurrence) -> BoardOccurrence?
  func perform(_ request: QuestActionRequest) async -> QuestActionOutcome
  func existingReason(of occurrence: BoardOccurrence) async -> QuestActionReason
  func minuteOfDay() -> Int?
}

enum QuestActionStep: Hashable {
  case menu
  case partial
  case skip
  case postpone
  case reschedule
  case attachReason
}

struct QuestActionPresentation: Identifiable, Hashable {
  let occurrence: Occurrence
  let step: QuestActionStep

  var id: Occurrence { occurrence }
}

/// What was done, for the host's confirmation: the request and the row as it was before it.
struct QuestActionCompletion {
  let request: QuestActionRequest
  let before: BoardOccurrence
  let offersUndo: Bool
}

/// The action list and each action's own step (`quest-actions.tsx`): a sheet that stays open on a failure and closes once the change is written.
struct QuestActionSheet<Host: QuestActionHosting>: View {
  private static var utc: TimeZone { TimeZone(identifier: "UTC") ?? .gmt }
  private static var quarterHour: Int { 15 }
  private static var lastMinute: Int { 1439 }

  let host: Host
  let occurrenceID: Occurrence
  let dayLabel: String
  let finished: (QuestActionCompletion) -> Void
  @State private var step: QuestActionStep
  @State private var reason: ReasonTag?
  @State private var note = ""
  @State private var time: Date
  @State private var problem: String?
  @State private var confirmingCap = false
  @State private var loadedReason = false
  @Environment(\.dismiss) private var dismiss

  init(host: Host, presentation: QuestActionPresentation, dayLabel: String, finished: @escaping (QuestActionCompletion) -> Void) {
    self.host = host
    occurrenceID = presentation.occurrence
    self.dayLabel = dayLabel
    self.finished = finished
    _step = State(initialValue: presentation.step)
    let planned = host.occurrence(presentation.occurrence)?.plannedMinute
    let now = host.minuteOfDay().map { min(Self.lastMinute, ($0 + Self.quarterHour - 1) / Self.quarterHour * Self.quarterHour) }
    _time = State(initialValue: Self.date(minute: planned ?? now ?? 0))
  }

  var body: some View {
    if let occurrence = host.occurrence(occurrenceID) {
      content(occurrence)
        .confirmationDialog(capTitle(occurrence), isPresented: $confirmingCap, titleVisibility: .visible) {
          Button {
            submit(.reschedule(occurrenceID, toMinute: Self.minute(of: time), acceptBeyondCap: true), occurrence)
          } label: {
            Text("Move it anyway", tableName: "Today")
          }
          Button(role: .cancel) {
          } label: {
            Text("Keep the plan", tableName: "Today")
          }
          .shadowDialogCancelAction()
        } message: {
          Text(verbatim: capMessage(occurrence))
        }
    } else {
      ShadowContentUnavailable(
        Text("That quest isn’t in your plan any more.", tableName: "Today"), systemImage: "flag.slash"
      )
      .shadowSheetHeader(Text("Quest", tableName: "Today"), cancel: ShadowSheetCancel(Text("Close", tableName: "Today")) { dismiss() })
    }
  }

  @ViewBuilder
  private func content(_ occurrence: BoardOccurrence) -> some View {
    let name = QuestActionCopy.name(occurrence.quest)
    switch step {
    case .menu:
      menu(occurrence)
        .shadowSheetHeader(
          Text(verbatim: name), subtitle: Text(verbatim: summary(occurrence)),
          cancel: ShadowSheetCancel(Text("Close", tableName: "Today")) { dismiss() })
    case .partial:
      form {
        Text("A partial keeps the streak and grants XP for what you did. It is a real outcome, not a failure.", tableName: "Today").descriptionStyle()
        reasonFields(hint: Text("— optional, used only in your own patterns", tableName: "Today"))
      }
      .shadowSheetHeader(
        Text("Partial — \(name)", tableName: "Today"), cancel: cancel,
        confirm: confirm(Text("Save partial", tableName: "Today"), occurrence) { .partial(occurrenceID, currentReason) })
    case .skip:
      form {
        Text(verbatim: QuestActionCopy.skipReasonNote).descriptionStyle()
        breakFacts(occurrence, lock: false)
        reasonFields(hint: Text("— optional, used only in your own patterns", tableName: "Today"))
      }
      .shadowSheetHeader(
        Text("Skip — \(name)", tableName: "Today"), cancel: cancel,
        confirm: confirm(Text("Skip quest", tableName: "Today"), occurrence) { .skip(occurrenceID, currentReason) })
    case .postpone:
      form {
        Text("This moves the occurrence to tomorrow.", tableName: "Today").descriptionStyle()
        breakFacts(occurrence, lock: occurrence.actions.postpone == .needsConfirmation(.breaksPlanLock))
      }
      .shadowSheetHeader(
        Text("Postpone — \(name)", tableName: "Today"),
        cancel: ShadowSheetCancel(Text("Keep today", tableName: "Today")) { dismiss() },
        confirm: confirm(Text("Postpone", tableName: "Today"), occurrence) {
          .postpone(occurrenceID, breakingLock: occurrence.actions.postpone == .needsConfirmation(.breaksPlanLock))
        })
    case .reschedule:
      form { rescheduleFields(occurrence) }
        .shadowSheetHeader(
          Text("Reschedule — \(name)", tableName: "Today"),
          cancel: ShadowSheetCancel(Text("Keep the plan", tableName: "Today")) { dismiss() },
          confirm: ShadowSheetConfirm(Text("Move it", tableName: "Today"), isDisabled: isBusy, submitShortcut: true) { move(occurrence) })
    case .attachReason:
      form {
        Text("A reason is only ever shown to you and used in your own patterns.", tableName: "Today").descriptionStyle()
        if occurrence.log?.reasonTag != nil || occurrence.log?.reasonNote != nil {
          Text("Saving replaces the reason already recorded, tag and note together.", tableName: "Today").descriptionStyle()
        }
        reasonFields(hint: Text("— a tag, a note or both", tableName: "Today"))
      }
      .task(id: occurrence.log?.id) { await loadExistingReason(occurrence) }
      .shadowSheetHeader(
        Text("Add a reason — \(name)", tableName: "Today"), cancel: cancel,
        confirm: confirm(Text("Save reason", tableName: "Today"), occurrence, isDisabled: currentReason.isEmpty) { .attachReason(occurrenceID, currentReason) })
    }
  }

  private var cancel: ShadowSheetCancel {
    ShadowSheetCancel(Text("Cancel", tableName: "Today")) { dismiss() }
  }

  private var isBusy: Bool { host.actions.busy.contains(occurrenceID) }

  private var currentReason: QuestActionReason { QuestActionReason(tag: reason, note: note) }

  private func confirm(
    _ title: Text, _ occurrence: BoardOccurrence, isDisabled: Bool = false, request: @escaping () -> QuestActionRequest
  ) -> ShadowSheetConfirm {
    ShadowSheetConfirm(title, isDisabled: isDisabled || isBusy || currentReason.isNoteTooLong, submitShortcut: true) { submit(request(), occurrence) }
  }

  private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      content()
      if let problem {
        ShadowCallout(Text(verbatim: problem), intent: .danger)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.space4)
    .shadowFittedDetents()
    .shadowSheetStyle(.form)
  }

  private func menu(_ occurrence: BoardOccurrence) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ForEach(kinds(for: occurrence), id: \.self) { kind in
        let disabled = QuestActionCopy.disabledReason(kind, for: occurrence, at: host.nowMillis)
        Button {
          open(kind, occurrence)
        } label: {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: QuestActionCopy.label(kind)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: disabled ?? QuestActionCopy.rule(kind, for: occurrence))
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Spacing.space3)
        }
        .buttonStyle(.shadowCard)
        .disabled(disabled != nil || isBusy)
      }
      if let problem {
        ShadowCallout(Text(verbatim: problem), intent: .danger)
      }
    }
    .padding(Spacing.space4)
    .shadowFittedDetents()
  }

  /// Adding a reason has meaning only once something is recorded.
  private func kinds(for occurrence: BoardOccurrence) -> [QuestActionKind] {
    QuestActionKind.menu.filter { $0 != .attachReason || occurrence.actions.attachReason != .unavailable(.nothingRecorded) }
  }

  private func open(_ kind: QuestActionKind, _ occurrence: BoardOccurrence) {
    problem = nil
    switch kind {
    case .complete: submit(.complete(occurrenceID), occurrence)
    case .partial: step = .partial
    case .postpone: step = .postpone
    case .reschedule: step = .reschedule
    case .skip: step = .skip
    case .attachReason:
      reason = occurrence.log?.reasonTag
      step = .attachReason
    case .undo: submit(.undo(occurrenceID), occurrence)
    }
  }

  private func summary(_ occurrence: BoardOccurrence) -> String {
    let streak = occurrence.streak
    return [
      dayLabel, QuestActionCopy.stat(occurrence.quest.statAffinity), QuestActionCopy.strictness(occurrence.quest.strictness),
      streak.currentDays > 0 ? QuestActionCopy.streak(days: streak.currentDays, unit: streak.unit) : nil,
      streak.shields > 0 ? QuestActionCopy.shields(streak.shields) : nil,
    ].compactMap(\.self).joined(separator: " · ")
  }

  private func reasonFields(hint: Text) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
        Text("Reason", tableName: "Today").foregroundStyle(ShadowColor.textPrimary)
        hint.foregroundStyle(ShadowColor.textSecondary).fixedSize(horizontal: false, vertical: true)
      }
      .shadowFont(.subheadline)
      ShadowFlowLayout {
        ForEach(ReasonTag.allCases, id: \.self) { tag in
          ShadowTag(Text(verbatim: QuestActionCopy.reason(tag)), isSelected: Binding(get: { reason == tag }, set: { reason = $0 ? tag : nil }))
        }
      }
      ShadowTextEditor(
        text: $note, placeholder: Text("Anything worth remembering (optional)", tableName: "Today"), limit: QuestActionReason.noteLimit, minHeight: 56,
        maxHeight: 120
      ) { count in
        Text("\(count.count) of \(QuestActionReason.noteLimit)", tableName: "Today")
      }
      .accessibilityLabel(Text("Reason note", tableName: "Today"))
    }
  }

  private func breakFacts(_ occurrence: BoardOccurrence, lock: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      QuestActionFact(term: Text("Streak", tableName: "Today"), value: Text(verbatim: QuestActionCopy.streakNote(occurrence.breakCost)))
      QuestActionFact(term: Text("Cost", tableName: "Today"), value: Text(verbatim: QuestActionCopy.costNote(occurrence)))
      if lock { QuestActionFact(term: Text("Locked plan", tableName: "Today"), value: Text(verbatim: QuestActionCopy.lockNote)) }
    }
  }

  @ViewBuilder
  private func rescheduleFields(_ occurrence: BoardOccurrence) -> some View {
    Text("This changes only today’s time — the day and the recurring plan don’t move.", tableName: "Today").descriptionStyle()
    DatePicker(selection: $time, displayedComponents: .hourAndMinute) {
      Text("Move to", tableName: "Today")
    }
    .environment(\.timeZone, Self.utc)
    .onChange(of: time) { problem = nil }
    if case .needsConfirmation(.rescheduleBecomesPostpone) = occurrence.actions.reschedule {
      QuestActionFact(term: Text("Reschedule cap", tableName: "Today"), value: Text("Reached — this move is recorded as a postpone", tableName: "Today"))
      breakFacts(occurrence, lock: occurrence.actions.postpone == .needsConfirmation(.breaksPlanLock))
    } else {
      QuestActionFact(term: Text("Streak", tableName: "Today"), value: Text("Kept — a move inside the cap does not break it", tableName: "Today"))
      QuestActionFact(term: Text("HP", tableName: "Today"), value: Text("Unchanged", tableName: "Today"))
      QuestActionFact(term: Text("Recurring plan", tableName: "Today"), value: Text("Untouched — only today’s occurrence moves", tableName: "Today"))
    }
  }

  /// The model refuses a time already passed before it asks about the cap, so the cap dialog opens only for a move it would take.
  private func move(_ occurrence: BoardOccurrence) {
    submit(.reschedule(occurrenceID, toMinute: Self.minute(of: time), acceptBeyondCap: false), occurrence)
  }

  /// `quest.attachReason` writes the tag and the note together, so the form starts from the ones it replaces.
  private func loadExistingReason(_ occurrence: BoardOccurrence) async {
    guard !loadedReason else { return }
    loadedReason = true
    let existing = await host.existingReason(of: occurrence)
    if reason == nil { reason = existing.tag }
    if note.isEmpty { note = existing.note ?? "" }
  }

  private func capTitle(_ occurrence: BoardOccurrence) -> Text {
    Text("\(occurrence.reschedule.cap) reschedules used in the last 7 days", tableName: "Today")
  }

  private func capMessage(_ occurrence: BoardOccurrence) -> String {
    let cap = occurrence.reschedule.cap
    let strictness = QuestActionCopy.strictness(occurrence.quest.strictness)
    guard let freesOn = occurrence.reschedule.freesOn else {
      return String(
        localized:
          "\(cap) moves a week is the cap on \(strictness) quests. Past it a move is recorded as a postpone instead of disappearing, so the history stays honest either way.",
        table: "Today")
    }
    return String(
      localized:
        "\(cap) moves a week is the cap on \(strictness) quests. Past it a move is recorded as a postpone instead of disappearing, so the history stays honest either way. The cap frees up for occurrences from \(TodayFormat.shortDate(freesOn)).",
      table: "Today")
  }

  private func submit(_ request: QuestActionRequest, _ occurrence: BoardOccurrence) {
    problem = nil
    Task {
      switch await host.perform(request) {
      case .done(let offersUndo):
        finished(QuestActionCompletion(request: request, before: occurrence, offersUndo: offersUndo))
        dismiss()
      case .failed(let error):
        problem = QuestActionCopy.failure(request.kind, name: QuestActionCopy.name(occurrence.quest), message: error.headline)
      case .unavailable(.needsConfirmation(.rescheduleBecomesPostpone)):
        confirmingCap = true
      case .unavailable(.needsConfirmation(.breaksPlanLock)):
        problem = String(
          localized: "Today’s plan was locked while this was open. Postponing now breaks the lock; choose Postpone again to go ahead.", table: "Today")
      case .unavailable(let reason):
        problem = QuestActionCopy.unavailable(reason, for: request.kind)
      case .cancelled:
        break
      }
    }
  }

  private static func date(minute: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(minute * 60))
  }

  private static func minute(of date: Date) -> Int {
    let seconds = Int(date.timeIntervalSince1970.rounded(.down))
    return ((seconds / 60) % 1440 + 1440) % 1440
  }
}

struct QuestActionFact: View {
  let term: Text
  let value: Text

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      term.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      value.shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

extension Text {
  fileprivate func descriptionStyle() -> some View {
    shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary).fixedSize(horizontal: false, vertical: true)
  }
}
