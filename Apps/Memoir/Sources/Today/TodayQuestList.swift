import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// `outcomeTone` (`quest-presenters.ts:62-67`) over the row's effective state.
enum TodayTone: Equatable {
  case kept
  case partial
  case open
  case closed

  init(_ state: QuestLogState?) {
    switch state {
    case nil, .rescheduled?: self = .open
    case .completed?: self = .kept
    case .partial?, .recovery?, .late?: self = .partial
    case .skipped?, .missed?, .postponed?: self = .closed
    }
  }
}

/// The day's quests in one list, as the web lists them: by planned start, an all-day quest last.
struct TodayQuestList: View {
  let board: TodayBoard
  let wakeNote: String?
  let actions: QuestActionsModel
  let nowMillis: Int64
  let complete: (BoardOccurrence) -> Void
  let openActions: (BoardOccurrence) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      header
      VStack(spacing: 0) {
        ForEach(Array(board.occurrences.enumerated()), id: \.element.id) { index, occurrence in
          if index > 0 { Divider() }
          TodayQuestRow(
            occurrence: occurrence, isUnsaved: actions.unsaved.contains(occurrence.id), isBusy: actions.busy.contains(occurrence.id), nowMillis: nowMillis,
            complete: { complete(occurrence) }, openActions: { openActions(occurrence) })
        }
      }
      .shadowCard()
      lock
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Group {
        if board.tally.partial > 0 {
          Text("\(board.tally.kept) of \(board.tally.scheduled) done · \(board.tally.partial) partial", tableName: "Today")
        } else {
          Text("\(board.tally.kept) of \(board.tally.scheduled) done", tableName: "Today")
        }
      }
      .shadowFont(.headline)
      .foregroundStyle(ShadowColor.textPrimary)
      Spacer(minLength: Spacing.space2)
      if let wakeNote {
        Text(verbatim: wakeNote).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  /// The plan lock is set on the Planning Board; Today only says where it stands and what today can hold.
  @ViewBuilder
  private var lock: some View {
    let summary = board.lock
    if summary.state != .none || summary.capacity != nil {
      HStack(spacing: Spacing.space2) {
        switch summary.state {
        case .active: ShadowBadge(Text("Plan locked", tableName: "Today"), intent: .accent, systemImage: "lock.fill")
        case .broken: ShadowBadge(Text("Lock broken", tableName: "Today"), intent: .warning, systemImage: "lock.open")
        case .none: EmptyView()
        }
        if let capacity = summary.capacity {
          Group {
            if capacity.warning == .none {
              Text("Today can hold about \(capacity.capacity.capacity) quests.", tableName: "Today")
            } else {
              Text("Today’s plan is over its capacity of about \(capacity.capacity.capacity) quests.", tableName: "Today")
            }
          }
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }
}

/// `features/quests/quest-row.tsx`: the check completes, the name opens the quest, and the menu holds every other action.
struct TodayQuestRow: View {
  let occurrence: BoardOccurrence
  let isUnsaved: Bool
  let isBusy: Bool
  let nowMillis: Int64
  let complete: () -> Void
  let openActions: () -> Void

  private var name: String { QuestActionCopy.name(occurrence.quest) }
  private var tone: TodayTone { TodayTone(occurrence.effectiveState) }

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.space3) {
      Button(action: complete) {
        Image(systemName: checkSymbol)
          .font(.title2)
          .foregroundStyle(checkColor)
          .frame(minWidth: ShadowMetrics.tapTarget, minHeight: ShadowMetrics.tapTarget)
      }
      .buttonStyle(.plain)
      .disabled(isBusy || !occurrence.actions.complete.isPossible(at: nowMillis))
      .accessibilityLabel(Text(verbatim: checkLabel))
      NavigationLink(value: MemoirRoute.quest(.detail(occurrence.quest.id))) {
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text(verbatim: name).shadowFont(.body).foregroundStyle(tone == .closed ? ShadowColor.textSecondary : ShadowColor.textPrimary)
          Text(verbatim: TodayQuestRow.meta(occurrence)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          if isUnsaved {
            Text(verbatim: QuestActionCopy.unsaved).shadowFont(.footnote).foregroundStyle(ShadowColor.dangerText)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if tone == .closed, let state = occurrence.effectiveState {
        ShadowBadge(Text(verbatim: QuestActionCopy.state(state)))
      }
      if occurrence.locked {
        ShadowBadge(Text("Locked", tableName: "Today"))
      }
      Button(action: openActions) {
        Image(systemName: "ellipsis.circle").frame(minWidth: ShadowMetrics.tapTarget, minHeight: ShadowMetrics.tapTarget)
      }
      .buttonStyle(.plain)
      .foregroundStyle(ShadowColor.textSecondary)
      .accessibilityLabel(Text("Actions for \(name)", tableName: "Today"))
    }
    .padding(.horizontal, Spacing.space2)
    .contextMenu {
      Button(action: openActions) { Text("Actions for \(name)", tableName: "Today") }
    }
  }

  private var checkSymbol: String {
    switch tone {
    case .kept: "checkmark.circle.fill"
    case .partial: "circle.lefthalf.filled"
    case .open: "circle"
    case .closed: "minus.circle"
    }
  }

  private var checkColor: Color {
    switch tone {
    case .kept: ShadowColor.successSolid
    case .partial: ShadowColor.accent
    case .open: ShadowColor.textSecondary
    case .closed: ShadowColor.textTertiary
    }
  }

  /// `occurrenceCheckLabel` (`quest-presenters.ts:91-96`).
  private var checkLabel: String {
    switch occurrence.effectiveState {
    case .completed?: String(localized: "Completed: \(name)", table: "Today")
    case .partial?: String(localized: "Partial: \(name)", table: "Today")
    case nil, .rescheduled?: String(localized: "Mark complete: \(name)", table: "Today")
    case let state?: String(localized: "\(QuestActionCopy.state(state)): \(name)", table: "Today")
    }
  }

  /// `occurrenceMeta` (`quest-presenters.ts:76-89`).
  static func meta(_ occurrence: BoardOccurrence) -> String {
    let time: String? =
      if case .recorded(.rescheduled) = occurrence.status, let minute = occurrence.log?.rescheduledToMinute {
        String(localized: "Moved to \(TodayFormat.time(minuteOfDay: minute))", table: "Today")
      } else {
        occurrence.quest.startMinute.map(TodayFormat.time(minuteOfDay:))
      }
    let xp = occurrence.log?.xpAwarded ?? 0
    let streak = occurrence.streak
    return [
      time, xp > 0 ? String(localized: "+\(xp) XP", table: "Today") : nil, QuestActionCopy.stat(occurrence.quest.statAffinity),
      QuestActionCopy.strictness(occurrence.quest.strictness),
      streak.currentDays > 0 ? QuestActionCopy.streak(days: streak.currentDays, unit: streak.unit) : nil,
    ].compactMap(\.self).joined(separator: " · ")
  }
}
